#!/bin/bash
# ============================================================
# verify_zips.sh (v3)
#
# 변경점 (v2 → v3):
#   - ROOT 기본값: ./zips/138.뉴스_대본_및_앵커_음성_데이터
#   - multi-volume zip (.z01/.z02 + .zip) 자동 감지
#   - 검증 모드 2단계:
#       기본 (DEEP=0): 빠른 헤더 검증 (unzip -l, 몇 초)
#       정밀 (DEEP=1): 7z t 로 전체 데이터 읽기 (HDD 기준 수십 분~수 시간)
#   - .z01, .z02 같은 분할 파트는 단독 검증 대상에서 제외
#   - 단일 zip 은 기존대로 unzip -tq
#
# 사용:
#   ./verify_zips.sh              # 빠른 검증
#   DEEP=1 ./verify_zips.sh       # 정밀 검증 (시간 안내 후 사용자 확인)
#   DEEP=1 YES=1 ./verify_zips.sh # 확인 없이 정밀 검증 (CI/스크립트용)
#
# 환경변수:
#   DATASET_KEY     기본: 71557
#   FILELIST        기본: filelist_${DATASET_KEY}.txt
#   ROOT            기본: ./zips/138.뉴스_대본_및_앵커_음성_데이터
#   PARALLEL        기본: 8
#   DEEP            기본: 0  (1이면 7z t 사용)
#   YES             기본: 0  (1이면 DEEP=1 확인 프롬프트 스킵)
#   SHOW_DETAILS    기본: 1
#   USE_COLOR       기본: auto
#   DEBUG           기본: 0
# ============================================================
set -u

DATASET_KEY="${DATASET_KEY:-71557}"
FILELIST="${FILELIST:-filelist_${DATASET_KEY}.txt}"
ROOT="${ROOT:-./zips/138.뉴스_대본_및_앵커_음성_데이터}"
PARALLEL="${PARALLEL:-8}"
DEEP="${DEEP:-0}"
YES="${YES:-0}"
SHOW_DETAILS="${SHOW_DETAILS:-1}"
USE_COLOR="${USE_COLOR:-auto}"
DEBUG="${DEBUG:-0}"

# 색상
if [ "$USE_COLOR" = "auto" ]; then
  [ -t 1 ] && USE_COLOR=1 || USE_COLOR=0
fi
if [ "$USE_COLOR" = "1" ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# 의존성
need_7z=0
[ "$DEEP" = "1" ] && need_7z=1
for cmd in awk grep find xargs unzip basename sort sed tr; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] missing: $cmd"; exit 1; }
done
if [ "$need_7z" = "1" ]; then
  command -v 7z >/dev/null 2>&1 || { echo "[ERROR] DEEP=1 mode requires 7z (sudo apt install p7zip-full)"; exit 1; }
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[ERROR] bash 4.0+ 필요"; exit 1
fi
[ -f "$FILELIST" ] || { echo "[ERROR] filelist 없음: $FILELIST"; exit 1; }
[ -d "$ROOT" ] || { echo "[ERROR] ROOT 없음: $ROOT"; exit 1; }

normalize_name() {
  echo "$1" | tr -d '[:space:]'
}

# .zip 또는 .zNN 모두 파싱
parse_filelist_line() {
  local line="$1"
  local clean=$(echo "$line" | sed -e 's/[─├└│|]/ /g' -e 's/\r//g')
  local zip_part=$(echo "$clean" | grep -oE '.*\.(zip|z[0-9]{2})' | head -1)
  [ -z "$zip_part" ] && return 1
  local name_norm=$(echo "$zip_part" | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
  local key=$(echo "$clean" | grep -oE '[0-9]{4,}' | tail -1)
  local size=$(echo "$clean" | grep -oE '[0-9.]+ ?(KB|MB|GB|TB)' | head -1)
  [ -z "$name_norm" ] || [ -z "$key" ] && return 1
  echo "${name_norm}|${size:-?}|${key}"
}

printf "${BOLD}============================================${NC}\n"
printf "${BOLD}  AI Hub zip 무결성 검증 (v3, multi-volume aware)${NC}\n"
printf "${BOLD}============================================${NC}\n"
echo "  DATASET_KEY : $DATASET_KEY"
echo "  ROOT        : $ROOT"
echo "  FILELIST    : $FILELIST"
echo "  PARALLEL    : $PARALLEL"
if [ "$DEEP" = "1" ]; then
  printf "  MODE        : ${YELLOW}DEEP (7z t)${NC} — 전체 데이터 읽기\n"
else
  printf "  MODE        : ${GREEN}FAST (unzip -l)${NC} — 헤더만 읽기\n"
  echo "                (정밀 검증을 원하면 DEEP=1 로 재실행)"
fi
[ "$DEBUG" = "1" ] && echo "  DEBUG       : ON"
echo

# === filelist 파싱 ===
declare -A filelist_info
filelist_count=0
debug_shown=0
while IFS= read -r line || [ -n "$line" ]; do
  parsed=$(parse_filelist_line "$line") || continue
  IFS='|' read -r name size key <<< "$parsed"
  filelist_info["$name"]="${size}|${key}"
  filelist_count=$((filelist_count+1))
  if [ "$DEBUG" = "1" ] && [ "$debug_shown" -lt 5 ]; then
    printf "${BLUE}[DEBUG] name=[%s] size=[%s] key=[%s]${NC}\n" "$name" "$size" "$key"
    debug_shown=$((debug_shown+1))
  fi
done < "$FILELIST"

if [ "$filelist_count" -eq 0 ]; then
  printf "${RED}[ERROR] filelist 파싱 0건.${NC}\n"
  exit 1
fi

# === multi-volume 그룹 식별 + 시간 안내 ===
# 메인 zip 들 중 같은 prefix 의 .z?? 가 있으면 multi-volume
declare -A is_multivol  # basename(main zip) -> 1
multivol_groups=()
multivol_total_bytes=0
while IFS= read -r mainzip; do
  d=$(dirname "$mainzip")
  b=$(basename "$mainzip")
  prefix="${b%.zip}"
  if compgen -G "$d/${prefix}.z[0-9][0-9]" >/dev/null 2>&1; then
    is_multivol["$b"]=1
    multivol_groups+=("$mainzip")
    # 그룹 전체 용량
    for f in "$mainzip" "$d/${prefix}.z"[0-9][0-9]; do
      [ -f "$f" ] && multivol_total_bytes=$((multivol_total_bytes + $(stat -c%s "$f")))
    done
  fi
done < <(find "$ROOT" -name "*.zip" 2>/dev/null)

if [ "${#multivol_groups[@]}" -gt 0 ]; then
  multivol_total_gb=$(awk "BEGIN{printf \"%.1f\", $multivol_total_bytes/1024/1024/1024}")
  printf "${BOLD}🔗 multi-volume zip 그룹 ${#multivol_groups[@]}개 감지 (합계 약 ${multivol_total_gb} GB)${NC}\n"
  for g in "${multivol_groups[@]}"; do
    echo "    - $g"
  done
  echo

  if [ "$DEEP" = "1" ]; then
    # 시간 예상치 (HDD 100MB/s 가정, SSD 면 5배 빠름)
    est_min_hdd=$(awk "BEGIN{printf \"%d\", $multivol_total_bytes/1024/1024/100/60}")
    est_min_ssd=$(awk "BEGIN{printf \"%d\", $multivol_total_bytes/1024/1024/500/60}")
    printf "${YELLOW}[WARN] DEEP 모드는 모든 볼륨을 읽습니다.${NC}\n"
    printf "       예상 시간: HDD 약 ${est_min_hdd}분 / SSD 약 ${est_min_ssd}분\n"
    if [ "$YES" != "1" ]; then
      printf "       계속하시려면 ${BOLD}y${NC} 를 입력하세요 [y/N]: "
      read -r answer
      case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "       중단합니다."; exit 0 ;;
      esac
    fi
  fi
fi

# === 검증 대상: .zip 만 (.z?? 는 메인 zip 으로 묶여 검증됨) ===
total_zip=$(find "$ROOT" -name "*.zip" 2>/dev/null | wc -l)
if [ "$total_zip" -eq 0 ]; then
  printf "${YELLOW}[WARN] zip 파일 없음.${NC}\n"
  exit 1
fi

printf "🔍 검증 시작 (${BOLD}%d개 메인 zip${NC}, 병렬 ${BOLD}%d${NC})\n" "$total_zip" "$PARALLEL"
echo

TMPFILE=$(mktemp); trap "rm -f $TMPFILE" EXIT

start_ts=$(date +%s)

# 검증 워커: 인라인 sh -c
# - 같은 prefix 의 .z?? 가 있으면 multi-volume → DEEP 따라 분기
# - 없으면 단일 zip → unzip -tq
find "$ROOT" -name "*.zip" -print0 \
  | xargs -0 -P "$PARALLEL" -I {} sh -c '
      zip="$1"
      deep="$2"
      d=$(dirname "$zip")
      b=$(basename "$zip")
      prefix="${b%.zip}"
      ok=0
      if ls "$d/${prefix}.z"[0-9][0-9] >/dev/null 2>&1; then
        # multi-volume
        if [ "$deep" = "1" ]; then
          7z t "$zip" >/dev/null 2>&1 && ok=1
        else
          # unzip -l: central directory 읽기 (몇 초)
          unzip -l "$zip" >/dev/null 2>&1 && ok=1
        fi
      else
        # 단일 zip
        unzip -tq "$zip" >/dev/null 2>&1 && ok=1
      fi
      [ "$ok" -eq 0 ] && echo "$b"
    ' _ {} "$DEEP" > "$TMPFILE"

end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

broken_count=$(wc -l < "$TMPFILE")
ok_count=$((total_zip - broken_count))

printf "${BOLD}📊 검증 결과${NC} (${elapsed}초)\n"
printf "  정상 : ${GREEN}%d건${NC}\n" "$ok_count"
if [ "$broken_count" -eq 0 ]; then
  printf "  깨짐 : ${GREEN}%d건${NC}\n" "$broken_count"
else
  printf "  깨짐 : ${RED}%d건${NC}\n" "$broken_count"
fi
if [ "$DEEP" = "0" ] && [ "${#multivol_groups[@]}" -gt 0 ]; then
  echo
  printf "${BLUE}ℹ️  multi-volume zip 은 헤더만 검증되었습니다.${NC}\n"
  printf "    데이터 본문까지 검증하려면: ${BOLD}DEEP=1 ./verify_zips.sh${NC}\n"
fi
echo

if [ "$broken_count" -eq 0 ]; then
  printf "${GREEN}${BOLD}✓ 검증 통과${NC}\n"
  exit 0
fi

printf "${RED}${BOLD}✗ 깨진 zip 발견${NC}\n"

if [ "$SHOW_DETAILS" = "1" ]; then
  echo
  printf "${BOLD}📋 깨진 파일 상세${NC}\n"
  printf -- "─────────────────────────────────────────────────────────────────────\n"
  printf "%-50s %-12s %-10s\n" "파일명(정규화)" "용량" "filekey"
  printf -- "─────────────────────────────────────────────────────────────────────\n"

  TMPSORT=$(mktemp); sort "$TMPFILE" > "$TMPSORT"

  unmatched=()
  filekeys_csv=""
  declare -A added_keys
  while IFS= read -r raw_name; do
    norm_name=$(normalize_name "$raw_name")
    info="${filelist_info[$norm_name]:-}"
    if [ -n "$info" ]; then
      size="${info%|*}"; key="${info#*|}"
      printf "%-50s %-12s %-10s\n" "$norm_name" "$size" "$key"
      # multi-volume 이면 같은 prefix 의 .z?? filekey 도 함께 권고
      prefix_n="${norm_name%.zip}"
      for fn in "${!filelist_info[@]}"; do
        case "$fn" in
          "$norm_name"|"${prefix_n}".z[0-9][0-9])
            k="${filelist_info[$fn]#*|}"
            if [ -z "${added_keys[$k]:-}" ]; then
              added_keys[$k]=1
              [ -z "$filekeys_csv" ] && filekeys_csv="$k" || filekeys_csv="${filekeys_csv},${k}"
            fi
            ;;
        esac
      done
    else
      unmatched+=("$raw_name")
    fi
  done < "$TMPSORT"
  rm -f "$TMPSORT"

  printf -- "─────────────────────────────────────────────────────────────────────\n"

  if [ "${#unmatched[@]}" -gt 0 ]; then
    echo
    printf "${YELLOW}[WARN] filelist 에서 매칭 안 된 깨진 파일:${NC}\n"
    printf '  - %s\n' "${unmatched[@]}"
  fi

  echo
  printf "${BOLD}💡 복구 방법${NC}\n"
  echo "  (A) 자동 복구:    ./repair_aihub.sh"
  echo "  (B) 수동 명령:    aihubshell -mode d -datasetkey $DATASET_KEY \\"
  echo "                                -filekey '$filekeys_csv' \\"
  echo "                                -aihubapikey \"\$AIHUB_APIKEY\""
  echo
  echo "  💬 multi-volume zip 의 경우, 메인 .zip 뿐 아니라 같은 prefix 의"
  echo "     .z01/.z02 filekey 도 함께 권고에 포함되어 있습니다."
fi

exit 1