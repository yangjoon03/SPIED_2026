# galaxy-bridge

iOS 앱(`SPIED_2026`)이 실시간으로 붙는 두 개의 로컬 서버.

- **`server.js`** — 갤럭시 폰(`public/index.html`)에서 카메라/센서/GPS를 받아
  WebSocket으로 Xcode 앱에 그대로 중계하는 HTTPS 서버 (기본 포트 8080).
- **`local_segmentation_server.py`** — 카메라 프레임을 받아 YOLO11(`last.pt`)로
  바리어프리 요소를 인식해 돌려주는 FastAPI 서버 (기본 포트 8002).

두 서버 모두 같은 Mac(또는 같은 LAN의 다른 머신)에서 띄우고, iOS 앱 쪽
(`GalaxyBridge.swift`, `WalkingPathView.swift`, `SegmentationService.swift`)의
host 기본값을 그 머신의 실제 IP로 맞추면 된다.

## galaxy-bridge 서버 (카메라/센서 중계, :8080)

```bash
npm install
```

HTTPS이므로 자체서명 인증서가 필요하다 (모바일 브라우저의 카메라 권한
(`getUserMedia`)이 HTTPS 컨텍스트를 요구하기 때문). 저장소에는 개인키를 올리지
않으므로 처음 한 번만 로컬에서 직접 생성한다:

```bash
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=localhost"
```

```bash
node server.js
```

실행하면 콘솔에 갤럭시 폰에서 열 주소(`https://<이 머신의 IP>:8080`)와 Xcode가
붙을 WebSocket 주소가 출력된다. 자체서명 인증서라 폰 브라우저에서 처음 열 때
"안전하지 않음" 경고를 수동으로 허용해야 한다.

## 세그멘테이션 서버 (AI 인식, :8002)

```bash
conda activate <YOLO/ultralytics/torch가 설치된 환경>
python local_segmentation_server.py
```

`last.pt`는 이 저장소에 포함된 학습된 YOLO11 가중치다. `/health`, `/predict`
계약은 iOS 앱이 붙는 원격 추론 서버와 동일해서, 앱 쪽은 `SegmentationService.swift`의
`baseURL`만 바꾸면 로컬/원격 서버를 코드 수정 없이 오갈 수 있다.

Apple Silicon(MPS)에서는 서버 기동 시 자동으로 워밍업 추론을 한 번 돌려서,
Metal 셰이더 컴파일로 인한 첫 요청 지연(15~20초)을 사용자가 겪지 않게 한다.

## 포함되지 않은 것

- `cert.pem`, `key.pem` — 자체서명 개인키라 git에 올리지 않는다. 위 openssl
  명령으로 로컬에서 재생성.
- `node_modules/` — `npm install`로 재생성.
