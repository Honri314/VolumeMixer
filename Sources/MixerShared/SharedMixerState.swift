import Foundation
import CoreAudio

// MARK: - Extension과 메인앱 사이 상태 공유
//
// 제어센터 컨트롤은 별도 프로세스(extension)에서 실행된다. 메인앱의 MixerEngine까지
// 직접 접근할 수 없으므로 UserDefaults(app group)를 통해 명령을 주고받는다.
//
// 프로토콜:
//   - extension이 "muteAll" 명령을 기록 + timestamp 갱신
//   - 메인앱이 주기적으로 읽어서 MixerEngine에 적용
//
// 이 방식이면 extension은 상태가 없고, 실제 오디오 조작은 메인앱이 수행한다.

enum SharedMixerState {
    static let suiteName = "group.com.volmixer.shared"
    static let muteAllKey = "cmdMuteAll"
    static let restoreKey = "cmdRestoreAll"
    static let timestampKey = "lastCommandAt"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    // 앱 그룹이 없으면(예: 시그니처 문제) 표준 UserDefaults로 폴백
    static var effectiveDefaults: UserDefaults {
        defaults ?? .standard
    }

    static var allMuted: Bool {
        effectiveDefaults.bool(forKey: muteAllKey) && !effectiveDefaults.bool(forKey: restoreKey)
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

    /// 메인앱이 내려가는 동안: 마지막 명령 시각 이후 새 명령인지 확인
    static func pendingCommand() -> (muteAll: Bool, restoreAll: Bool)? {
        let d = effectiveDefaults
        let ts = d.double(forKey: timestampKey)
        let appliedAt = d.double(forKey: "lastAppliedAt")
        guard ts > appliedAt else { return nil }
        d.set(ts, forKey: "lastAppliedAllAt")
        d.set(ts, forKey: "lastAppliedAt")
        return (d.bool(forKey: muteAllKey), d.bool(forKey: restoreKey))
    }
}
