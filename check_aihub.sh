#!/bin/bash
# ============================================================
# check_aihub.sh (v2)
# AI Hub 데이터셋 다운로드 상태를 빠르게 진단.
#
# v2 변경점:
#   - 토큰 기반 filelist 파싱 (| 구분자 가정 제거)
#   - 트리 문자(└─├─││|) 자동 처리
#   - 파일명 공백 정규화로 매칭 (한글 사이 공백 케이스 대응)
#   - DEBUG=1 모드로 파싱 결과 진단 가능
#
# 환경변수:
#   DATASET_KEY     기본: 71349
#   FILELIST        기본: filelist_${DATASET_KEY}.txt
#   ROOT            기본: ./133.감성_및_발화_스타일_동시_고려_음성합성_데이터
#   SHOW_DETAILS    기본: 1 (0이면 개수만)
#   USE_COLOR       기본: auto
#   DEBUG           기본: 0 (1이면 파싱 진단 정보 출력)
# ============================================================
set -u

DATASET_KEY="${DATASET_KEY:-71557}"
FILELIST="${FILELIST:-filelist_${DATASET_KEY}.txt}"
ROOT="${ROOT:-./138.뉴스_대본_및_앵커_음성_데이터}"
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
for cmd in awk grep find sort basename sed tr; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] missing: $cmd"; exit 1; }
done
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[ERROR] bash 4.0+ 필요"; exit 1
fi
[ -f "$FILELIST" ] || { echo "[ERROR] filelist 없음: $FILELIST"; exit 1; }
[ -d "$ROOT" ] || { echo "[ERROR] ROOT 없음: $ROOT"; exit 1; }

# === 정규화 함수: 모든 공백 제거 ===
normalize_name() {
  echo "$1" | tr -d '[:space:]'
}

# === filelist 라인 파싱: "normalized_name|size|key" 출력 ===
parse_filelist_line() {
  local line="$1"
  # 트리 문자(└─├─│|), \r 제거 → 공백으로 치환
  local clean=$(echo "$line" | sed -e 's/[─├└│|]/ /g' -e 's/\r//g')
  # .zip까지의 텍스트 추출 (마지막 .zip 위치까지)
  local zip_part=$(echo "$clean" | grep -oE '.*\.zip' | head -1)
  [ -z "$zip_part" ] && return 1
  # 앞쪽 공백 제거 후 모든 공백 제거 = 정규화 파일명
  local name_norm=$(echo "$zip_part" | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
  # filekey: 4자리 이상 숫자 중 마지막
  local key=$(echo "$clean" | grep -oE '[0-9]{4,}' | tail -1)
  # 용량
  local size=$(echo "$clean" | grep -oE '[0-9.]+ ?(KB|MB|GB|TB)' | head -1)
  [ -z "$name_norm" ] || [ -z "$key" ] && return 1
  echo "${name_norm}|${size:-?}|${key}"
}

printf "${BOLD}============================================${NC}\n"
printf "${BOLD}  AI Hub 다운로드 빠른 진단 (v2)${NC}\n"
printf "${BOLD}============================================${NC}\n"
echo "  DATASET_KEY : $DATASET_KEY"
echo "  ROOT        : $ROOT"
echo "  FILELIST    : $FILELIST"
[ "$DEBUG" = "1" ] && echo "  DEBUG       : ON"
echo

# === filelist 파싱: 정규화 파일명 -> "용량|filekey" ===
declare -A filelist_info
filelist_count=0
line_no=0
debug_shown=0

while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no+1))
  parsed=$(parse_filelist_line "$line") || continue
  IFS='|' read -r name size key <<< "$parsed"
  filelist_info["$name"]="${size}|${key}"
  filelist_count=$((filelist_count+1))

  # DEBUG: 처음 5개 파싱 결과 표시
  if [ "$DEBUG" = "1" ] && [ "$debug_shown" -lt 5 ]; then
    printf "${BLUE}[DEBUG] L%d: name=[%s] size=[%s] key=[%s]${NC}\n" \
      "$line_no" "$name" "$size" "$key"
    debug_shown=$((debug_shown+1))
  fi
done < "$FILELIST"

if [ "$filelist_count" -eq 0 ]; then
  printf "${RED}[ERROR] filelist 파싱 0건. 포맷 확인:${NC}\n"
  echo "        head -20 $FILELIST"
  echo "        DEBUG=1 ./check_aihub.sh"
  exit 1
fi

[ "$DEBUG" = "1" ] && echo "[DEBUG] filelist 파싱 완료: ${filelist_count}건" && echo

# === 디스크 스캔 (정규화 파일명으로 저장) ===
declare -A disk_names_normalized
disk_zips=0
while IFS= read -r zip; do
  basename_raw=$(basename "$zip")
  basename_norm=$(normalize_name "$basename_raw")
  disk_names_normalized["$basename_norm"]=1
  disk_zips=$((disk_zips+1))

  # DEBUG: 첫 3개 디스크 파일과 매칭 시도 결과
  if [ "$DEBUG" = "1" ] && [ "$disk_zips" -le 3 ]; then
    if [ -n "${filelist_info[$basename_norm]:-}" ]; then
      printf "${GREEN}[DEBUG] disk=[%s] norm=[%s] → filelist 매칭 ✓${NC}\n" \
        "$basename_raw" "$basename_norm"
    else
      printf "${RED}[DEBUG] disk=[%s] norm=[%s] → filelist 매칭 ✗${NC}\n" \
        "$basename_raw" "$basename_norm"
    fi
  fi
done < <(find "$ROOT" -name "*.zip" 2>/dev/null)

part_count=$(find "$ROOT" -name "*.zip.part*" 2>/dev/null | wc -l)
tar_count=$(find "$ROOT" -name "download.tar" 2>/dev/null | wc -l)

[ "$DEBUG" = "1" ] && echo

# === 누락 식별 (정규화 키로 비교) ===
missing=()
for name in "${!filelist_info[@]}"; do
  [ -z "${disk_names_normalized[$name]:-}" ] && missing+=("$name")
done

# === 출력 ===
printf "${BOLD}📊 개수 비교${NC}\n"
printf "  filelist 등록 zip : %d\n" "$filelist_count"
printf "  디스크 zip        : %d\n" "$disk_zips"

if [ "$part_count" -eq 0 ]; then
  printf "  part 잔재         : ${GREEN}0${NC}\n"
else
  printf "  part 잔재         : ${RED}%d${NC}   (0이어야 정상)\n" "$part_count"
fi
if [ "$tar_count" -eq 0 ]; then
  printf "  download.tar 잔재 : ${GREEN}0${NC}\n"
else
  printf "  download.tar 잔재 : ${RED}%d${NC}   (0이어야 정상)\n" "$tar_count"
fi
echo

if [ "${#missing[@]}" -eq 0 ] && [ "$part_count" -eq 0 ] && [ "$tar_count" -eq 0 ]; then
  printf "${GREEN}${BOLD}✓ 모든 zip 파일이 정상적으로 다운로드되었습니다.${NC}\n"
  echo "  (단, zip 내부 무결성은 별도 검증 필요: ./verify_zips.sh)"
  exit 0
fi

printf "${YELLOW}${BOLD}✗ 이상 발견:${NC}\n"
[ "${#missing[@]}" -gt 0 ] && printf "  - 누락 파일: ${YELLOW}%d건${NC}\n" "${#missing[@]}"
[ "$part_count" -gt 0 ] && printf "  - part 잔재: ${YELLOW}%d건${NC}\n" "$part_count"
[ "$tar_count" -gt 0 ] && printf "  - tar 잔재 : ${YELLOW}%d건${NC}\n" "$tar_count"
echo

if [ "${#missing[@]}" -gt 0 ] && [ "$SHOW_DETAILS" = "1" ]; then
  printf "${BOLD}📋 누락된 파일 상세${NC}\n"
  printf -- "─────────────────────────────────────────────────────────────────────\n"
  printf "%-50s %-12s %-10s\n" "파일명(정규화)" "용량" "filekey"
  printf -- "─────────────────────────────────────────────────────────────────────\n"

  TMPSORT=$(mktemp); trap "rm -f $TMPSORT" EXIT
  printf '%s\n' "${missing[@]}" | sort > "$TMPSORT"

  filekeys_csv=""
  while IFS= read -r name; do
    info="${filelist_info[$name]}"
    size="${info%|*}"; key="${info#*|}"
    printf "%-50s %-12s %-10s\n" "$name" "$size" "$key"
    [ -z "$filekeys_csv" ] && filekeys_csv="$key" || filekeys_csv="${filekeys_csv},${key}"
  done < "$TMPSORT"

  printf -- "─────────────────────────────────────────────────────────────────────\n"
  echo
  printf "${BOLD}💡 복구 방법${NC}\n"
  echo "  (A) 자동 복구:    ./repair_aihub.sh"
  echo "  (B) 수동 명령:    aihubshell -mode d -datasetkey $DATASET_KEY \\"
  echo "                                -filekey '$filekeys_csv' \\"
  echo "                                -aihubapikey \"\$AIHUB_APIKEY\""
fi

exit 1