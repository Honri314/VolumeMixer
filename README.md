# VolumeMixer (볼륨믹스)

앱별로 개별 볼륨을 조절할 수 있는 macOS 메뉴바 앱입니다 (Swift, 외부 의존성 0개). macOS 14 이상에서 앱이 재생하는 소리를 프로세스 단위로 가로채고(Per-App Process Tap), 기본 출력으로 섞어 학습니다.

## 다운로드
- 릴리스: https://github.com/Honri314/VolumeMixer/releases (DMG + SHA256)

## 동작 원리 (오디오 라라우트)

```
앱(프로세스) 1마다
  Process Tap(공식 CATap API) 생성
    -> aggregate device(비공개)에 연결
    -> IOProc에서 버퍼를 받아 gain을 곱해 링버퍼에 적
즉, 시스템 기본 출력 오디오 유닛(DefaultOutput AudioUnit)의
render callback에서 모든 앱의 링버퍼를 합쳐 출력
```

- 원본 출력은 `CATapMuteBehaviorWhenTapped`로 음소거되므로 소리가 두 번 나지 않습니다.
- 슬라이더 100% 상태에서 tap을 해제하면 원본 채널로 자연 복귀합니다.
- 링버퍼(FloatRingBuffer)는 스레드 안전(NSLock)이고, 필요 프레임이 부족하면 nil을 드리프트(divert)로 방지합니다.

## 구성 요소 (3개 SwiftPM 타깃)

| 타깃 | 설명 |
|--|--|
| `VolumeMixer` (실행 타깃) | 메뉴바 본체. 인자에 `--cli`가 있으면 CLI 모드로 진입 |
| `MixerShared` | 메뉴바 앱/제어센터 위젯이 공유하는 상태 (App Group UserDefaults) |
| `VolumeMixerControls` | macOS 26+ WidgetKit 제어센터 컨트롤 |

### VolumeMixer 내부 파일
| 파일 | 역할 |
|--|--|
| `main.swift` | 엔트리포인트. `--cli` 판별 후 메뉴바 앱(MenuBarApp) 실행. Dock 아이콘 없음(accessory), SF Symbols 벡터 아이콘 슬라이더(slider.horizontal.3), 팝오버 330px, 실행 1회 자동 오픈, 바깥 클릭 자동 닫힘(전역 마우스 모니터) |
| `App.swift` | 팝오버 SwiftUI 화면(MixerPanelView) 등 전체 UI |
| `MixerEngine.swift` | 핵심 엔진: 앱마다 tap 생성 → aggregate device 연결 → IOProc 게인 적용 링버퍼 적립 → 출력 AU에서 합성. tap 생성/해제/lifecycle 정리 |
| `AudioEngine.swift` | CoreAudio 기능 추상화: `listAudioProcesses` / `createTap` / `destroyTap` 프로토콜 + 구현(heder CoreAudio, 프로세스 이름 보고, 미디어 타이틀) |
| `MixerViewModel.swift` | 뷰모델 — 앱 목록 새로고침, 실시간 볼륨(사용 중 반영)과 확정 볼륨(commit) 함께 구성, 제어 중 앱 추적 |
| `MediaRemoteAdapter.swift` | 현재 재생 앱 파악 등 MediaRemote 연동 |
| `CliTool.swift` | 터미널 디버그 도구 |

## CLI 사용법
```
volume-mixer --cli list           # 현재 오디오 출력 프로세스 나열
volume-mixer --cli tap <pid>      # tap 생성 3초 후 제거 (검증용)
volume-mixer --cli tap <pid> [초] [게인]  # tap 유지하며 게인 적용 검증
volume-mixer --cli version
```

## 제어센터 위젯 (macOS 26+)
- 제어센터는 긴 슬라이더를 못 넣으므로 원터치 컨트롤만 제공:
  - 모두 음소거 토글 (AppIntent)
  - 복원 버튼
- 상태 공유는 App Group UserDefaults(`group.com.volmixer.shared`)로 수행하며, SwiftPM 타깃 간 임포트 문제를 우회하기 위해 동일 키 프로토콜을 컨트롤 모듈에 복제합니다(MixerShared의 키와 문자열이 동일해 호환됩니다).

## server/ (릴리스 미러 서버)
서버 컴퓨터에서 .dmg 다운로드를 제공하는 순수 Node.js 기본 모듈 서 rapporto (`volumemixer-server.js`, Node 내장 http 만 사용):
- `index.html` 다운로드 페이지, 최신 .dmg 탐색(파일명 정렬) 제공
- `download`/`sha256` 경로로 파일·해시 스트림
- `./server & node volumemixer-server.js` → 8470 포트

## 빌드
```
swift build
swift run                      # 메뉴바 앱 실행
swift run VolumeMixer --cli list
swift build -c release
```
macOS 14+ 필요(Per-App tap은 공식 API). 제어센터 위젯은 macOS 26+ 에서만 표시됩니다.
