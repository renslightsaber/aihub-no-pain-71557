# 상세 사용 가이드 (USAGE)

AI Hub 데이터셋 **71557 (뉴스 대본 및 앵커 음성 데이터)** 를 처음 다운로드해서 학습에 쓸 수 있는 형태까지 가공하는 전체 흐름을 단계별로 안내합니다.

> 👋 처음 보시는 분은 0번부터 차례대로 진행하세요. 이미 다운로드는 끝났다면 [2번](#2-폴더-재구성) 부터 보시면 됩니다.

---

## 목차

- [0. 사전 준비](#0-사전-준비)
- [1. 다운로드](#1-다운로드)
- [2. 폴더 재구성](#2-폴더-재구성)
- [3. 무결성 검증](#3-무결성-검증)
- [4. 압축 해제](#4-압축-해제)
- [5. 메타데이터 생성](#5-메타데이터-생성)
- [6. 노트북 탐색](#6-노트북-탐색)
- [7. 트러블슈팅](#7-트러블슈팅)
- [부록: 단계별 예상 시간](#부록-단계별-예상-시간)

---

## 0. 사전 준비

### 0.1 디스크 공간

| 용도 | 크기 |
|---|---|
| 다운로드 zip 보관 | ~227 GB |
| 압축 해제 후 wav + json | ~315 GB |
| 작업 임시 공간 (권장 여유) | ~50 GB |
| **합계 권장** | **최소 600 GB** |

### 0.2 시스템 패키지

```bash
sudo apt update
sudo apt install -y p7zip-full unzip
```

> ⚠️ **`p7zip-full` 은 필수입니다.** multi-volume zip (TS.z01 + TS.z02 + TS.zip) 을 풀려면 `7z` 가 필요합니다. `unzip` 만으로는 안 됩니다.

### 0.3 aihubshell 설치

[AI Hub 공식 안내](https://aihub.or.kr) 의 절차에 따라 설치합니다. 일반적으로:

```bash
curl -O https://api.aihub.or.kr/api/aihubshell.do
chmod +x aihubshell.do
sudo mv aihubshell.do /usr/bin/aihubshell

# 설치 확인
aihubshell -version
```

### 0.4 AI Hub API 키

1. https://aihub.or.kr 회원가입 + 로그인
2. **마이페이지 → 인증키 신청** 으로 API 키 발급
3. 데이터셋 71557 페이지에서 **다운로드 권한 신청** → 승인 대기 (보통 1~3 영업일)
4. 발급받은 키를 환경변수로 등록:
   ```bash
   export AIHUB_APIKEY="여기에-API-키"

   # 영구 등록은 ~/.bashrc 또는 ~/.zshrc 에 위 줄 추가
   ```

### 0.5 Python 패키지

```bash
pip install -r requirements.txt
```

`requirements.txt` 내용:
```
pandas>=1.5
tqdm>=4.60
jupyter
notebook
ipywidgets>=7.6
```

### 0.6 작업 디렉토리

깔끔한 작업 디렉토리를 하나 만들고 거기로 이동:

```bash
mkdir -p /path/to/news_anchor_tts_dataset
cd /path/to/news_anchor_tts_dataset

# 이 레포 스크립트들을 복사하거나 clone
git clone https://github.com/renslightsaber/aihub-no-pain-71557.git .
```

---

## 1. 다운로드

작업 디렉토리에서:

```bash
aihubshell -mode d -datasetkey 71557 -aihubapikey "$AIHUB_APIKEY"
```

다운로드되는 파일들:

| 파일 | 크기 | filekey | 설명 |
|---|---|---|---|
| `TS.z01` | 100 GB | 558636 | Training 음성 — multi-volume part 1 |
| `TS.z02` | 100 GB | 558637 | Training 음성 — multi-volume part 2 |
| `TS.zip` | 2 GB | 558638 | Training 음성 — central directory |
| `TL.zip` | 244 MB | 558639 | Training 라벨링 JSON |
| `VS.zip` | 25 GB | 558640 | Validation 음성 |
| `VL.zip` | 28 MB | 558641 | Validation 라벨링 JSON |

⏱️ 네트워크 환경에 따라 **수 시간 ~ 하루** 정도 걸립니다. `byobu` 또는 `tmux` 안에서 돌리세요.

> 💡 **TS.z01, TS.z02, TS.zip 은 한 세트입니다.** 셋이 같은 디렉토리에 모두 있어야 압축 해제가 가능합니다. 하나라도 빠지면 안 됩니다.

### 1.1 다운로드 진단

다운로드가 도중에 끊겼거나 누락된 파일이 있는지 확인:

```bash
./check_aihub.sh
```

이 스크립트는:
- `filelist_71557.txt` 와 디스크 파일을 비교
- 누락된 파일 / `.part` 잔재 / `download.tar` 잔재를 감지
- 누락 시 어떤 filekey 를 재다운로드해야 하는지 알려줌

### 1.2 자동 복구

누락이 있다면:

```bash
./repair_aihub.sh
```

다음을 자동으로 수행:
1. 모든 zip 의 무결성 점검
2. 깨졌거나 누락된 파일 식별
3. multi-volume 그룹 단위로 묶어 재다운로드 (TS 가 깨졌으면 z01/z02/zip 모두)

### 1.3 다운로드 후 확인

`check_aihub.sh` 가 `✓ 모든 zip 파일이 정상적으로 다운로드되었습니다.` 를 출력하면 다음 단계로.

---

## 2. 폴더 재구성

`aihubshell` 이 다운로드한 트리는 작업 디렉토리에 곧장 펼쳐집니다. 이걸 `zips/` 폴더로 모아 작업 공간을 깔끔하게 만듭니다.

```bash
./reorganize_to_zips.sh
```

**전:**
```
./138.뉴스_대본_및_앵커_음성_데이터/...
```

**후:**
```
./zips/138.뉴스_대본_및_앵커_음성_데이터/01-1.정식개방데이터/
    ├── Training/
    │   ├── 01.원천데이터/{TS.z01, TS.z02, TS.zip}
    │   └── 02.라벨링데이터/TL.zip
    └── Validation/
        ├── 01.원천데이터/VS.zip
        └── 02.라벨링데이터/VL.zip
```

같은 파일시스템 안의 `mv` 라 즉시 끝납니다.

---

## 3. 무결성 검증

### 3.1 빠른 검증 (권장)

```bash
./verify_zips.sh
```

- multi-volume 그룹을 자동 감지
- 메인 zip 의 **central directory 만 읽어** 빠르게 검증 (몇 초)
- false positive 없음

> 💡 일상적으로는 이거면 충분합니다. 다음 단계의 `7z x` 가 압축을 풀면서 CRC 를 자동 검증하기 때문에 정밀 검증은 사실상 중복입니다.

### 3.2 정밀 검증 (선택)

데이터 본문까지 CRC 검증하고 싶다면:

```bash
DEEP=1 ./verify_zips.sh
```

내부적으로 `7z t` 를 사용해 모든 볼륨의 모든 파일을 읽어 CRC 비교. ⏱️ **HDD 30분~2시간**.

스크립트가 다음과 같이 예상 시간을 알려주고 `y/N` 확인을 받습니다:

```
🔗 multi-volume zip 그룹 1개 감지 (합계 약 202.3 GB)
    - ./zips/.../TS.zip

[WARN] DEEP 모드는 모든 볼륨을 읽습니다.
       예상 시간: HDD 약 34분 / SSD 약 6분
       계속하시려면 y 를 입력하세요 [y/N]: 
```

확인 프롬프트 없이 진행하려면:

```bash
DEEP=1 YES=1 ./verify_zips.sh
```

### 3.3 손상 발견 시

검증에서 깨진 zip 이 나오면 자동 복구:

```bash
./repair_aihub.sh
```

multi-volume zip 의 경우 같은 prefix 의 `.z01`, `.z02`, `.zip` filekey 를 묶어서 같이 받습니다.

---

## 4. 압축 해제

```bash
./extract_aihub.sh
```

내부 순서:
1. **TS** (multi-volume, ~287 GB 해제) → `7z x` 사용
2. **TL** (244 MB, JSON 약 30만 개)
3. **VS** (25 GB)
4. **VL** (28 MB)

⏱️ **HDD 기준 6~8시간, SSD 기준 1.5~3시간.**

### 4.1 백그라운드 실행 (권장)

긴 작업이므로 `byobu` / `tmux` 안에서:

```bash
byobu                              # 새 세션 시작
./extract_aihub.sh
# Ctrl+B, D 로 detach
# 나중에 byobu attach 로 다시 들어옴
```

또는 nohup 으로:
```bash
nohup ./extract_aihub.sh > extract.log 2>&1 &
disown
```

### 4.2 부분 실행 (분할 압축 해제)

라벨링 데이터만 먼저 풀어 metadata 빌드와 노트북 작업을 일찍 시작하고 싶다면:

```bash
# 가벼운 라벨링만 (1~2시간)
ONLY=tl,vl ./extract_aihub.sh

# Validation 음성만 (30~45분)
ONLY=vs ./extract_aihub.sh

# Training 음성만 — 가장 큼 (5~7시간)
ONLY=ts ./extract_aihub.sh
```

### 4.3 진행률 모니터링

별도 byobu/tmux 세션에서:

```bash
# 풀린 wav 개수로 진행률 추정 (목표 343,974개)
watch -n 30 'find ./extracted/Training/원천데이터 -name "*.wav" | wc -l'

# 풀린 JSON 개수 (목표 약 306,728개 + 35,875개)
watch -n 30 'find ./extracted -name "*.json" | wc -l'

# 디스크 활동 확인 — %util 이 0 이 아니면 정상
iostat -x 5

# 프로세스 살아있는지 확인
ps aux | grep -E "7z|unzip|extract" | grep -v grep
# STAT 가 D (uninterruptible sleep, disk I/O) 또는 R (running) 이면 정상
```

### 4.4 왜 이렇게 오래 걸리는가

- WAV 는 비압축(stored) 모드 → CPU 거의 안 쓰고 **순수 I/O bound**
- HDD 에서 시퀀셜 read + write 동시 → 헤드 왕복으로 throughput 절반 이하
- 작은 파일 30만 개 이상 → 메타데이터 작업 오버헤드 큼
- **같은 HDD 에서 병렬 압축 해제는 오히려 더 느려집니다** (헤드 경쟁). 직렬이 정답.

---

## 5. 메타데이터 생성

```bash
python3 build_metadata.py
```

⏱️ 멀티프로세싱으로 약 5~15 분.

### 5.1 산출물

| 파일 | 설명 |
|---|---|
| `metadata.csv` | 1행=1발화. 381,456행 × 24컬럼 |
| `overall_stats.txt` | 전체 통계 (총 시간, 길이 분포, 각종 분포) |
| `per_speaker_stats.txt` | 화자 86명 각각의 통계 |
| `per_sex_stats.txt` | 남/여 통계 |
| `metadatas_per_speaker/SPK???.csv` | 화자별 CSV 분리본 (86개) |

### 5.2 주요 컬럼

| 그룹 | 컬럼 |
|---|---|
| **경로 (서버 이전 안전)** | `base_dir`, `audio`, `audio_path`, `json_path` |
| 분류 | `split`, `filename` |
| script | `script_id`, `url`, `title`, `press`, `press_field`, `press_date`, `index`, `text`, `sentence_type`, `keyword` |
| speaker | `speaker_id`, `age`, `sex`, `job` |
| file | `audio_format`, `utterance_start`, `utterance_end`, `audio_duration` |

### 5.3 경로 컬럼 설계 (서버 이전 안전성)

```
base_dir   = /AN202_data12t/tts_datasets/aihub/
audio      = news_anchor_tts_dataset/extracted/Training/원천데이터/SPK???/.../*.wav
audio_path = base_dir + audio   ← 즉시 사용 가능한 절대 경로
```

다른 서버로 옮긴 뒤:
- 노트북 상단의 `OVERRIDE_BASE_DIR` 변수만 새 prefix 로 바꿔주면
- 모든 `audio_path` 가 자동 갱신

### 5.4 옵션

```bash
# base_dir 변경
python3 build_metadata.py --base-dir /custom/prefix/

# 워커 수 (기본: CPU 코어 수 - 2)
python3 build_metadata.py --workers 16

# 각 audio_path 실존 여부 점검 (느려짐)
python3 build_metadata.py --verify-audio

# 통계 txt 생략
python3 build_metadata.py --no-stats

# 화자별 CSV 생략
python3 build_metadata.py --no-per-speaker

# 출력 경로 변경
python3 build_metadata.py --output ./out/metadata.csv

# 압축 해제 위치 변경
python3 build_metadata.py --extracted /other/path/extracted
```

---

## 6. 노트북 탐색

```bash
jupyter notebook explore_dataset.ipynb
```

### 6.1 가장 단순한 사용

```python
inspect_speaker('SPK014', n=3, random_state=42)
```

→ 화자 메타 카드 + 3개 무작위 샘플 (텍스트·메타·오디오 위젯)

### 6.2 추가 필터

```python
inspect_speaker('SPK014',
                sentence_type='완전직접인용형',  # 작문형 | 요약형 | 완전직접인용형
                press_field='문화',              # 정치 | 경제 | 사회 | 문화 | 국제 | 지역 | 스포츠 | IT과학
                press='KBS',                     # KBS | SBS | MBC | YTN | OBS
                duration_min=10, duration_max=15,
                text='영화',                      # 부분 일치
                n=3, random_state=0)
```

### 6.3 인터랙티브 위젯

마지막 셀의 ipywidgets 폼으로 코드 없이 즉석 검색 가능. 드롭다운에서 화자를 고르고 슬라이더로 샘플 수 조정.

### 6.4 화자별 CSV 로드 (메모리 절약)

전체 `metadata.csv` (~150MB) 대신 한 화자만 다루고 싶을 때:

```python
import pandas as pd
df_spk = pd.read_csv('./metadatas_per_speaker/SPK014.csv')
```

---

## 7. 트러블슈팅

### Q. `unzip -tq TS.zip` 이 항상 깨졌다고 나옵니다

✅ **정상입니다.** TS 는 multi-volume zip (`z01 + z02 + zip` 한 세트) 이라 메인 zip 만 단독 검증할 수 없습니다.

확인 방법:
```bash
cd ./zips/138.뉴스_대본_및_앵커_음성_데이터/01-1.정식개방데이터/Training/01.원천데이터/
unzip -l TS.zip | tail
```

`343,974 files` 같은 합계가 정상 출력되면 데이터는 무결합니다. `unzip -tq` 는 multi-volume 을 제대로 처리하지 못하는 도구의 한계일 뿐입니다.

### Q. `./extract_aihub.sh` 가 멈춘 것 같습니다

⏱️ `unzip -q` 옵션 때문에 진행 메시지가 안 보일 뿐, 대부분 정상 동작 중입니다. 별도 세션에서 확인:

```bash
# 1. 프로세스 살아있는지
ps aux | grep -E "7z|unzip" | grep -v grep
# STAT 가 D 또는 R 이면 정상, T(stopped) 또는 없으면 문제

# 2. 디스크 일하는지
iostat -x 5
# %util > 0, kB_wrtn/s 또는 kB_read/s 에 숫자 있으면 정상

# 3. 파일 개수 증가 확인 (가장 직관적)
watch -n 30 'find ./extracted -name "*.json" -o -name "*.wav" | wc -l'
```

세 신호가 일치하면 정상. 작은 파일 30만 개 풀기는 HDD 에서 1~3시간 정상 범위입니다.

### Q. 같은 디스크의 다른 작업과 충돌해서 너무 느립니다

❌ **HDD 에서 병렬 압축 해제는 직렬보다 느립니다** (헤드 경쟁).

해결책:
1. 큰 작업(TS) 은 다른 디스크 I/O 가 끝난 뒤 단독으로
2. 작은 작업(TL, VL) 은 동시에 풀어도 영향 거의 없음
3. `ONLY=tl,vl ./extract_aihub.sh` 로 분할 실행

### Q. `DEEP=1 ./verify_zips.sh` 가 예상 시간을 넘겨 안 끝납니다

⏱️ 예상치는 베스트케이스(시퀀셜 100MB/s) 기준이라 낙관적입니다. 실제 HDD 는 60MB/s 안팎이고 다른 I/O 와 경쟁하면 30~50MB/s 로 떨어집니다. 202 GB 의 경우 **1~1.5 시간**이 더 현실적입니다.

대안:
- 그냥 `./extract_aihub.sh` 를 바로 실행하세요. `7z x` 가 풀면서 CRC 를 자동 검증합니다. 손상이 있으면 그 시점에 멈춥니다.

### Q. 디스크 공간이 부족해질 것 같습니다

zip 들을 보관하면서 풀려면 총 ~542GB 가 필요합니다. 만약 여유가 정말 빠듯하다면:

1. `./extract_aihub.sh` 완료 + `python3 build_metadata.py` 까지 검증 완료 후
2. `zips/` 폴더를 백업하거나 삭제 (다시 받으려면 시간 걸리므로 백업 권장)

```bash
# 외장 디스크로 백업
mv ./zips /mnt/external/backup_71557_zips
```

### Q. `7z: command not found`

```bash
sudo apt install -y p7zip-full
```

### Q. multi-volume zip 인데 `.z01` 이 없습니다

`./check_aihub.sh` 또는 `./repair_aihub.sh` 를 돌려 다시 받으세요. multi-volume 은 세 파일이 모두 있어야 동작합니다.

### Q. 노트북에서 오디오가 재생되지 않습니다

- `audio_path` 의 실제 파일이 있는지 확인:
  ```python
  from pathlib import Path
  print(Path(df.audio_path.iloc[0]).is_file())
  ```
- 다른 서버로 옮긴 경우 노트북 상단의 `OVERRIDE_BASE_DIR` 설정:
  ```python
  OVERRIDE_BASE_DIR = '/new/prefix/'
  ```

---

## 부록: 단계별 예상 시간

| 단계 | HDD (12TB 7200rpm 기준) | SSD |
|---|---|---|
| 1. 다운로드 | 네트워크 의존 (~수 시간) | 동일 |
| 2. 폴더 재구성 | 즉시 (mv = rename) | 즉시 |
| 3. 검증 FAST | 몇 초 | 몇 초 |
| 3. 검증 DEEP | 30분~2시간 | 5~15분 |
| 4. TS 압축 해제 | 5~7시간 | 1~2시간 |
| 4. TL 압축 해제 | 1~2시간 (작은 파일 30만개) | 20~40분 |
| 4. VS 압축 해제 | 30~45분 | 10분 |
| 4. VL 압축 해제 | 30초 | 즉시 |
| 4. 전체 합계 | **6~8시간** | **1.5~3시간** |
| 5. 메타데이터 빌드 | 5~15분 | 2~5분 |

다른 디스크 I/O 와 경쟁 중이면 위 시간이 1.5~2배 늘어날 수 있습니다.

---

## 참고

- 데이터셋 페이지: https://aihub.or.kr/aihubdata/data/view.do?dataSetSn=71557
- 데이터 설명서: [`docs/2-017_뉴스_대본_및_앵커_음성_데이터_데이터설명서.pdf`](./docs/)
- 구축·활용 가이드라인: [`docs/2-017_뉴스_대본_및_앵커_음성_데이터_구축_활용_가이드라인_v1_0.pdf`](./docs/)
- 레포 메인: [`README.md`](./README.md)
