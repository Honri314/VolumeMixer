import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 제어센터 위젯 (macOS 26+ WidgetKit Control)
//
// 제어센터 컨트롤은 "버튼/토글" 형태만 지원하므로 긴 세로 슬라이더는 못 넣는다.
// 대신 원터치 시나리오 컨트롤 제공:
//   1) 모두 음소거 토글
//   2) 복원 버튼
//
// 상태 공유: SwiftPM 타깃 임포트 문제 우회를 위해 컨트롤 모듈 안에
// 같은 프로토콜(shared defaults key)을 중복 선언한다. 메인 앱의 MixerShared와
// 키 문자열이 동일하므로 UserDefaults 기반으로 호환된다.

@available(macOS 26.0, *)
enum SharedMixerState {
    // 메인 앱 MixerShared.SharedMixerState에서 쓰는 키와 동일해야 한다
    static let suiteName = "group.com.volmixer.shared"
    static let muteAllKey = "cmdMuteAll"
    static let restoreKey = "cmdRestoreAll"
    static let timestampKey = "lastCommandAt"

    static var effectiveDefaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func muteAll(_ muted: Bool) {
        let d = effectiveDefaults
        d.set(muted, forKey: muteAllKey)
        d.set(false, forKey: restoreKey)
        d.set(Date().timeIntervalSince1970, forKey: timestampKey)
    }

    static func restoreAll() {
        let d = effectiveDefaults
        d.set(false, forKey: muteAllKey)
        d.set(true, forKey: restoreKey)
        d.set(Date().timeIntervalSince1970, forKey: timestampKey)
    }
}

// MARK: - AppIntents

@available(macOS 26.0, *)
struct ToggleAllMuted: AppIntent {
    static let title: LocalizedStringResource = "모든 앱 음소거"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            SharedMixerState.muteAll(true)
        }
        return .result()
    }
}

@available(macOS 26.0, *)
struct RestoreAllVolumes: AppIntent {
    static let title: LocalizedStringResource = "모든 앱 볼륨 복원"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            SharedMixerState.restoreAll()
        }
        return .result()
    }
}

// MARK: - 컨트롤 위젯

@available(macOS 26.0, *)
struct MuteAllControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.volmixer.muteAll") {
            ControlWidgetButton(action: ToggleAllMuted()) {
                Label("모두 음소거", systemImage: "speaker.slash.fill")
            }
        }
        .displayName("볼륨 믹서 음소거")
        .description("조절 중인 모든 앱을 한 번에 음소거합니다")
    }
}

@available(macOS 26.0, *)
struct RestoreControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.volmixer.restore") {
            ControlWidgetButton(action: RestoreAllVolumes()) {
                Label("볼륨 복원", systemImage: "arrow.counterclockwise")
            }
        }
        .displayName("볼륨 복원")
        .description("모든 앱을 100%로 되돌립니다")
    }
}

// MARK: - 위젯 번들 엔트리

@available(macOS 26.0, *)
@main
struct VolumeMixerControlExtension: WidgetBundle {
    var body: some Widget {
        MuteAllControlWidget()
        RestoreControlWidget()
    }
}
