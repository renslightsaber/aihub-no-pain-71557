#!/usr/bin/env python3
"""
build_metadata.py (v2)
─────────────────────────────────────────────────────────
AI Hub 71557 (뉴스 대본 및 앵커 음성 데이터) 의 라벨링 JSON 들을 모두 파싱하여
다음을 한 번에 생성:

  1. metadata.csv                       — 전체 메타데이터 (1행=1발화)
  2. metadatas_per_speaker/SPK???.csv   — 화자별 CSV 분리본
  3. overall_stats.txt                  — 전체 통계
  4. per_speaker_stats.txt              — 화자별 통계
  5. per_sex_stats.txt                  — 성별 통계

경로는 세 컬럼으로 분해:
  - base_dir   : 서버에서 바뀔 수 있는 prefix (기본 /AN202_data12t/tts_datasets/aihub/)
  - audio      : base_dir 기준 상대 경로 (서버 이전 안전)
  - audio_path : base_dir + audio = 절대 경로 (편의)

사용:
    python3 build_metadata.py
    python3 build_metadata.py --extracted ./extracted --base-dir /custom/prefix/
    python3 build_metadata.py --workers 16 --verify-audio
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from multiprocessing import Pool, cpu_count
from pathlib import Path

import pandas as pd
from tqdm import tqdm


DEFAULT_BASE_DIR = "/AN202_data12t/tts_datasets/aihub/"


# ═════════════════════════════════════════════════════════
#  단일 JSON 파서 (워커에서 호출)
# ═════════════════════════════════════════════════════════
def parse_one(args):
    json_path_s, split, label_root_s, audio_root_s, base_dir_s = args
    json_path = Path(json_path_s)
    label_root = Path(label_root_s)
    audio_root = Path(audio_root_s)
    base_dir = Path(base_dir_s)

    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        rel = json_path.relative_to(label_root)
        wav_rel = rel.with_suffix(".wav")
        audio_abs = (audio_root / wav_rel).resolve()

        # base_dir 기준 상대 경로 (서버 이전 대비)
        try:
            audio_rel_to_base = str(audio_abs.relative_to(base_dir))
        except ValueError:
            audio_rel_to_base = str(audio_abs)  # base_dir 밖이면 절대경로

        script = data.get("script", {}) or {}
        speaker = data.get("speaker", {}) or {}
        finfo = data.get("file_information", {}) or {}

        def _f(v, default=0.0):
            try:
                return float(v) if v not in (None, "") else default
            except (TypeError, ValueError):
                return default

        return {
            "split": split,
            "filename": json_path.stem,                       # e.g. SPK014KBSCU001F001
            "base_dir": str(base_dir).rstrip("/") + "/",      # 항상 '/' 로 끝남
            "audio": audio_rel_to_base,
            "audio_path": str(audio_abs),
            "json_path": str(json_path.resolve()),
            # script
            "script_id":     script.get("id"),
            "url":           script.get("url"),
            "title":         script.get("title"),
            "press":         script.get("press"),
            "press_field":   script.get("press_field"),
            "press_date":    script.get("press_date"),
            "index":         script.get("index"),
            "text":          script.get("text"),
            "sentence_type": script.get("sentence_type"),
            "keyword":       script.get("keyword"),
            # speaker
            "speaker_id":    speaker.get("id"),
            "age":           speaker.get("age"),
            "sex":           speaker.get("sex"),
            "job":           speaker.get("job"),
            # file information
            "audio_format":     finfo.get("audio_format"),
            "utterance_start":  _f(finfo.get("utterance_start")),
            "utterance_end":    _f(finfo.get("utterance_end")),
            "audio_duration":   _f(finfo.get("audio_duration")),
            "_error": None,
        }
    except Exception as e:
        return {
            "split": split,
            "json_path": str(json_path),
            "_error": f"{type(e).__name__}: {e}",
        }


# ═════════════════════════════════════════════════════════
#  split 단위 처리
# ═════════════════════════════════════════════════════════
def build_for_split(extracted_root: Path, split: str, base_dir: Path, workers: int) -> pd.DataFrame:
    label_root = extracted_root / split / "라벨링데이터"
    audio_root = extracted_root / split / "원천데이터"

    if not label_root.exists():
        print(f"[WARN] {label_root} 없음, 건너뜀", file=sys.stderr)
        return pd.DataFrame()

    print(f"[{split}] JSON 검색: {label_root}")
    json_files = sorted(label_root.rglob("*.json"))
    if not json_files:
        print(f"[WARN] {split}: JSON 0건", file=sys.stderr)
        return pd.DataFrame()

    print(f"[{split}] {len(json_files):,}개 발견. 파싱 시작 (workers={workers}) ...")
    args_list = [
        (str(jp), split, str(label_root), str(audio_root), str(base_dir))
        for jp in json_files
    ]

    with Pool(workers) as pool:
        records = list(
            tqdm(
                pool.imap_unordered(parse_one, args_list, chunksize=500),
                total=len(args_list),
                desc=f"Parsing {split}",
                unit="json",
            )
        )

    return pd.DataFrame.from_records(records)


# ═════════════════════════════════════════════════════════
#  오디오 존재 점검 (선택)
# ═════════════════════════════════════════════════════════
def add_audio_exists(df: pd.DataFrame, verify: bool) -> pd.DataFrame:
    if not verify or "audio_path" not in df.columns:
        return df
    print("audio 파일 존재 여부 확인 중 ...")
    df["audio_exists"] = [
        Path(p).is_file() if isinstance(p, str) else False
        for p in tqdm(df["audio_path"], unit="file")
    ]
    return df


# ═════════════════════════════════════════════════════════
#  유틸: 시간 포매팅
# ═════════════════════════════════════════════════════════
def fmt_hms(sec) -> str:
    sec = int(sec)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return f"{h:d}:{m:02d}:{s:02d}"


def _ts() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


# ═════════════════════════════════════════════════════════
#  통계 1: 전체 (overall_stats.txt)
# ═════════════════════════════════════════════════════════
def write_overall_stats(df: pd.DataFrame, out_path: Path) -> None:
    L = []
    p = L.append

    p("=" * 72)
    p("전체 오디오 통계  (AI Hub 71557: 뉴스 대본 및 앵커 음성 데이터)")
    p("=" * 72)
    p(f"생성 시각        : {_ts()}")
    p(f"총 발화 수       : {len(df):,}")
    if "split" in df.columns:
        p(f"  Training       : {(df['split'] == 'Training').sum():,}")
        p(f"  Validation     : {(df['split'] == 'Validation').sum():,}")
    p(f"고유 화자 수     : {df['speaker_id'].nunique()}")

    total = df["audio_duration"].sum()
    p(f"총 발화 시간     : {fmt_hms(total)}  ({total:,.0f} 초)")

    p("")
    p("─── 발화 길이 분포 (초) ───")
    desc = df["audio_duration"].describe()
    for k in ("mean", "std", "min", "25%", "50%", "75%", "max"):
        p(f"  {k:6s} : {desc[k]:8.3f}")

    p("")
    p("─── 길이 구간 분포 (PDF 음성길이 구간) ───")
    bins   = [0, 5, 10, 15, 20, 25, 30, 35, 40, 1e9]
    labels = ["00-05초", "06-10초", "11-15초", "16-20초",
              "21-25초", "26-30초", "31-35초", "36-40초", "40초+"]
    cuts = pd.cut(df["audio_duration"], bins=bins, labels=labels,
                  right=True, include_lowest=True)
    vc = cuts.value_counts().reindex(labels, fill_value=0)
    for lab, c in vc.items():
        pct = 100 * c / max(len(df), 1)
        bar = "█" * int(pct / 2)
        p(f"  {lab} : {c:>9,} ({pct:5.2f}%) {bar}")

    def _dist(col_name: str, title: str, width: int = 14):
        p("")
        p(f"─── {title} ───")
        for v, c in df[col_name].value_counts().items():
            pct = 100 * c / max(len(df), 1)
            v_str = str(v)
            p(f"  {v_str:<{width}s} : {c:>9,} ({pct:5.2f}%)")

    _dist("sex",           "성별 분포",        width=6)
    _dist("age",           "연령 분포",        width=6)
    _dist("job",           "직업 분포",        width=14)
    _dist("press",         "언론사 분포",      width=6)
    _dist("press_field",   "보도분야 분포",    width=8)
    _dist("sentence_type", "문장유형 분포",    width=14)

    out_path.write_text("\n".join(L) + "\n", encoding="utf-8")


# ═════════════════════════════════════════════════════════
#  통계 2: 화자별 (per_speaker_stats.txt)
# ═════════════════════════════════════════════════════════
def write_per_speaker_stats(df: pd.DataFrame, out_path: Path) -> None:
    L = []
    p = L.append

    p("=" * 100)
    p("화자별 오디오 통계")
    p("=" * 100)
    p(f"생성 시각      : {_ts()}")
    p(f"고유 화자 수   : {df['speaker_id'].nunique()}")
    p("")

    g = (
        df.groupby("speaker_id", dropna=True)
        .agg(
            sex=("sex", "first"),
            age=("age", "first"),
            job=("job", "first"),
            n=("audio_duration", "count"),
            total_sec=("audio_duration", "sum"),
            mean_sec=("audio_duration", "mean"),
            min_sec=("audio_duration", "min"),
            max_sec=("audio_duration", "max"),
        )
        .sort_values("total_sec", ascending=False)
    )

    header = (
        f"{'speaker_id':<12s} {'sex':<4s} {'age':<6s} {'job':<14s} "
        f"{'n':>8s} {'total':>10s} {'mean':>7s} {'min':>7s} {'max':>7s}"
    )
    p(header)
    p("-" * 100)
    for spk, row in g.iterrows():
        p(
            f"{str(spk):<12s} {str(row.sex):<4s} {str(row.age):<6s} {str(row.job):<14s} "
            f"{int(row.n):>8,} {fmt_hms(row.total_sec):>10s} "
            f"{row.mean_sec:>7.2f} {row.min_sec:>7.2f} {row.max_sec:>7.2f}"
        )
    p("-" * 100)
    p("범례: n=발화 수, total=총 발화 시간(HH:MM:SS), mean/min/max=발화 길이(초)")

    out_path.write_text("\n".join(L) + "\n", encoding="utf-8")


# ═════════════════════════════════════════════════════════
#  통계 3: 성별 (per_sex_stats.txt)
# ═════════════════════════════════════════════════════════
def write_per_sex_stats(df: pd.DataFrame, out_path: Path) -> None:
    L = []
    p = L.append

    p("=" * 72)
    p("성별 오디오 통계")
    p("=" * 72)
    p(f"생성 시각: {_ts()}")
    p("")

    for sex in sorted(df["sex"].dropna().unique()):
        sub = df[df["sex"] == sex]
        n_speakers = sub["speaker_id"].nunique()
        n_files = len(sub)
        total = sub["audio_duration"].sum()
        mean = sub["audio_duration"].mean()
        std = sub["audio_duration"].std()
        med = sub["audio_duration"].median()

        p(f"━━━ {sex} ━━━")
        p(f"  화자 수        : {n_speakers}")
        p(f"  발화 수        : {n_files:,}")
        p(f"  총 발화 시간   : {fmt_hms(total)}  ({total:,.0f} 초)")
        p(f"  평균 길이      : {mean:.3f} 초")
        p(f"  중앙값         : {med:.3f} 초")
        p(f"  표준편차       : {std:.3f} 초")

        p("  연령 분포:")
        for age, c in sub["age"].value_counts().items():
            pct = 100 * c / max(n_files, 1)
            p(f"    {str(age):<8s} : {c:>9,} ({pct:5.2f}%)")

        p("  직업 분포:")
        for job, c in sub["job"].value_counts().items():
            pct = 100 * c / max(n_files, 1)
            p(f"    {str(job):<14s} : {c:>9,} ({pct:5.2f}%)")

        p("  보도분야 분포:")
        for fld, c in sub["press_field"].value_counts().items():
            pct = 100 * c / max(n_files, 1)
            p(f"    {str(fld):<8s} : {c:>9,} ({pct:5.2f}%)")

        p("")

    out_path.write_text("\n".join(L) + "\n", encoding="utf-8")


# ═════════════════════════════════════════════════════════
#  화자별 CSV
# ═════════════════════════════════════════════════════════
def write_per_speaker_csv(df: pd.DataFrame, out_dir: Path) -> Path:
    per_dir = out_dir / "metadatas_per_speaker"
    per_dir.mkdir(parents=True, exist_ok=True)

    speakers = sorted(df["speaker_id"].dropna().unique())
    for spk in tqdm(speakers, desc="화자별 CSV 저장", unit="spk"):
        sub = df[df["speaker_id"] == spk]
        sub.to_csv(per_dir / f"{spk}.csv", index=False, encoding="utf-8-sig")

    return per_dir


# ═════════════════════════════════════════════════════════
#  main
# ═════════════════════════════════════════════════════════
def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--extracted", default="./extracted",
                   help="압축 해제된 루트 (Training/, Validation/ 을 포함)")
    p.add_argument("--output", default="./meta/metadata.csv",
                   help="출력 CSV 경로")
    p.add_argument("--base-dir", default=DEFAULT_BASE_DIR,
                   help="공통 prefix. 서버 이전 시 이 값만 바꾸면 됨")
    p.add_argument("--workers", type=int, default=max(1, cpu_count() - 2),
                   help="병렬 워커 수")
    p.add_argument("--verify-audio", action="store_true",
                   help="각 row 의 audio_path 존재 여부 점검 (느려질 수 있음)")
    p.add_argument("--no-stats", action="store_true",
                   help="통계 txt 3종 생성 안 함")
    p.add_argument("--no-per-speaker", action="store_true",
                   help="화자별 CSV 생성 안 함")
    args = p.parse_args()

    extracted = Path(args.extracted).resolve()
    base_dir = Path(args.base_dir).resolve()
    if not extracted.exists():
        sys.exit(f"[ERROR] extracted 경로 없음: {extracted}")

    print("=" * 60)
    print("build_metadata.py v2")
    print("=" * 60)
    print(f"  --extracted : {extracted}")
    print(f"  --base-dir  : {base_dir}")
    print(f"  --output    : {args.output}")
    print(f"  --workers   : {args.workers}")
    print()

    dfs = []
    for split in ("Training", "Validation"):
        df = build_for_split(extracted, split, base_dir, args.workers)
        if not df.empty:
            dfs.append(df)

    if not dfs:
        sys.exit("[ERROR] 파싱된 데이터 없음")

    full = pd.concat(dfs, ignore_index=True)

    # 에러 분리
    err_mask = full["_error"].notna() if "_error" in full.columns else pd.Series([False] * len(full))
    errors = full[err_mask]
    full = full[~err_mask].drop(columns=["_error"], errors="ignore")
    if not errors.empty:
        err_path = Path(args.output).with_suffix(".errors.csv")
        errors.to_csv(err_path, index=False, encoding="utf-8-sig")
        print(f"[WARN] 파싱 실패 {len(errors):,}건 → {err_path}", file=sys.stderr)

    # wav 존재 여부 (선택)
    full = add_audio_exists(full, args.verify_audio)

    # 정렬
    sort_keys = [k for k in ("split", "speaker_id", "filename") if k in full.columns]
    if sort_keys:
        full = full.sort_values(sort_keys).reset_index(drop=True)

    # 컬럼 순서 정리 (경로 컬럼을 앞쪽으로)
    preferred = [
        "split", "filename",
        "base_dir", "audio", "audio_path", "json_path",
        "speaker_id", "age", "sex", "job",
        "press", "press_field", "press_date",
        "script_id", "url", "title", "index",
        "text", "sentence_type", "keyword",
        "audio_format", "utterance_start", "utterance_end", "audio_duration",
    ]
    if "audio_exists" in full.columns:
        preferred.append("audio_exists")
    cols = [c for c in preferred if c in full.columns] + \
           [c for c in full.columns if c not in preferred]
    full = full[cols]

    # 전체 CSV
    full.to_csv(args.output, index=False, encoding="utf-8-sig")
    print(f"\n✓ {args.output}  ({len(full):,}행, {len(full.columns)}컬럼)")

    out_dir = Path(args.output).parent

    # 통계 3종
    if not args.no_stats:
        overall_path  = out_dir / "overall_stats.txt"
        per_spk_path  = out_dir / "per_speaker_stats.txt"
        per_sex_path  = out_dir / "per_sex_stats.txt"
        write_overall_stats(full,     overall_path)
        write_per_speaker_stats(full, per_spk_path)
        write_per_sex_stats(full,     per_sex_path)
        print(f"✓ {overall_path}")
        print(f"✓ {per_spk_path}")
        print(f"✓ {per_sex_path}")

    # 화자별 CSV
    if not args.no_per_speaker:
        per_dir = write_per_speaker_csv(full, out_dir)
        print(f"✓ {per_dir}/  ({full['speaker_id'].nunique()} 파일)")

    # 요약
    print()
    print("=" * 60)
    print("완료")
    print("=" * 60)
    print(f"  총 행            : {len(full):,}")
    print(f"  컬럼 수          : {len(full.columns)}")
    print(f"  고유 화자 수     : {full['speaker_id'].nunique()}")
    if "audio_duration" in full.columns:
        total_sec = full["audio_duration"].sum()
        print(f"  총 발화 시간     : {fmt_hms(total_sec)} ({total_sec:,.0f} 초)")
    if "audio_exists" in full.columns:
        print(f"  audio 존재(확인) : {int(full['audio_exists'].sum()):,} / {len(full):,}")
    if errors.shape[0]:
        print(f"  파싱 실패        : {len(errors):,}건 (→ .errors.csv)")
    print()


if __name__ == "__main__":
    main()