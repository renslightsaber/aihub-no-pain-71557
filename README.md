# aihub-no-pain-71557

> AI Hub **뉴스 대본 및 앵커 음성 데이터** ([데이터셋 71557](https://aihub.or.kr/aihubdata/data/view.do?dataSetSn=71557)) 을 **고통 없이** 다운로드·검증·압축해제·메타데이터화하는 스크립트 모음.

![bash](https://img.shields.io/badge/bash-4.0%2B-green)
![python](https://img.shields.io/badge/python-3.10%2B-blue)
![license](https://img.shields.io/badge/license-MIT-lightgrey)

---

## 왜 만들었나요

AI Hub 의 대용량 음성 데이터셋, 특히 **multi-volume zip** (`TS.z01 + TS.z02 + TS.zip`) 이 섞여있는 71557 은 평범한 `unzip` 으로 풀려고 하면 함정이 가득합니다.

- 🪤 `unzip -tq TS.zip` → **항상 깨졌다고 거짓 보고** (multi-volume false positive)
- 🪤 `7z t TS.zip` → 정확하지만 HDD 에서 **30분~2시간** 걸림
- 🪤 다운로드는 잘 됐는데 어디서 잘못됐는지 알 길이 없음
- 🪤 1,132시간 / 381,456 파일 / ~287GB 압축 해제에 6~8시간 소요
- 🪤 풀고 나면 라벨링 JSON 80만 개를 일일이 파싱해야 데이터로 쓸 수 있음

이 레포는 위 함정들을 모두 검증된 흐름으로 우회합니다.

---

## 워크플로우

```mermaid
graph LR
    A[1. 다운로드<br/>aihubshell] --> B[2. 폴더 재구성<br/>zips/]
    B --> C[3. 무결성 검증<br/>verify_zips.sh]
    C --> D[4. 압축 해제<br/>extract_aihub.sh]
    D --> E[5. 메타데이터<br/>build_metadata.py]
    E --> F[6. 탐색<br/>Jupyter Notebook]
```

---

## 주요 기능

| 기능 | 스크립트 |
|---|---|
| 다운로드 상태 진단 (multi-volume 인식) | `check_aihub.sh` |
| 누락·손상 파일 자동 복구 | `repair_aihub.sh` |
| 무결성 검증 (FAST 헤더 / DEEP 본문) | `verify_zips.sh` |
| 폴더 재구성 (`zips/` 로 모으기) | `reorganize_to_zips.sh` |
| 4 개 zip 패키지 압축 해제 (7z) | `extract_aihub.sh` |
| 라벨링 JSON 80만+ 개 → CSV | `build_metadata.py` |
| 화자 중심 인터랙티브 탐색 | `explore_dataset.ipynb` |

---

## 데이터셋 한눈에

| 항목 | 값 |
|---|---|
| 데이터셋 ID | **71557** |
| 이름 | 뉴스 대본 및 앵커 음성 데이터 |
| 총 시간 | **1,132 시간** |
| 총 발화 수 | **381,456** |
| 화자 수 | **86 명** (20\~60대, 남/녀, 아나운서 준비생/현직/전직) |
| 언론사 | KBS, SBS, MBC, YTN, OBS |
| 보도 분야 | 정치, 경제, 사회, 문화, 국제, 지역, 스포츠, IT/과학 |
| 문장 유형 | 작문형, 요약형, 완전직접인용형 |
| 음성 포맷 | 44.1kHz / 16bit / Mono WAV |
| 라벨 포맷 | JSON (script + speaker + file_information) |
| 압축 크기 | ~227 GB |
| 압축 해제 후 | ~315 GB |

상세는 [`docs/`](./docs/) 의 데이터 설명서 PDF 참고.

---

## 빠른 시작 (TL;DR)

```bash
# 1. 클론 + 의존성
git clone https://github.com/renslightsaber/aihub-no-pain-71557.git
cd aihub-no-pain-71557
sudo apt install -y p7zip-full unzip
pip install -r requirements.txt

# 2. AI Hub API 키 (마이페이지에서 발급 + 데이터셋 71557 권한 신청)
export AIHUB_APIKEY="여기에-키"

# 3. 다운로드 (수 시간)
aihubshell -mode d -datasetkey 71557 -aihubapikey "$AIHUB_APIKEY"

# 4. 검증·압축해제·메타데이터 한 줄씩
./reorganize_to_zips.sh
./verify_zips.sh
./extract_aihub.sh          # 6~8시간 (HDD)
python3 build_metadata.py

# 5. 노트북으로 탐색
jupyter notebook explore_dataset.ipynb
```

각 단계의 옵션·트러블슈팅은 👉 [**USAGE.md**](./USAGE.md)

---

## 최종 산출물

```
.
├── metadata.csv                       # 통합 메타데이터 (381,456행 × 24컬럼)
├── overall_stats.txt                  # 전체 통계
├── per_speaker_stats.txt              # 화자 86명 각각의 통계
├── per_sex_stats.txt                  # 남/여 비교 통계
├── metadatas_per_speaker/             # 화자별 CSV 분리본
│   ├── SPK003.csv
│   ├── SPK004.csv
│   └── ... (86개)
└── extracted/                         # 압축 해제된 wav + json (~315GB)
    ├── Training/{원천데이터,라벨링데이터}/
    └── Validation/{원천데이터,라벨링데이터}/
```

### `metadata.csv` 컬럼 (24개)

| 그룹 | 컬럼 |
|---|---|
| **경로** | `base_dir`, `audio`, `audio_path`, `json_path` |
| 분류 | `split`, `filename` |
| script | `script_id`, `url`, `title`, `press`, `press_field`, `press_date`, `index`, `text`, `sentence_type`, `keyword` |
| speaker | `speaker_id`, `age`, `sex`, `job` |
| file | `audio_format`, `utterance_start`, `utterance_end`, `audio_duration` |

> 💡 경로 컬럼이 셋으로 분해되어 있는 이유: **서버 이전 안전성**. `base_dir` 만 바꾸면 모든 절대 경로가 자동 갱신됩니다.

---

## 노트북 미리보기

화자 중심 탐색 — 한 줄이면 됩니다:

```python
inspect_speaker('SPK014', n=3, random_state=42)
```

→ 화자 메타정보 카드 + 무작위 3개 샘플의 텍스트·메타·오디오 위젯이 한꺼번에 표시됩니다.

추가 필터도 가능:

```python
inspect_speaker('SPK014',
                sentence_type='완전직접인용형',
                press_field='문화',
                duration_min=10, duration_max=15,
                text='영화',
                n=3)
```

또는 마지막 셀의 **ipywidgets 폼**으로 드롭다운·슬라이더만 가지고 즉석 검색.

---

## 디렉토리 구조

```
aihub-no-pain-71557/
├── README.md                  ← (이 문서)
├── USAGE.md                   ← 상세 사용 가이드
├── requirements.txt
├── filelist_71557.txt         ← AI Hub 의 파일 목록 (검증 기준)
│
├── check_aihub.sh             ← 다운로드 진단
├── repair_aihub.sh            ← 누락 자동 복구
├── verify_zips.sh             ← 무결성 검증 (multi-volume 인식)
├── reorganize_to_zips.sh      ← zips/ 폴더로 정돈
├── extract_aihub.sh           ← 4개 zip 압축 해제
│
├── build_metadata.py          ← JSON 80만 개 → CSV + 통계
├── explore_dataset.ipynb      ← 화자 중심 탐색 노트북
│
└── docs/
    ├── 2-017_뉴스_대본_및_앵커_음성_데이터_데이터설명서.pdf
    └── 2-017_뉴스_대본_및_앵커_음성_데이터_구축_활용_가이드라인_v1_0.pdf
```

---

## 시스템 요구사항

- **OS**: Linux (Ubuntu 22.04+ 검증)
- **Bash**: 4.0+
- **Python**: 3.10+
- **aihubshell**: 25.09.19+
- **p7zip-full** (multi-volume zip 처리에 필수)
- **디스크 여유**: 최소 600 GB 권장 (압축 ~227GB + 해제 ~315GB + 여유)

---

## 라이선스 / 저작권

- **이 레포의 코드**: MIT License
- **AI Hub 데이터**: [AI Hub 이용약관](https://aihub.or.kr) 을 따르며, 데이터 자체는 본 레포에 포함되어 있지 않습니다. 사용자가 직접 다운로드해야 합니다.
- **데이터 원본 출처**: 한국지능정보사회진흥원(NIA), AI Hub. 구축 기관: 타임소프트(주관), 케이엘큐브·코난테크놀로지·에이스솔루션(참여).

---

## 참고 링크

- 🔗 데이터셋 페이지: https://aihub.or.kr/aihubdata/data/view.do?dataSetSn=71557
- 🔗 AI Hub: https://aihub.or.kr
- 📄 데이터 설명서: [`docs/`](./docs/)

---

## 기여 / 이슈

이 레포는 71557 데이터셋에 특화된 워크플로우입니다. 다른 AI Hub 음성 데이터셋에도 비슷한 흐름이 통할 가능성이 있으니, 적용 사례나 문제를 발견하면 이슈로 알려주세요.
