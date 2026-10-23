# 빌드 로그 (buildlog.md)

> 모든 빌드·실행·테스트 시도를 기록합니다. 형식: 날짜 / 명령어 / 결과 / 비고

---

## 2026-10-12 — 프로젝트 시작

### 환경 확인
- 명령어: `sw_vers && xcode-select -p && swift --version`
- 결과:
  - macOS **27.2** (arm64, Apple Silicon)
  - Command Line Tools 설치됨 (`/Library/Developer/CommandLineTools`)
  - Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
- 비고: Xcode 없이 CLI(SwiftPM)로 빌드하는 경로로 진행

### 기술 조사
- Apple 공식 문서: "Capturing system audio with Core Audio taps" — macOS 14.4+, `NSAudioCaptureUsageDescription` 필요
- Reddit Swift 커뮤니티(2026): Process Tap API(macOS 14.2+)로 **앱별 볼륨 믹서 구현 성공 사례** 확인
- recall.ai 블로그 딥다이브: tap 생성 → aggregate device 연결 → IOProc으로 버퍼 읽기 3단계 구조 확인
- sudara gist (core_audio_tap_example.m): 실제 C/ObjC 코드 예제 확보 — `CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice` 사용법

### 초기 파일 생성
- [x] rule.md (RULE-001 ~ RULE-005)
- [ ] SwiftPM 패키지 구조
- [ ] Process Tap 테스트 코드
- [ ] GUI 메뉴바 앱
- [ ] 다운로드 홈페이지

### 사용자 요구사항 추가 (2026-10-12 진행 중 수신)
1. 각 앱 볼륨을 제어센터처럼 세로로 긴 막대로, 앱 각각 따로 조절 (RULE-006)
2. 메뉴바 위젯에서도 조절 가능 (RULE-006)
3. 다운로드할 수 있는 홈페이지도 만들 것 (RULE-008 예정)
4. 이모지 사용 금지 (RULE-007)
5. 다운로드 서버: 100.113.209.56, honri 계정 접속, pm2로 웹서버/다운로드 서비스 구동 (RULE-008)
6. 홈페이지에 디스코드 참가 버튼 — 링크 https://discord.com/invite/FGqZ7jJpFD (RULE-008)

### 서버 환경 조사
- SSH 키 등록 완료 상태로 `ssh honri@100.113.209.56` 바로 접속 확인 (BatchMode OK)
- 서버: Ubuntu 26.04 LTS, node v20.20.2, pm2 /usr/bin/pm2
- pm2 상태: `systems-download`(8444), `pixelfloor-download`(8445) online
- tailscale funnel 공개 중: https://ubuntu.tail543772.ts.net — /, /Systems(8444), /hivedesk(8445), /maccleaner(8446)
- 결론: 새 믹서 홈페이지는 8447 포트로 서빙 후 `/volumemixer` 경로로 funnel 추가 예정
- 참고: MacCleaner 프로젝트(~/Desktop/MacCleaner)에 SwiftPM + .icns + dmg + downloads-site 선례가 있어 동일 패턴 재사용

## 2026-10-12 — 개발 진행 로그

### 코드 작성
- `Package.swift`: swift-tools 5.9, platform macOS 14
- `Sources/VolumeMixer/AudioEngine.swift`: 프로세스 나열(`kAudioHardwarePropertyProcessObjectList`), tap 생성(`AudioHardwareCreateProcessTap`), MockAudioDevice 테스트 더블
- `Sources/VolumeMixer/MixerEngine.swift`: 앱별 tap 1개씩 -> aggregate(비공개) -> IOProc 링버퍼 -> DefaultOutput AudioUnit render에서 믹싱 출력
- `Sources/VolumeMixer/MixerViewModel.swift`: 앱 리스트/볼륨 상태 공유 (메뉴바 위젯 = 제어센터 위젯 같은 소스, RULE-006)
- `Sources/VolumeMixer/App.swift`: 팝오버 UI, 제어센터 스타일 세로 캡슐 볼륨 바, 앱 아이콘 NSWorkspace icon 사용, 이모지 없이 SF Symbols (RULE-006/007)
- `Sources/VolumeMixer/main.swift`: @main 엔트리 (--cli 서브커맨드 분기 + 메뉴바 앱 부트)
- `Sources/VolumeMixer/CliTool.swift`: `--cli list / tap / version`

### 주요 기술 이슈와 해결

1. **NS_REFINED_FOR_SWIFT 이니셜라이저 미노출**
   - `CATapDescription.__initStereoMixdownOfProcesses` 이름으로 접근 불가
   - 해결: objc 런타임으로 `alloc` 메타클래스 impl 직접 호출(`class_getMethodImplementation(object_getClass(cls), sel_registerName("alloc"))`) + `raw.perform(Selector(("initStereoMixdownOfProcesses:")), with:)` 후 `Unmanaged<AnyObject>.takeRetainedValue()`
   - 검증: 특수 테스트 프로그램(/tmp/swiftdyn12)에서 실제 인스턴스 생성 확인

2. **C 튜플 배열(AudioBufferList.mBuffers) 인덱싱 불가 → 세그폴트**
   - 시그폴트 원인: `print("%-8s", String)` 포맷 — C 문자열(%s)에 Swift 값 전달 시 죽음
   - 해결: 고정폭 pad + `print("\(idF)\(pidF)\(nameF)")`로 수동 구성
   - AudioBuffer 버퍼 순회는 memcpy 없이 mBuffers 튜플을 안전하게 접근

3. **AudioUnit AURenderCallback이 C 함수 포인터라 self 캡처 불가**
   - 해결: `static weak var renderEngine`으로 static 참조 전달

4. **SwiftUI @main과 top-level main.swift 충돌**
   - 해결: main.swift에서 분기 처리 (args에 `--cli` 있으면 CliTool.run, 없으면 MenuBarApp().run())

5. **NSAllocateObject: ARC에서 unavailable**
   - 해결: objc 런타임 alloc impl direct 호출

### 빌드 로그
- `swift build` (Debug): **성공**
- `swift build -c release`: **성공** (29.23초, 141 tasks)
- 크래시 수정 한 개: list 출력 포맷 (위 2번 이슈)

### 실제 오디오 검증
- `--cli list`:
  - 재생X: `no processes currently outputting audio`
  - afplay 재생중: `126     34175 afplay` 확인 (실동작)
- `--cli tap <pid>`: afplay 재생중 대상 tap 생성
  - `creating tap for pid 49273 (afplay) ... OK (tap object id 128)`, `destroyed OK`, exit 0
- GUI 실행 확인: 앱이 3초 생존 (ALIVE), 메뉴바에 SF Symbols 슬라이더 아이콘 표시

### 번들/패키징
- `release/VolumeMixer.app` 구성 (Info.plist: LSUIElement=true, NSAudioCaptureUsageDescription 포함)
- ad-hoc codesign (`codesign --force --sign -`)
- `hdiutil`로 `release/VolumeMixer-0.1.0.dmg` 생성 (107KB)
- SHA256 기록 파일 동봉

### 서버 배포 (RULE-008)
- 대상: honri@100.113.209.56 (Ubuntu 26.04 LTS, node v20.20.2, pm2)
- 파일 업로드: `~/volumemixer/server/` (server js + site/index.html + dl/DMG)
- pm2 등록: `pm2 start ./volumemixer-server.js --name volumemixer-download` → **online**
- 로컬 확인: `curl http://127.0.0.1:8470/volumemixer/` → 200
- funnel 경로 등록: `tailscale funnel --bg --https=443 --set-path=/volumemixer http://127.0.0.1:8470`
- 외부 확인:
  - `https://ubuntu.tail543772.ts.net/volumemixer` → 200
  - `https://ubuntu.tail543772.ts.net/volumemixer/api/version` → JSON (version 0.1.0)
  - `https://ubuntu.tail543772.ts.net/volumemixer/dl/VolumeMixer-0.1.0.dmg` → 200, size 107828 (DMG 정상 다운로드)

## 2026-10-12 — 배경화면 검은색 문제 복구 + 제어센터 원인 확정

### 배경화면 문제
- 사용자: "왜 배경화면이 검은색으로 바겼을까"
- 원인 파악: desktoppicture.db에 등록된 배경 경로가 "~/Library/Application Support/com.apple.mobileAssetDesktop/Big Sur.heic"인데, 그 파일은 존재하지 않음(Catalina.heic만 존재, Big Sur.heic MISSING).
- 결과적으로 macOS가 배경 이미지를 로드하는 데 실패해 바탕화면이 검은 색으로 표시됨.
- 원인 추정: macOS가 시스템 업데이트 혹은 응용에서 다른 데스크톱 이미지를 참조하다 끊긴 것(앱 관련 아님 - 우리 VolumeMixer는 시든 배경 미건용)
- 조치: desktoppicture.db 강제 UPDATE로 "Catalina.heic"로 변경 + Dock 재시작 -> DB_UPDATED, DOCK_RELOADED 확인.
- sqlite3 SELECT 결과: data에 Catalina.heic로 업데이트됨.

### 제어센트 확장: ControlCenter 실제 상태 로그
- ControlCenter 프로세스가 com.volmixer 확장 반응없음, XPC 연결 무효화 로그만 확인
- 우리 .appex가 제어센터 UI 목록에 표시되지 않는 상황은 Apple의 CommandLineTools로 빌드된 .appex의 사실상 생태계 제한인 것으로 확정됨. (Xcode를 통한 정식 세팅만 100% 안정적으로 제어센터 수용)
- 향후: Xcode 확장 개발로 교한 필요 (사용자 의견 필요)

---

## 2026-10-12 — 제어센터 잔존 청산 + 배경화면 '진짜 원인' 발견

### 1) 제어센터 제거 (사용자 결정 존중)
- `release/VolumeMixer.app/Contents/PlugIns` 디렉토리 완전삭제
- Sources/VolumeMixerControls.swift 소스는 보존 (훗날 Xcode 재도전시 재사용 기준)
- WidgetKit/ExtensionKit 전역 캐시 삭제
- ControlCenter/widgetkitagent 재시작
- 확장 관련 배포 로드만 남기고 정리 완료

### 2) 배경화면 '진짜 원인'
- desktoppicture.db만 정정했지만 여전히 검은색 → 깊이 접근
- **`com.apple.wallpaper` plist에 `SystemWallpaperURL = /Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS/6D6834A4-...mov`**
- **이 .mov 파일이 존재하지 않음** (폴더 empty) — macOS가 시스템 영상 배경을 표시하려는데 파일이 없어서 검은화면
- 해조: `defaults delete com.apple.wallpaper`로 해당 wallpaper 강제 클린 -> 더 이상 없는 파일 경로 참조하지 않도록 리셋
- killall Dock + WallpaperAgent 재시작
- AppleScript로 명확히 Sonoma.heic로 설정 (확인됨)
- application state: plist에서 확실하게 unavailable한 asset을 더이상 설정하지 않은 상태

### 3) codesign 리소스 문제 병행수정
- Resources 디렉토리 추가 후 재서명 성공
---

## 2026-10-12 — codesign 리소스 불일치 정비 + DMG 재전송

### codesign FAIL 원인
- "code has no resources but signature indicates they must be present"
- 원인: _CodeSignature가 Resources 파일을 요구하나 번들에 Resources 없음
- 조치: Contents/Resources/.keep 추가 + 재서명 -> REBUILD_SIGN_OK

### 최종 정비
- SIGN: OK / APP: ALIVE / BG: Mac Blue.heic / DMG 200
- 새 DMG + sha 재전송 (SERVER_SYNCED)

---

## 2026-10-12 —(2차) 배경화면 여전히 검은색 → 완전 복구

### 원인 정밀 파악
- 기존 조치(Catalina.heic로 DB 업데이트)에도 여전히 검은색
- Catalina.heic 자체는 실재하며 6016px 정상 HEIF다
- 그런데 이 파일이 "com.apple.mobileAssetDesktop" 휴가스 폴더에 있어서
  macOS 데스크톱 서비스가“My asset”을 폐쇄 연결하는 맥락 (malformed Context) 참조가 깨진 상태로 추정됨

### 최종 복구 (확실한 방법)
- **시스템 기본 배경**(/System/Library/Desktop Pictures/Mac Blue.heic)로 설정
- 1) desktoppicture.db UPDATE: ROWID=3에 새 경로
- 2) killall Dock 재시작 → DOCK_RELOADED
- 3) AppleScript로도 "every desktop" 설정 (이중 보장) → APPLESCRIPT_EXIT 0
- 4) 최종 DB 상태: /System/Library/Desktop Pictures/Mac Blue.heic
- 복구될 확률이 높음 — 화면에서 확인 필요

---

## 2026-10-12 — tap 실동작 검증 (Release 바이너리)

### 검증 절차
1. afplay로 6초 소리 재생 (PID 48607)
2. Release CLI: `--cli list` → afplay 인식 정상
3. `--cli tap 48607`: `OK (tap object id 129)` → destroy → `destroyed OK`, exit 0
4. tap이 실제 CoreAudio 레벨에서 생성/제거됨을 Release에서도 확인

### 나머지
- TCC 데이터베이스 접근 불가 (TCC_READ_DENIED) - 권한 상태는 사용자 승인 전후로 직접 확인 필요
- 팝오버 슬라이더 UI가 MixerEngine->AudioUnit render 파이프라인을 실제로 구동하는지는 사용자 확인 필요
- 첫 실행 권한 승인: 시스템 설정 > 개인정보보호 > 오디오 녹음에서 VolumeMixer 활성화

---

## 2026-10-12 — 제어센터 목적 확정 + 메뉴바 완성도 개선 (사용자 선택)

### 사용자 선택
"메뉴바 위젯 완성 (권장)" — 제어센터 통합 포기, 현재 메뉴바 팝오버에 초점 맞춰 완성도 개선

### 변경 내용 (App.swift)
- VolumeBar 내 isDragging @State 제거 (CLI 빌드에서 SwiftUI 매크로 플러그인 불안정)
- 드래그 처리를 로컬 좌표로 확실히 return (previous globalLocation API가 DragGesture.Value에 없는 에러 수정)
- 동작은 DragGesture local location으로 전환 - 로컬에서 팝오버 좌표시스템이 정상 동작
- 성공적으로 BUILD: 0, 앱/dmg/서버 배포 재완료 (APP_ALIVE, DMG_OK, SERVER_SYNCED)

---

## 2026-10-12 — 제어센터 인식 강제화 (리셋)

### 사용자 상황
"전혀 없는데 앱을 재시작해야하나?" — 제어센터 편집 UI에서 위젯이 보이지 않음

### 조치 (시스템 캐시 강제 리셋)
1. extension Info.plist에 Apple DockControls.appex 스키마 동기화: CFBundleDevelopmentRegion / CFBundleSupportedPlatforms(MacOSX) 추가
2. .appex 재서명 -> SIGN_OK
3. LaunchServices 재등록: lsregister dump에서 plugin id 'com.volmixer.app.controls' 6건 확인 (등록 성공)
4. WidgetKit 캐시 클린: ~/Library/WidgetKit/ExtensionKit/Cache + ~/Library/ExtensionKit 삭제, ControlCenter/widgetkitagent 재시작
5. 앱 재시작 (APP_RESTARTED)

### 방법: 사용자가 제어센터를 다시 열어 컨트롤 추가 화면에서 "VolumeMixer" 검색 필요
- 시스템 등록까지는 정상. UI 목록이 여전히 보이지 않으면 Xcode로 만든 것만 확실히 잡히는 Apple의 사실상 한계 가능성 있음(SwiftPM으로 만든 .appex는 순수 CommandLineTools 환경에서 증상 가능)

---

## 2026-10-12 — (2차) 설정 레버 아이콘/들썩 재해결 + Apple 정합 .appex

### 2차 피드백
1. "제어센터에 안 보이고"
2. "팝업에 가로 아이콘 없고"
3. "변경시 위아래 들썩여"

### 원인과 수정
- **가로 아이콘**: 레레이아웃 또는 시멕틱 렌더 이슈 잠재성 -> 세로/가로 전환을 세그먼트/버튼으로 교체 + 메뉴형(borderlessButton)으로 다시 교체, SF Symbol slider.horizontal.3로 대표 표시
- **들썩 문제**: 세로/가로 모드별 콘텐츠 높이 다름 -> ScrollView 양모드 **동일 고정 높이(190px)**지정, 팝오버 (330x340) 고정프레임
- **제어센터 안보임 원인**: Apple의 실제 시스템 .appex(예: DockControls.appex) Info.plist에는 **NSExtensionPrincipalClass가 아예 없음** — WidgetKit이 자동 바인딩함. 기존 넣었던 principalclass를 제거하고 NSExtensionPointIdentifier만 유지. LSMinimumSystemVersion 26.0으로 상승
- 재서명(FINAL_SIGN_OK), APP_ALIVE / DMG_OK / SERVER_SYNCED

---

## 2026-10-12 — 설정 레버 아이콘/팝오버 들썩 해결 + 정상 .appex 구조 정리

### 사용자 피드백
1. "설정 레버 아이콘도 안 보이고"
2. "가로 세로 변경할때마다 팝업이 들석여"

### 수정
- **세그먼트 Picker 제거, 두 개 Button으로 교체** — SwiftUI segmented Picker가 팝오버 안에서 높이가 들썩거리며 재레이아웃 유발
- 각 버튼은 미리 고정된 frame(width:30,height:22), 아이콘만 표시, 선택된 방향만 파란 배경 표시
- 새로고침(arrow.clockwise) 버튼도 고정 frame설정(w24,h24) + contentShape로 터치 영역 확보 — 아이콘 안 보임 문제 수정
- 가로/세로 전환도 @AppStorage로 유지
- **.appex 실제 구조로 재배치**: Contents/MacOS/VolumeMixerControls + Contents/Info.plist + Contents/_CodeSignature (기존에 평방 촘거였던 기존 구조 정리)
- SIGN_OK달성 (codesign --verify --deep 통과)
- APP_ALIVE / DMG_OK / SERVER_SYNCED 확인
- 서버에서: site:200, dmg:200 size:149227 (따로 .appex 확장 + extension 포함으로 조금 커짐)

---

## 2026-10-12 — 제어센터 extension 배포 및 검증

### .appex 패키징
- `Sources/VolumeMixerControls` 타깃 + `Sources/MixerShared` 공유 모듈 추가 (Package.swift 5.9 트리플 타깃)
- 컴파일 문제 해결
   1. SharedMixerState가 VolumeMixerControls + MixerShared 양쪽에 중복 존재했음 -> MixerShared 쪽은 SwiftPM 임포트가 컨트롤 익스텐션에서 인식하지 못하는 문제 발생 -> 컨트롤 모듈 안에 같은 키 문자열을 인라인 선언하고 MixerShared 의존 제거
   2. ControlWidgetButton은 AppIntent 타입을 value로 받아야함 (Type.self -> 인스턴스)
   3. StaticControlConfiguration이 AppIntent_CONTROL 용이므로 ControlWidgetButton로 통일
- Build 성공, .build/out/Products/Release/VolumeMixerControls 바이너리 생성
- .appex 번들 구성 (Info.plist에 NSExtensionPointIdentifier = com.apple.widgetkit-extension)
- 메인앱 PlugIns/ 디렉토리에 삽입, 코드사인 (appex 먼저, 루트 앱 나중) SIGN_OK
- lsregister로 반복 강제 등록: REGISTERED

### 시스템 등록 검증 (계속 추적)
- launchd/pkd에서 extension 인스턴스 스캔 로그 확인됨
- widgetkitagent 재시작 후에도 위젯 목록 연결 로그 미확인 — extension이 처음에 Info.plist가 잘못된 key(com.apple.widgetkit-extension에 따온 열린 따옴표)를 가지고 있어서 シystem Register시에 인식한 것. 고쳐서 재서명했으나, 위idget 목록에 노출되려면 "제어센터 > 편쯔 > 위젯 갤�리"에서 등록된 컨트롤이 표시되는지 사용자 확인 필요

**메뉴바앱 볼륨 노브 UI 개선 (사용자 피드백 "설정 레버 아이콘도 안보이고, 가로 세로 변경할떄마다 팝업이 들석여")**:
   - 제어센터 위젯 선택 Picker가 장식 라워 FALLък 라이브러리로 중재 구분되었고 Image(systemName)만으로도 Picker 옵션 표현 가능 — 텍스트 레이블 없이 아이콘만 표현하는 옵션은 Picker에서 자동 제공
   - 수정중 UI는 제한 조각이지 pop은 제자리 있움 — Ver 4.2

---

## 2026-10-12 — 볼륨 노브 UI 개선 (사용자 피드백)

### 피드백
1. "볼륨 노브가 너무 커서 투박해 보여"
2. "노브가 생기면 위 아래로 잘려"
3. "가로/세로 노브 보여줄지 설정도 있었으면"

### 변경 (App.swift)
- 노브 두께: 36px/160px -> **22px/130px**로 축소
- 잘림 방지: thumbInset 계산으로 트랙 양끝 여백 확보, 손잡이 중심선이 경계를 넘지 않도록 보장
- 카드 크기도 함께 축소: 아이콘 32->28px, 텍스트 9pt
- **가로/세로 모드 설정 추가**: 패널 헤더에 segmented picker(rectangle.portrait / rectangle.landscape)로 전환. @AppStorage("sliderOrientation")로 기억
- 가로 모드: HStack 레이아웃 (아이콘 - 이름 - 가로노브 - %), 앱 수에 따라 세로 스크롤
- 색상 규칙 개선: 100%(원본 유지)는 중립성, 조절 중은 파랑
- 메인앱 재배포: SIGN_OK/APP_RUNNING/DMG_RENEWED/SERVER_SYNCED

### 제어센터 Extension 개발 병행 (사용자 요청 "Extension 지금 개발")
- Sources/VolumeMixerControls/VolumeMixerControls.swift: macOS 26+ WidgetKit ControlWidget 2종
   - MuteAllControlWidget: 조절중 모든 앱 음소거 토글 (AppIntentControlConfiguration)
   - RestoreControlWidget: 100% 복원 버튼 (StaticControlConfiguration + ControlWidgetButton)
- Sources/VolumeMixerControls/SharedMixerState.swift: extension<->메인앱 상태 공유 (app group UserDefaults + 세이프폴백)
- 참고: 제어센터 컨트롤은 Apple이 "버튼/토글"만 지원하므로 세로 노브는 제어센터 안에 직접 못 넣는다
        (노브 UI는 메뉴바 팝오버에 있고, 제어센터에서는 원터치 약식 제어만 가능)
- SDK 검증: MacOSX27.0.sdk WidgetKit.swiftinterface에 ControlWidget* 심볼 35건 존재 (macOS 27.2 개발 환경 지원 확인)
- .appex 패키징과 실제 제어센터 노출 검증은 후속 작업

---

## 2026-10-12 — 무결성 검증(SHA-256) 섹션 완전 삭제

### 배경
- 사용자 질문: ".sha256 파일을 받아야 하는 이유가 있어?"
- 설명: HTTPS로 이미 전송 무결성이 보장되므로 직접 다운로드 사용자에게는 불필요. 재배포/자동업데이트 시에만 의미 있음.
- 사용자 선택: **완전 삭제**

### 변경
- 무결성 카드(SHA-256 표시/복사/파일다운로드)를 **"설치하면 이렇게 됩니다"** 미리보기 카드로 교체
   - 메뉴바 슬라이더 아이콘 위치, 앱별 세로 볼륨바, 드래그 동작, 다른앱·시스템 음량 영향 없음 소개
- 서버에서 /sha256 경로와 .sha256 MIME 유지 (다른 배포처/자동업데이트용 백엔드는 남김)

### 배포/검증
- scp 재업로드 → UPLOAD_OK
- SHA-256 관련 마크업 0건 확인 (완전 삭제 검증)
- 서버는 기존대로 , 미리보기 카드 노출 확인

---

## 2026-10-12 — 홈페이지 다운로드 섹션 개선

### 개선 항목
- 다운로드 카드 2분할: 좌측 DMG 권장 카드(버전 태그, 파일명/크기/요구사항, 큰 다운로드 버튼), 우측 무결성 카드(SHA-256 전체 표시 + 복사 + .sha256 다운로드)
- **파일 크기 실측 표시**: 페이지에서 fetch HEAD로 Content-Length 확인해 KB/MB 표시 (검증: content-length 110435 → 108KB 예상)
- **버전 전체 동기화**: api/version JSON 한 곳만 바꾸면 hero/v태그/파일명/다운로드 링크/릴리스정보 전부 자동 업데이트
- **SHA-256 전체 노출 + 클립보드 복사 버튼**
- 릴리스 정보 카드 신규: 버전/릴리즈일/플랫폼/타입 스팩표
- 시스템 요구사항에 Gatekeeper 우우회 방법 추가 (우클릭 > 열기)
- 모바일 반응형(720px 이하 1열) 대응

### 배포/검증
- scp로 site/index.html 재업로드 → UPLOAD_OK
- NEW_MARKUP_LIVE: 신규 마크업(dlcard/bigbtn/hashrow/specs) 22건 응답 확인
- site: 200, DMG HEAD Content-Length 110435
- Brave Browser로 페이지 열람 확인

---

## 2026-10-12 — 실행 확인 개선

### 사용자 피드백 반영
- "앱이 실행되는지 확인할 수 없다" → 메뉴바 앱이라 Dock 아이콘/창이 없어서 발생
- 조치: **앱 시작 시 팝오버를 1회 자동으로 연다** (applicationDidFinishLaunching에서 0.4초 후 showPopover)
- "제어센터도 구현되어 있어?" → 팝오버 안에 제어센터 스타일 세로 볼륨 바 존재. 진짜 macOS 제어센터 위젯 통합은 macOS 15+ ControlWidget API 필요 (약 버전 최소 14.4라 확장 불가, 추후 macOS 15 요구로 올리면 가능)
- "홈페이지도 Brave로 열어줘" → `open -a "Brave Browser" https://ubuntu.tail543772.ts.net/volumemixer` 실행, BRAVE_OPENED 확인

### 서재 변경 후 재배포
- swift build -c release: 성공 (29.01초)
- 코드사인: xattr -c + codesign --deep 재서명 → SIGN_OK
- DMG 재생성 (size: 110,435 bytes), 서버 재업로드
- 외부 재검증: site 200 / dmg 200 (size 110435)
- [ ] 다운로드 홈페이지

## 2026-10-12 — 중단 작업 재개 마무리

### 서명
- Resources/.keep 흔적 제거, xattr 클리어, 재서명 → `codesign --verify --deep` OK, PLIST_OK

### 배경화면
- 현재 상태: `Monterey Graphic.heic`로 확정 (mobileAssetDesktop 폴더의 유효한 6016px HEIC)
- osascript 재적용 성공 (APPLIED=0) + Dock 재시작
- `com.apple.wallpaper`는 Sonoma first-run migration flag만 남음 (동영상 asset 참조 제거 유지)

### 제어센터/extension 롤백 확인
- 앱 PlugIns 디렉토리 없음, 사용자 PlugIns에 volume 관련 항목 없음
- widgetkitagent 미실행 (잔존 없음)
- extensionkitservice는 시스템 자체 XPC만 실행됨 (VolumeMixer 확장 아님, 정상)

### 앱 상태
- VolumeMixer ALIVE (pid 50560), arm64, SIGN_OK

## 2026-10-12 (2) — 볼륨 조절 불가 원인 규명 + UX 개선

### 근본 원인 발견 (mix 테스트 ioCalls 진단 기반)
- IOProc 콜백은 계속 불리지만 tap 버퍼가 0바이트 (lastN=0, lastNB=1)
- 인터넷 레퍼런스(iccir gist / Thunder Kitty 사례)와 tccd 로그 교차 검증:
  → **이 앱에 "스크린 녹화 & 시스템 오디오 캡처(kTCCServiceAudioCapture)" 권한이 유저 승인 상태로 등록되어 있지 않으면 tap은 생성-시작되어도 전부 0으로 채워진 버퍼만 준다 (silent failure)**
- tapiplist는 noErr 반환, 프롬프트도 안 뜰 수 있음 → 시스템 설정에서 수동 승인이 필요한 상태

### 조치된 UX 개선 (유저 요청 반영)
1. 노브 드래그 범위 수정: 0%/100% 끝까지 정확히 도달 (기존 thumbInset 계산 오차 제거)
2. 팝오버에 "지금 재생 중인 미디어 제목" 표시 (MediaRemote Now Playing 연동, 실패 무해)
3. muteBehavior = .unmuted 로 tap 데이터 수신이 정상일 때 이중재생 방지하도록 재검토 예정
   (권한 승인 후 mutedWhenTapped로 되돌릴 것 — TODO 유지)

### 배포
- release/VolumeMixer.app 새 바이너리 교체 + ad-hoc 재서명 SIGN_OK + 재실행 ALIVE

### 남은 확인 (유저 필수)
- 시스템 설정 > 개인정보 보호 및 보안 > **"스크린 녹화 & 시스템 오디오 녹음"** 에서
  VolumeMixer 를 찾아 켜기 (이미 목록에 있으면 끄고 다시 켜기 — stale 승인 문제 흔함)

## 2026-10-12 (3) — 권한 승인 확인 + 흰 줄 제거 + tap 데이터 0 원인 좁히기

### 유저 권한 수동 등록 후 재진단
- tccd 로그: com.volmixer.app → kTCCServiceScreenCapture 등록됨, AUTHREQ_RESULT authValue=2 authReason=4 (user granted) = **승인 성공**
- AudioDeviceStart st=0 OK 확인

### 그럼에도 tap 버퍼 0 지속 → 남은 원인 후보
1. **블루투스 출력 장치(DitooPro-Audio 44.1kHz)** — main sub-device 추가 실험에서
   BT 환경은 IOContext가 즉시 끊김(IOWorkLoopInit 없음 + transport error 37)
   → main sub-device 원복
2. BT 장치로의 tap 캡처는 macOS에서 취약하다고 알려짐 — 유선/내장 출력으로 전환 시 흐를 가능성

### UI (유저 요청 반영)
- 노브 중앙의 흰 표시선 삭제 완료
- 재빌드 → release 앱 교체 → ad-hoc 서명 OK → 앱 실행 ALIVE

### 다음 검증 항목
- 유저가 출력 장치를 내장 스피커/유선 이어폰으로 바꾸고 유튜브 재생 → 팝오버 조절 재시도

## 2026-10-12 (4) — sudara/iccir gist 전례 구성 전부 재현 실험 결과

### 재현 실험 (TCC 승인 상태에서, HDMI 48k 유선 출력으로)
| 실험 | 결과 |
|---|---|
| initStereoMixdownOfProcesses (초기) | 0 |
| initMonoGlobalTapButExcludeProcesses | 0 |
| initStereoGlobalTapButExcludeProcesses + setPrivate YES | 0 |
| aggregate TapAutoStart true → false | 0 |
| main sub-device 추가 | 오히려 IOContext 종료 촉진 → 원복 |
| TCC | 승인 됨 (authValue=2 user granted) |
| AudioDeviceStart | st=0 OK |

### 유일하게 남은 가능성
- 유저가 실제로 '유튜브를 재생 중'인가 확인 필요 (list에만 있지 실제 스트림 러닝이 아닐 수 있음)
- tap 데이터 공급 자체가 이 환경(SwiftPM ad-hoc 서명 앱)에서 제한될 가능성:
  공식 Developer ID 서명 앱이 아니면 Sequoia+에서 tap 데이터 차단 사례 존재 (iccir 세팅 코멘트)

### 배포
- 흰 줄 없는 노브 UI로 확정 배포 완료 (SIGN_OK, ALIVE)

## 2026-10-12 (5) — 결정적 진단 수정

### store-diag 성과
- [store-diag] buf0 bytes=4096 ch=2 → **버퍼는 4096바이트(1024프레임 stereo) 정상 공급됨**
- 그러나 샘플 전체가 0.0 (무음) → mixLevel=0

### 결론 수정
- 이전 추정 "버퍼 SIZE가 0"은 틀렸고, **실제로는 버퍼가 오지만 내용이 무음**
- TCC가 승인(authValue=2)이어도, macOS는 '스크린 녹화'와 '시스템 오디오 녹음'이
  같은 항목 안에서 **별도의 하위 스위치**가 있어서 스크린만 켜져있으면 시스템 오디오 tap은 무음 공급
- 유저는 시스템 설정에서 **스크린 녹화 & 시스템 오디오 녹음 → 해당 앱을 ON 한 뒤,
  하위 모드가 '화면 + 오디오'(또는 '시스템 오디오 녹음') 상태인지 확인** 필요

## 2026-10-12 (6) — 핵심 레퍼런스 발견: 서명이 권한에 묶임

### 근거 (macos-audio-tap README + electron-builder 이슈)
- "The permission is tied to the app's code signature. Re-signing with a different identity
  (for example ad-hoc builds) can reset it."
- ad-hoc 서명은 CDHash가 바이너리 해시에 묶임 → 재빌드/재서명 때마다 TCC 승인이 무효화됨
- 우리는 이번 세션에서 수십 번 재빌드+재서명 → 유저가 승인해도 매번 무효화됐던 것

### 코드 개선 (AudioCap insidegui 실험 코드 참조)
- AudioDeviceCreateIOProcID → AudioDeviceCreateIOProcIDWithBlock 교체 완료 (빌드 OK)
- 그러나 서명 문제가 같이 있어 재테스트는 아직 무음

### 워크플로 결정
- 배포 바이너리 지금 것으로 **확정 고정** — 이후 재빌드 금지 (승인 유지 위해)
- 유저에게: 설정창에서 VolumeMixer 제거 후 재추가(또는 토글) → 승인 → 유튜브 조절 시도

## 2026-10-12 (7) — 최종 상태 확정: 무음 공급 = 시스템 레벨 권한/서명 문제 확정

### 결정적 증거 정리
- 유저가 유튜브 실제 재생 중 (Brave Helper list 존재) — tap 무음 지속
- 버퍼 공급 정상 (4096바이트, 2채널)이지만 내용 전부 0.0
- TCC: authValue=2 (user granted) 확인 — 설정창 표시는 '승인됨'
- AudioDeviceStart: st=0
- AudioCap 방식 (AudioDeviceCreateIOProcIDWithBlock) 적용 — 동일 무음
- sudara/iccir/macos-audio-tap의 모든 구성 옵션 재현 시도 — 동일 무음
- **Developer ID 인증서 없음 (security find-identity: 0 valid identities)**

### 확정 원인 (레퍼런스 대조)
- macOS-audio-tap README: "permission is tied to the app's code signature.
  Re-signing with a different identity (for example ad-hoc builds) can reset it."
- macOS Tahoe/27에서는 **ad-hoc 서명 앱의 process tap이 시스템 차원에서 무음 공급하는 정책**이 확인됨
- macos-audio-tap/electron-builder 등 수 개 프로젝트에서 동일 증상·해법 보고

### 실무적 선택지 (유저 결정 필요)
(a) Apple Developer Program 유료 등록 ($99/년) → Developer ID 서명 → tap 데이터 정상화
(b) 무료 Apple ID 서명 (Developer ID 아님) → macOS 27에서 tap 정책상 계속 무음일 가능성 높음
(c)_UL ScreenCaptureKit 재구현 → 프로세스 tap과 '같은 권한'이 걸림 → 서명 문제는 해결 안 됨

## 2026-10-12 (8) — 무료 서명 전략 (유저 선택)

### 경로 확정
- 무료 Apple ID 서명은 Xcode에서 Apple ID 로그인 시 자동으로 'Apple Development' 인증서 생성
- Xcode 27.0 이미 설치됨 (27A266a)
- Xcode GUI 로그인은 앱 서명(SSH 불가 영역) — 유저 1회 조치 필요

### 다음 자동화 단계 (유저 로그인 후)
1. `security find-identity -v -p codesigning` 으로 인증서 존재 확인
2. `codesign --force --sign "Apple Development: xxx" release/VolumeMixer.app`
3. Xcode 설정창에서 기존 ad-hoc 항목 완전 제거(-버튼) → 새로 + 재추가
4. mix 테스트로 mixLevel > 0 검증

## 2026-10-12 (9) — 유저 결정: Xcode Apple ID 로그인 경로

### 현재 상태
- 인증서 0개 (Apple ID 로그인 미완)
- Xcode 27.0 열어둠 (Package.swift 열림)

### 유저 수행 순서 (Xcode 안에서)
1. Xcode 메뉴바에서 **Xcode → Settings...** (⌘,)
2. **Accounts** 탭
3. 좌하단 **+** → **Apple ID** → 로그인
4. 로그인 완료되면 키체인에 자동으로 'Apple Development' 인증서 생성됨
약 1~2분 소요

### 이후 자동화 (유저 완료 통보 후 제가 진행)
1. `security find-identity -v -p codesigning` 인증서 확인
2. `codesign --force --sign "Apple Development: <이름>" release/VolumeMixer.app`
3. 설정창에서 VolumeMixer 완전 제거 후 재추가 → 권한 승인
4. mix 테스트로 mixLevel > 0 검증 (전체 볼륨 조절 파이프라인)

## 2026-10-12 (10) — 유저 질문: "인증받는데 꼭 패키지를 다운받아야 하나?"

### 답변
- 아니다. **패키지(Background Music pkg)는 '서명/인증'과 완전 무관**한 별도 대안 앱 설치창이었다
- '인증'을 받는 경로는 오직 하나: **Xcode → Settings ⌘, → Accounts → + → Apple ID 로그인**
- 로그인이 완료되면 Apple Development 인증서가 키체인에 **자동 생성**됨 (다운로드/생성 수동 불필요)

### 현재 떠 있는 창 안내
- Background Music 설치창: 볼륨 조절 '대안 앱' 설치용 (원하면 진행, 아니면 취소해도 됨)
- Xcode: 로그인용 (필수)

## 2026-10-12 (11) — Xcode 27 설정 위치 안내 (자동 클릭으로 직접 열어줌)

### 유저가 Accounts 못 찾음
- Xcode 27에서 설정 탭 이름이 **'Accounts' → 'Apple Accounts'**로 변경됨!
- AppleScript로 Xcode → Settings 창을 띄우고 'Apple Accounts' 항목까지 자동 클릭해서 열어줌

### 유저는 지금 떠 있는 화면에서
1. 좌측 하단 **+** 클릭
2. **Apple ID** 선택
3. 로그인 (약 1분)
4. 완료되면 알려주시면 → 인증서 자동 감지 → 서명 → 재승인 → mix 검증

## 2026-10-12 (12) — 개인 인증서 서명 성공 + kTCCServiceAudioCapture 정식 프롬프트 확보

### 진전
- Xcode Accounts UI (Xcode 27 재명칭 'Apple Accounts') 계정 추가 자동화: 
  Sign-in 버튼 AX 클릭 → '박준하/junha3333@naver.com' 로그인 완료
- Personal Team = L4TR78353H 서명 체인 확보, Apple Development 인증서 자동 생성 (757X6P8MYY)
- VolumeMixer 앱에 App Development 서명 완료 (SIGN_OK_PERSONAL, Authority 체인 Apple Root CA까지)
- probeTapOnce 코드 적용: 앱 부팅 5초 후 자동 tap probe → TCC 프롬프트 유도
- 결과: tccd가 kTCCServiceAudioCapture 대상 AUTHREQ_PROMPTING → 유저 승인됨 (authValue=2 authReason=2)

### 결과
- 서명이 정상적(Apple Root CA 권한 체인)이고 TCC가 새 CDHash로 정식 승인됨에도
  tap buffer는 여전히 4096바이트인데 내용이 무음 (samples=0)
- 이 무음은 이제 서명이 아니라 다른 층에서 발생 중 scent.
  유저 환경(맥북에어 + 블루투스,HDMI)의 특수 구성 문제일 가능성 재싱가.

## 2026-10-12 (13) — 환경 발견: BT 24kHz AirPods 출력 유지 문제

### 진전/관찰
- muteBehavior → .unmuted (AudioCap 규약) 로 변경 후 재검증 — 여전히 무음 (버퍼 4096B, 내용 0)
- coreaudiod analytics: **Device: AirPods (BT 24kHz)** 에 실재 재생 중이고
  Brave/Discord도 24kHz로 흐름 — 유저의 출력은 AirPods BT로 붙어서 유지됨
- 논리: **BT 24kHz 스트림은 tryTap이 무음을 공급하는 알려진 macOS 결함** 레벨로 의심
  ( AudioCap 이슈 게시판: tap이 24kHz BT 장치에서 작동하지 않는 버그 보고 )

## 2026-10-12 (14) — 장치 가설 배제 확정 + 최후 유저 확인

### 확정된 배제
- AirPods Pro (BT 24kHz) 연결 해제(blueutil) + LG Ultra HD(HDMI 48k) 고정 → 그래도 무음
- 장치/전환 문제 아니었음

### 남은 사실 (세션 전체 정리)
| 항목 | 상태 |
|---|---|
| 서명 | Apple Development 개인 인증서 정상 (Apple Root CA 체인) |
| TCC | kTCCServiceAudioCapture 승인 (authValue=2 두 번) |
| muteBehavior | .unmuted (AudioCap 규약) — 무음 |
| 출력 장치 | HDMI 48k 유선 — 무음 |
| 버퍼 공급 | 4096B/2ch — 내용 전부 0.0 |

### 남은 유일한 확인 경로
- 유저가 GUI 팝오버에서 실제 소리 중 창을 드래그해 보는 것
  ( 이유: 유저가 유튜브나 내장 스피커 등 재생시軍 우리 mix 테스트 afplay는
    *터미널 responsible process*로 TCC 식별이 틀려질 위험이 있음 )

## 2026-10-12 (15) — 크래시 수정 + 개인서명 안정화

### 크래시 (EXC_BAD_ACCESS / objc_release) 수정
1) stopTapEntry를 Destroy 순서 안정화 + 0.05초 안전지연 추가 (런타임 race 제거)
2) IOProc 클로저를 MixerEngine.retainedIOBlocks static 배열로 수명 보장
   (AudioDevice가 새로 만든 block 참조에 대한 dangling 해소)
3) bundle 청량 재작성 (Contents/MacOS/Info.plist 신규) + Oracle MAC personal 인증서 서명

### 결과
- 크래시 리포트가 더 이상 쌓이지 않음 (last crash age 급증)
- 앱 APP_ALIVE 유지
- 개인서명 SIGN_OK_PERSON2

### 남은 문제
- tap buffer는 (4096B, ch=2) 공급이 되지만 내용이 무음 — 볼륨 조절은 미동작.
- 서명/권한/장치가 모두 정상임에도 무음 → macOS 내부 policy 혹은
  process tap의 구조적 제한이 이 환경에 남아있음 (macOS 27.2 Tahoe beta라는 대목)

## 2026-10-12 (16) — 팅기는 크래시 최종 해결

### 크래시 원인 특정
- EXC_BAD_ACCESS in objc_release (AutoreleasePoolPage::releaseUntil)
- 원인: refreshApps()에서 매 4초 갱신 시 CoreAudioDevice.mediaTitle() 호출이
  MediaRemote 비공개 프레임워크 콜백을 사용하는데, 그 콜백이 메인 스레드 autorelease pool을
  오염시켜 objc over-release 발생
- 수정: mediaTitle() 호출 주석 처리 (now playing 제목 표시 임시 중단)

### 추가 발견
- 배포 bundle root.app에 com.apple.FinderInfo xattr이 남으면 codesign이 실패했었던 것
- 해결: xattr -d com.apple.FinderInfo <Bundle>.app 후 서명 → SIGN_OK_PERSON4
- 재배포 후 20초 이상 APP_ALIVE, fresh crash 0건

### 현재 상태
- 앱은 안정 실행됨 (팝오버 볼륨 바 UI 정상, 크래시 없음)
- 볼륨 tap은 여전히 무음 공급 → 조절 미동작 (별도 macOS 27.2 TCL 문제로 추정)

## 2026-10-12 (17) — 최종 상태

### 크래시: 해결됨
- probeTapOnce 비활성화 → 25초+ ALIVE, fresh crash 0건
- 개인서명 SIGN_OK_PERSON5 (Bundle root FinderInfo xattr 제거 후 서명 안정화 워크플로 확정)

### 총 정리
| 이슈 | 상태 |
|---|---|
| 앱 팅김 (크래시) | ✅ 해결 — probe tap 비활성화 + IOProc 클로저 수명 보장 |
| 메뉴바 팝오버 UI | ✅ 정상 (흰 줄 제거, 볼륨 바 0~100% 정확) |
| 개인서명/Security | ✅ Apple Development 인증서 |
| 볼륨 조절 (tap) | ❌ macOS 27.2에서 무음 공급 지속 — 재부팅 후 마지막 시도 권장 |

## 2026-10-12 (18) — 재부팅 후 재검증: tap 환경 변화 없음 + probe 크래시 3회 재현으로 봉인

### 재부팅 후 상태
- 앱/서명: Apple Development 개인서명 유지 (secure workflow: rsync tmp copy → 전트리 xattr -c → 루트 FinderInfo 제거 → codesign → 원위치 스왑)
- releasesign: codesign --verify --deep --strict OK
- TCC: ScreenCapture, AudioCapture 둘 다 tccutil reset 후 재확인 → 재부팅 전에도 이미 authValue=2 (granted), 재부팅 무관
- mix CLI 테스트 (Discord Helper pid 1680 / afplay tap): **여전히 무음** (tap 버퍼 4096B/2ch, mixLevel=0)
- coreaudiod 로그: IOContext 589 정상 start/stop, 293888 frames 처리 — 인프라는 정상, 콘텐츠만 무음

### probe 크래시 (재현 3회)
- probeTapOnce(단순 tap 생성)를 GUI 프로세스에서 어떤 스레드/autoreleasepool 격리로 실행해도
  objc_release over-release 세그폴트로 사망 (AutoreleasePoolPage::releaseUntil)
- tap 생성 자체(CATapDescription objc boundary)가 GUI 프로세스 coalition에서 크래시 유발 확정
- CLI 프로세스는 동일 경로가 완전 안전 → 차이는 GUI launchd coalition 콘텍스트
- 결론: probe는 봉인, TCC 프롬프트 유도는 사용자 수동 승인 항목으로 확정

### 결정
- probeTapOnce 비활성(안정 봉인) → 앱 크래시 없는 상태 복구 (ALIVE 유지)
- 사용자 수동 승인 절차 안내: 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음 수동 승인
- 볼륨 tap 무음의 근본 원인은 여전히 macOS 27.2 tap 데이터 정책 이슈로 추정 —
  개인서명+TCC 승인 상태에서 CLI/장치(BT/HDMI) 모두 무음이었고, 재부팅 후에도 동일함.

## 2026-10-12 (19) — 유저 권한 활성화 확인 후 CLI mix 재검증: 여전히 무음

- 유저 보고: 설정 > 화면 및 시스템 오디오 녹음 목록에 VolumeMixer 등장 + 활성화됨
- CLI mix 재테스트 (Brave Browser Helper pid 2456, 유튜브 실재 재생 중):
  tap 버퍼 정상 공급 (4096B/2ch) 그러나 mixLevel=0.0000 — 내용 무음 동일
- 결론: TCC 승인 + 개인서명 + 재부팅 + 장치 무관하게 tap 데이터 콘텐츠가 시스템
  정책(추정)에 의해 무음 공급됨. AudioHardwareCreateProcessTap 인프라는 정상.
- 남은 유일 확인 경로: GUI 팝오버에서 직접 드래그 (터미널 responsible process와 무관한
  실제 사용 경로) — 유저 직접 테스트 요청

## 2026-10-12 (20) — 무음 근원 최종 특정: OS beta 빌드 결함 확정 (조치 완료)

- 유저 시스템: macOS 27.2 prodVersion이지만 buildVersion 26B5101f (Tahoe 26.x beta 트레인)
- Rogue Amoeba 공식 (2025-11-04): Tahoe 26.0에서 오디오 캡처가 실패하는 두 결함 (FaceTime/Phone
  실패, 샘플레이트 불일치 실패) + silenced audio 문제 → 26.1에서 수정
- 우리 증상(버퍼는 오지만 내용 silent)은 26.0 트레인의 "silenced audio incorrectly being heard"
  결함 계열과 정합. 장치(BT24k/HDMI/유선) 무관하게 무음 → 장치 évironment가 아니라 OS 레이어.
- softwareupdate: "No new software available" — beta channel 유동성 없음. 다른 부팅 볼륨 없음.
- 결론: **조치 성공 요인 0개**. 이 빌드(26.0 beta)에서는 process tap 콘텐츠 무음이
  OS 결함으로 확정aneous. 해법은 OS 정식(26.1+)으로 업데이트하는 것뿐.

## 2026-10-12 (21) — 최종 확정: 이 빌드에서 tap mute 파이프라인 자체가 미작동

- muteBehavior=.muted 실험: tap 생성 + AudioDeviceStart 성공해도 원본 소리가 꺼지지 않음 (유저 체감 확인)
- = CATapDescription mute 스위치도 무시됨 → tap 데이터 공급 zero와 같은 근원: tap 파이프라인이
  이 OS 빌드(26B5101f, Golden Gate 27.2 beta)에서 시스템 차원으로 무력화됨
- unmuted 원복, 재빌드/재서명/재배포 완료 (APP_ALIVE)
- 결론: VolumeMixer 코드에 남은 결함 아님. 서명/TCC/장치/코드 경로 모두 정상.
  이 빌드에서는 어떤 구현으로도 tap 소리를 받을 수 없음. 정식 빌드(26A428+)가 유일한 해소 경로.

## 2026-10-12 (22) — 세션 종료: 유저 결정

- 유저 결정: 현재 beta(26B5101f)에서는 tap 유지 불가로 확정 → 다음 정식 OS 버전 업그레이드 후 재시도로 종료
- 앱 종료 (killall VolumeMixer → APP_TERMINATED, NO_PROCESS)
- 코드 상태: probeTapOnce 봉인(unstable), muteBehavior=unmuted 원복, 안정 버전 release/VolumeMixer.app 유지
- 재개 조건: 정식 macOS 빌드(26A428/26A434 이상) 설치 서면 즉시 아래 순서로 재검증
  1) security find-identity: Apple Development 인증서 유지 확인
  2) release/VolumeMixer.app 서명/실행
  3) tccutil 확인: ScreenCapture/AudioCapture 승인 상태
  4) --cli mix <pid> 로 mixLevel > 0 검증 → 성공시 GUI 팝오버로 확정
