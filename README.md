# SPIED_2026

시각장애인 보행 보조 iOS 앱. 갤럭시 폰의 카메라/센서를 실시간으로 스트리밍받아
AI로 인도·횡단보도를 인식하고, 경로 이탈이나 위험 요소를 음성으로 안내한다.
현장에 설치된 스마트 횡단보도 신호기(아두이노)와 연동해, 사용자가 방향을 잘못
잡았거나 다 건너지 못했을 때 초록불을 자동으로 연장해준다.

## 주요 기능

- **날씨**: Open-Meteo API로 현재 위치 기준 날씨 표시
- **도보 경로 탐색**: 목적지 검색 + Tmap(SK Open API) 기반 보행자 경로 안내, Kakao
  Maps SDK로 지도 표시
- **실시간 AI 바리어프리 인식**: 갤럭시 폰 카메라 프레임을 세그멘테이션 서버
  (YOLO11)로 전송해 인도 요철, 점자블록, 횡단보도 등을 인식하고 화면에 오버레이
- **횡단보도 이탈 감지**: 인/경사연석 → 횡단보도 표면 인식으로 "지금 횡단보도를
  건너는 중"임을 확정하고, 나침반 방향이 크게 틀어지거나 정상적으로 다 건널
  시간이 되기 전에 횡단보도가 갑자기 안 보이면 방향 이탈로 판단해 음성 경고
- **음성 안내 로그**: 방금까지 안내된 음성 문구들을 화면에서도 확인 가능
  (`VoiceLogView`)
- **음성 명령 사물찾기**: "시각장애인 모드"에서 "find door"처럼 말하면 최신
  인식 결과에서 매칭되는 사물의 좌/가운데/우 위치를 영어 TTS로 안내
  (`VoiceFinderController`)
- **스마트 횡단보도 신호 연동**: 방향 이탈 경고가 뜨면 TCP로 라떼판다 브릿지에
  신호를 보내 초록불(보행 신호)을 5초씩, 최대 4번까지 연장 요청
  (`ArduinoSocket`)
- **오프라인 녹화·재생 테스트**: 실제 주행 녹화본(mp4 + 센서/GPS 타임라인 json)을
  그대로 재생해 라이브와 동일한 파이프라인으로 검증 가능 (`ReplayController`,
  `ReplayView`)

## 아키텍처

```
갤럭시 폰(웹앱)                Mac/서버                        iOS 앱(이 저장소)
─────────────────             ─────────────────                ─────────────────
카메라 + 센서(방향/자이로)      galaxy-bridge 서버(WS, :8080)  ── GalaxyBridgeClient
+ GPS 스트리밍           ──▶   세그멘테이션 서버(:8002, YOLO11) ── SegmentationService
                                                                    │
                                                              SegmentationController
                                                              (횡단보도 상태머신,
                                                               이탈 판단, 음성 경고)
                                                                    │
                                                              ArduinoSocket(TCP :9000)
                                                                    │
                                                              ▼
                                                    라떼판다(Windows) TCP↔시리얼 브릿지
                                                                    │
                                                              ▼
                                                    아두이노 스마트 횡단보도 신호기
                                                    (보행 신호 5초씩 최대 4회 연장)
```

- 갤럭시 브릿지/세그멘테이션 서버, 라떼판다 브릿지·아두이노 펌웨어는 이 저장소
  밖에서 별도로 관리된다. iOS 앱은 이 세 엔드포인트의 IP만 알면 된다.
- `GalaxyBridge.swift` / `WalkingPathView.swift`(카메라·센서, 기본 포트 8080),
  `SegmentationService.swift`(AI 인식 서버, 기본 포트 8002),
  `ArduinoSocket.swift`(횡단보도 신호기 브릿지, 기본 포트 9000) — 세 곳 모두
  로컬 네트워크 IP가 바뀔 때마다 해당 파일의 host 기본값을 갱신해야 한다.

## 횡단보도 이탈 판단 로직 (`SegmentationController`)

1. 경사연석(`outcurb_slide*`)을 본 뒤 짧은 시간 안에 실제 횡단보도 표면까지
   보이면, 경사연석을 처음 본 순간의 나침반 방향을 "정방향"으로 고정하고
   추적을 시작한다. 경사연석을 놓쳤거나 이미 횡단보도 위에서 앱을 켠 경우엔
   표면만으로도(일정 시간 꾸준히 보이면) 추적을 시작한다.
2. 추적 중 나침반 방향이 기준 방향에서 크게(30°+) 벗어난 채로 일정 시간
   유지되면 "Turn left/right" 보정 안내.
3. 몸은 정면을 향한 채 대각선으로 빠지는 경우(나침반만으로는 못 잡음)를 위해,
   아직 정상적으로 다 건널 시간이 되지 않았는데 횡단보도가 한동안 안 보이면
   "Crosswalk no longer visible" 경고.
4. 두 경고 모두 발생 시 `ArduinoSocket.extendGreen()`으로 보행 신호 연장을 요청.

> 이 로직은 실제 5개 테스트 녹화본을 세그멘테이션 서버에 직접 돌려 검증했다.
> 짧고 확신도 낮은 감지 신호는 진짜 순간적 이탈과 모델의 우연한 오탐이 거의
> 구별되지 않는다는 게 확인됐고, 현재는 "오탐이 가끔 있더라도 진짜 이탈을
> 놓치지 않는" 쪽으로 민감도를 맞춰뒀다. 근거와 트레이드오프는
> `SegmentationController.swift`의 `.tracking` case 주석 참고.

## 실행 방법

1. `SPIED_2026/Secrets.swift.example`을 같은 폴더에 `Secrets.swift`로 복사하고
   Tmap 앱 키를 채운다 (`.gitignore`에 등록되어 git에는 올라가지 않는다).
2. `GalaxyBridge.swift`, `WalkingPathView.swift`, `SegmentationService.swift`,
   `ArduinoSocket.swift`의 기본 host를 현재 네트워크의 실제 IP로 맞춘다.
3. Xcode에서 `SPIED_2026.xcodeproj`를 열고 시뮬레이터 또는 실기기에서 실행.
4. 갤럭시 폰에서 galaxy-bridge 웹앱을 열어 같은 서버로 스트리밍을 시작하면
   앱 화면에 카메라 피드가 표시된다.

### 오프라인 재생 테스트만 하고 싶을 때

세그멘테이션 서버만 떠 있으면 되고(갤럭시 폰/아두이노는 없어도 됨), 앱의
"재생 테스트" 화면에서 녹화된 mp4 + json 타임라인을 불러와 동일한 AI 인식·
이탈 감지 파이프라인을 그대로 재현해 볼 수 있다.

## 주요 파일

| 파일 | 역할 |
|---|---|
| `GalaxyBridge.swift` | 갤럭시 폰 카메라/센서/GPS WebSocket 클라이언트 |
| `SegmentationService.swift` | 세그멘테이션 서버 HTTP 클라이언트 |
| `SegmentationController.swift` | 인식 루프 + 횡단보도 이탈 상태머신 + 음성 경고 |
| `ArduinoSocket.swift` | 스마트 횡단보도 신호기 TCP 브릿지 |
| `DetectionAnnouncer.swift` | TTS 안내 + 화면용 안내 로그 |
| `VoiceLogView.swift` | 안내 로그 화면 표시 |
| `VoiceFinderController.swift` | 음성 명령으로 사물 위치 안내 |
| `WalkingPathView.swift` | 실시간 화면(카메라 + 지도 + 경로 탐색) |
| `ReplayController.swift` / `ReplayView.swift` | 녹화본 재생 테스트 |
| `RouteService.swift` | Tmap 지오코딩 + 보행자 경로 조회 |
| `WeatherViewModel.swift` 외 `Weather*.swift` | 날씨 화면 |
