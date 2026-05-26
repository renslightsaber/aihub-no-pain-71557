#!/bin/bash
# ============================================================
# repair_aihub.sh (v5)
#
# v5 변경점:
#   - filelist 파싱 로직 정규화 (토큰 기반, 트리 문자 처리)
#   - 디스크 파일명 정규화 매칭 (한글 사이 공백 케이스 대응)
#   - DEBUG=1 모드 추가
#   - 깨진/누락 파일 식별 정확도 개선
#
# 환경변수:
#   AIHUB_APIKEY              (필수)
#   DATASET_KEY               기본: 71349
#   ROOT                      기본: ./133.감성_...
#   FILELIST                  기본: filelist_${DATASET_KEY}.txt
#   BATCH                     기본: 50
#   DRY_RUN                   기본: 0
#   INCLUDE_NEVER_DOWNLOADED  기본: 1
#   DEBUG                     기본: 0
# ============================================================
set -u

DATASET_KEY="${DATASET_KEY:-71557}"
APIKEY="${AIHUB_APIKEY:?환경변수 AIHUB_APIKEY를 먼저 설정하세요.}"
FILELIST="${FILELIST:-filelist_${DATASET_KEY}.txt}"
ROOT="${ROOT:-./138.뉴스_대본_및_앵커_음성_데이터}"
BATCH="${BATCH:-50}"
DRY_RUN="${DRY_RUN:-0}"
INCLUDE_NEVER_DOWNLOADED="${INCLUDE_NEVER_DOWNLOADED:-1}"
DEBUG="${DEBUG:-0}"

for cmd in aihubshell unzip awk grep find sed tr; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] missing: $cmd"; exit 1; }
done
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[ERROR] bash 4.0+ 필요"; exit 1
fi
[ -f "$FILELIST" ] || { echo "[ERROR] filelist 없음: $FILELIST"; exit 1; }
[ -d "$ROOT" ] || { echo "[ERROR] ROOT 없음: $ROOT"; exit 1; }

normalize_name() {
  echo "$1" | tr -d '[:space:]'
}

parse_filelist_line() {
  local line="$1"
  local clean=$(echo "$line" | sed -e 's/[─├└│|]/ /g' -e 's/\r//g')
  local zip_part=$(echo "$clean" | grep -oE '.*\.zip' | head -1)
  [ -z "$zip_part" ] && return 1
  local name_norm=$(echo "$zip_part" | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
  local key=$(echo "$clean" | grep -oE '[0-9]{4,}' | tail -1)
  [ -z "$name_norm" ] || [ -z "$key" ] && return 1
  echo "${name_norm}|${key}"
}

echo "============================================"
echo "  repair_aihub.sh v5"
echo "  DATASET_KEY              : $DATASET_KEY"
echo "  ROOT                     : $ROOT"
echo "  FILELIST                 : $FILELIST"
echo "  BATCH                    : $BATCH"
echo "  DRY_RUN                  : $DRY_RUN"
echo "  INCLUDE_NEVER_DOWNLOADED : $INCLUDE_NEVER_DOWNLOADED"
[ "$DEBUG" = "1" ] && echo "  DEBUG                    : ON"
echo "============================================"

echo
echo "[1/3] 데이터셋 상태 점검 중..."

declare -A status_map        # 정규화 파일명 -> 상태
declare -A raw_name_map      # 정규화 파일명 -> 원본 파일명 (디스크 기준)
declare -A processed_base
declare -A filelist_files    # 정규화 파일명 -> filekey

# 1-A. 모든 zip 무결성 검증 (정규화 키로 저장)
total_zip=$(find "$ROOT" -name "*.zip" 2>/dev/null | wc -l)
echo "    (1-A) zip 무결성 검증 (${total_zip}개)..."
idx=0
while IFS= read -r zip; do
  idx=$((idx+1))
  printf "\r          진행: %d/%d" "$idx" "$total_zip"
  base_raw=$(basename "$zip")
  base_norm=$(normalize_name "$base_raw")
  raw_name_map["$base_norm"]="$base_raw"
  if unzip -tq "$zip" >/dev/null 2>&1; then
    status_map["$base_norm"]="ok"
  else
    status_map["$base_norm"]="broken"
  fi
done < <(find "$ROOT" -name "*.zip" 2>/dev/null)
[ "$total_zip" -gt 0 ] && echo

# 1-B. part 잔재 (정규화 키)
echo "    (1-B) part 잔재 식별..."
total_parts=$(find "$ROOT" -name "*.zip.part*" 2>/dev/null | wc -l)
while IFS= read -r partfile; do
  filename=$(basename "$partfile")
  base_raw=$(echo "$filename" | sed 's/\.part[0-9]*$//')
  base_norm=$(normalize_name "$base_raw")
  [ -n "${processed_base[$base_norm]:-}" ] && continue
  processed_base["$base_norm"]=1
  raw_name_map["$base_norm"]="$base_raw"

  current="${status_map[$base_norm]:-}"
  if [ -z "$current" ]; then
    status_map["$base_norm"]="missing"
  elif [ "$current" = "ok" ]; then
    status_map["$base_norm"]="residue_only"
  fi
done < <(find "$ROOT" -name "*.zip.part*" 2>/dev/null)
echo "          part 파일 총 ${total_parts}개 / 영향 base ${#processed_base[@]}개"

# 1-C. download.tar
tar_count=$(find "$ROOT" -name "download.tar" 2>/dev/null | wc -l)
echo "    (1-C) download.tar 잔재 ${tar_count}개"

# 1-D. filelist 파싱
echo "    (1-D) filelist 파싱..."
total_in_filelist=0
debug_shown=0
while IFS= read -r line || [ -n "$line" ]; do
  parsed=$(parse_filelist_line "$line") || continue
  IFS='|' read -r name key <<< "$parsed"
  filelist_files["$name"]="$key"
  total_in_filelist=$((total_in_filelist+1))
  if [ "$DEBUG" = "1" ] && [ "$debug_shown" -lt 5 ]; then
    echo "          [DEBUG] name=[$name] key=[$key]"
    debug_shown=$((debug_shown+1))
  fi
done < "$FILELIST"
echo "          filelist 등록: ${total_in_filelist}개"

if [ "$total_in_filelist" -eq 0 ]; then
  echo "    [ERROR] filelist 파싱 실패. DEBUG=1 ./repair_aihub.sh 로 진단하세요."
  exit 1
fi

# 1-E. never_downloaded (정규화 키 비교)
never_downloaded=()
for name in "${!filelist_files[@]}"; do
  [ -z "${status_map[$name]:-}" ] && never_downloaded+=("$name")
done
echo "    (1-E) 다운로드 시도 안 됨: ${#never_downloaded[@]}개"

if [ "$INCLUDE_NEVER_DOWNLOADED" = "1" ]; then
  for name in "${never_downloaded[@]}"; do
    status_map["$name"]="never_downloaded"
  done
  echo "          → 재다운로드 대상 포함"
fi

# 1-F. 통계
ok_count=0; broken_count=0; missing_count=0; residue_count=0; never_count=0
unhealthy_normalized=()
for name in "${!status_map[@]}"; do
  case "${status_map[$name]}" in
    ok)               ok_count=$((ok_count+1)) ;;
    broken)           broken_count=$((broken_count+1));   unhealthy_normalized+=("$name") ;;
    missing)          missing_count=$((missing_count+1)); unhealthy_normalized+=("$name") ;;
    residue_only)     residue_count=$((residue_count+1)) ;;
    never_downloaded) never_count=$((never_count+1));     unhealthy_normalized+=("$name") ;;
  esac
done

echo
echo "    === 점검 결과 ==="
echo "    filelist 등록 zip     : $total_in_filelist건"
echo "    --------"
echo "    정상 zip              : $ok_count건"
echo "    깨진 zip              : $broken_count건"
echo "    part만 있고 zip 없음  : $missing_count건"
echo "    zip 정상 + part 잔재  : $residue_count건"
echo "    다운로드 시도 안 됨   : $never_count건"
echo "    → 재다운로드 대상     : ${#unhealthy_normalized[@]}건"

# 50%+ 경고
if [ "$total_in_filelist" -gt 0 ] && [ "${#never_downloaded[@]}" -gt 0 ]; then
  ratio=$(( never_count * 100 / total_in_filelist ))
  if [ "$ratio" -ge 50 ]; then
    echo
    echo "    [WARN] $never_count/$total_in_filelist (${ratio}%)가 다운로드 시도 안 됨."
    echo "           의도된 부분 다운로드라면 INCLUDE_NEVER_DOWNLOADED=0 으로 실행."
  fi
fi

# 1-G. 잔재 정리 (raw 파일명 사용해서 실제 디스크 파일 삭제)
if [ "$DRY_RUN" = "0" ]; then
  echo "    → 잔재 정리 중..."
  [ "$tar_count" -gt 0 ] && find "$ROOT" -name "download.tar" -delete 2>/dev/null

  for name_norm in "${unhealthy_normalized[@]}"; do
    raw="${raw_name_map[$name_norm]:-}"
    if [ -n "$raw" ]; then
      find "$ROOT" -name "${raw}.part*" -delete 2>/dev/null
      find "$ROOT" -name "$raw" -delete 2>/dev/null
    fi
  done
  for name_norm in "${!status_map[@]}"; do
    if [ "${status_map[$name_norm]}" = "residue_only" ]; then
      raw="${raw_name_map[$name_norm]:-}"
      [ -n "$raw" ] && find "$ROOT" -name "${raw}.part*" -delete 2>/dev/null
    fi
  done
  echo "          잔재 정리 완료"
else
  echo "    → [DRY-RUN] 잔재 정리 건너뜀"
fi

if [ "${#unhealthy_normalized[@]}" -eq 0 ]; then
  echo
  echo "  ✓ 재다운로드 필요 없음. 종료."
  exit 0
fi

echo
echo "[2/3] filekey 매핑..."
filekeys=()
unmatched=()
for name in "${unhealthy_normalized[@]}"; do
  key="${filelist_files[$name]:-}"
  if [ -n "$key" ]; then
    filekeys+=("$key")
  else
    unmatched+=("$name")
  fi
done
echo "    매칭: ${#filekeys[@]}건 / 실패: ${#unmatched[@]}건"
if [ "${#unmatched[@]}" -gt 0 ]; then
  echo "    [WARN] 매칭 실패:"
  printf '      - %s\n' "${unmatched[@]}"
fi
if [ "${#filekeys[@]}" -eq 0 ]; then
  echo "  재다운로드할 filekey 없음. 종료."
  exit 1
fi

echo
echo "[3/3] 재다운로드 batch (총 ${#filekeys[@]}개, batch=$BATCH)"
for ((i=0; i<${#filekeys[@]}; i+=BATCH)); do
  batch=("${filekeys[@]:i:BATCH}")
  csv=$(IFS=,; echo "${batch[*]}")
  batch_num=$((i/BATCH+1))
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [DRY-RUN] batch $batch_num (${#batch[@]}개): $csv"
  else
    echo "  >> batch $batch_num (${#batch[@]}개): $csv"
    aihubshell -mode d -datasetkey "$DATASET_KEY" \
      -filekey "$csv" -aihubapikey "$APIKEY"
  fi
done

echo
echo "Done."
[ "$DRY_RUN" = "1" ] && echo "DRY-RUN 모드였습니다. 실제 복구는 DRY_RUN 없이 재실행." \
                    || echo "복구 완료. 다시 ./repair_aihub.sh 로 수렴 확인."