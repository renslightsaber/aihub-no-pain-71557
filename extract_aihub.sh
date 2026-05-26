#!/bin/bash
# ============================================================
# extract_aihub.sh
# AI Hub 71557 데이터셋 4개 zip 패키지를 ./extracted/ 로 압축 해제.
#
# 기대하는 zips 구조 (reorganize_to_zips.sh 후):
#   ./zips/138.뉴스_대본_및_앵커_음성_데이터/01-1.정식개방데이터/
#       Training/01.원천데이터/{TS.z01, TS.z02, TS.zip}
#       Training/02.라벨링데이터/TL.zip
#       Validation/01.원천데이터/VS.zip
#       Validation/02.라벨링데이터/VL.zip
#
# 출력 구조:
#   ./extracted/
#       Training/원천데이터/SPK???/.../*.wav
#       Training/라벨링데이터/SPK???/.../*.json
#       Validation/원천데이터/SPK???/.../*.wav
#       Validation/라벨링데이터/SPK???/.../*.json
#
# 환경변수:
#   ZIPS_ROOT  기본: ./zips/138.뉴스_대본_및_앵커_음성_데이터
#   OUT_ROOT   기본: ./extracted
#   SKIP_TS    1이면 TS 건너뜀 (라벨링/Validation 만 우선 풀고 싶을 때)
#   ONLY       comma-list: ts,tl,vs,vl 중 일부만 (예: ONLY=tl,vl)
# ============================================================
set -eu

ZIPS_ROOT="${ZIPS_ROOT:-./zips/138.뉴스_대본_및_앵커_음성_데이터}"
OUT_ROOT="${OUT_ROOT:-./extracted}"
SKIP_TS="${SKIP_TS:-0}"
ONLY="${ONLY:-}"

[ -d "$ZIPS_ROOT" ] || { echo "[ERROR] ZIPS_ROOT 없음: $ZIPS_ROOT"; exit 1; }

# 의존성
command -v unzip >/dev/null 2>&1 || { echo "[ERROR] unzip 필요"; exit 1; }
command -v 7z    >/dev/null 2>&1 || { echo "[ERROR] 7z 필요 (sudo apt install p7zip-full)"; exit 1; }

TS_ZIP="$ZIPS_ROOT/01-1.정식개방데이터/Training/01.원천데이터/TS.zip"
TL_ZIP="$ZIPS_ROOT/01-1.정식개방데이터/Training/02.라벨링데이터/TL.zip"
VS_ZIP="$ZIPS_ROOT/01-1.정식개방데이터/Validation/01.원천데이터/VS.zip"
VL_ZIP="$ZIPS_ROOT/01-1.정식개방데이터/Validation/02.라벨링데이터/VL.zip"

OUT_TR_AUDIO="$OUT_ROOT/Training/원천데이터"
OUT_TR_LABEL="$OUT_ROOT/Training/라벨링데이터"
OUT_VA_AUDIO="$OUT_ROOT/Validation/원천데이터"
OUT_VA_LABEL="$OUT_ROOT/Validation/라벨링데이터"

mkdir -p "$OUT_TR_AUDIO" "$OUT_TR_LABEL" "$OUT_VA_AUDIO" "$OUT_VA_LABEL"

want() {
  local key="$1"
  [ -z "$ONLY" ] && return 0
  echo ",$ONLY," | grep -q ",$key,"
}

echo "============================================"
echo "  extract_aihub.sh"
echo "  ZIPS_ROOT: $ZIPS_ROOT"
echo "  OUT_ROOT : $OUT_ROOT"
[ -n "$ONLY" ]      && echo "  ONLY     : $ONLY"
[ "$SKIP_TS" = "1" ] && echo "  SKIP_TS  : 1"
echo "============================================"
echo

# 1. TS (multi-volume, ~202 GB → ~287 GB)
if want ts && [ "$SKIP_TS" != "1" ]; then
  if [ -f "$TS_ZIP" ]; then
    echo "[1/4] Training 원천데이터 (TS multi-volume zip)"
    echo "      → $OUT_TR_AUDIO"
    echo "      ⏳ 시간 안내: ~287GB 풀어쓰기. HDD 기준 1~3시간."
    # 7z 는 multi-volume zip 을 네이티브로 풀어줌. 진행률 자동 표시.
    7z x "$TS_ZIP" -o"$OUT_TR_AUDIO" -y -bso0 -bsp1
    echo "      ✓ TS 완료"
  else
    echo "[1/4] TS.zip 없음, 건너뜀: $TS_ZIP"
  fi
  echo
fi

# 2. TL
if want tl; then
  if [ -f "$TL_ZIP" ]; then
    echo "[2/4] Training 라벨링데이터 (TL, 244MB)"
    unzip -q -o "$TL_ZIP" -d "$OUT_TR_LABEL"
    echo "      ✓ TL 완료"
  else
    echo "[2/4] TL.zip 없음, 건너뜀"
  fi
  echo
fi

# 3. VS
if want vs; then
  if [ -f "$VS_ZIP" ]; then
    echo "[3/4] Validation 원천데이터 (VS, 25GB)"
    unzip -q -o "$VS_ZIP" -d "$OUT_VA_AUDIO"
    echo "      ✓ VS 완료"
  else
    echo "[3/4] VS.zip 없음, 건너뜀"
  fi
  echo
fi

# 4. VL
if want vl; then
  if [ -f "$VL_ZIP" ]; then
    echo "[4/4] Validation 라벨링데이터 (VL, 28MB)"
    unzip -q -o "$VL_ZIP" -d "$OUT_VA_LABEL"
    echo "      ✓ VL 완료"
  else
    echo "[4/4] VL.zip 없음, 건너뜀"
  fi
  echo
fi

# 간단 통계
echo "============================================"
echo "  압축 해제 후 통계"
echo "============================================"
for d in "$OUT_TR_AUDIO" "$OUT_TR_LABEL" "$OUT_VA_AUDIO" "$OUT_VA_LABEL"; do
  if [ -d "$d" ]; then
    wav_n=$(find "$d" -name "*.wav" 2>/dev/null | wc -l)
    json_n=$(find "$d" -name "*.json" 2>/dev/null | wc -l)
    printf "  %s\n    wav=%d, json=%d\n" "$d" "$wav_n" "$json_n"
  fi
done

echo
echo "다음 단계: python3 build_metadata.py --extracted ./extracted --output ./metadata.csv"
