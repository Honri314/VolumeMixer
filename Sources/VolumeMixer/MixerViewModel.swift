import SwiftUI
import AppKit
import Combine

// MARK: - 뷰모델 (RULE-006: 메뉴바 위젯/제어센터 위젯이 같은 볼륨 소스를 공유)

@MainActor
final class MixerViewModel: ObservableObject {
    @Published var apps: [AudioApp] = []
    @Published var volumes: [UInt32: Float] = [:]     // processObjectID -> 0.0~1.0
    @Published var nowPlayingTitle: String = ""       // 재생 중인 미디어 제목 (유튜브 등)
    @Published var errorMessage: String?

    let engine = MixerEngine()
    private let device = CoreAudioDevice()
    private var refreshTimer: Timer?

    func start() {
        Task { refreshApps() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshApps() }
        }
        // ★ probe 비활성화 (세그폴트 복귀): probe tap 생성은 이 GUI 프로세스 안에서
        // 어떤 스레드/풀 격리로도 objc_release over-release를 피하지 못함 (크래시 3회 재현).
        // CLI 프로세스는 동일 경로가 안전 → 차이는 launchd/coalition 콘텍스트.
        // → TCC 프롬프트는 시스템 설정 수동 등록으로 대체 (유저 안내 완료).
    }

    /// 보류: GUI 프로세스 내 probe는 세그폴트 유발 (2026-10-12三次 재현 확인)
    @available(*, deprecated, message: "GUI probe crash: objc over-release in probe path")
    private func probeTapOnce() {
        guard !apps.isEmpty else { return }
        let app = apps[0]
        let box = ProbeBox()
        Thread.detachNewThreadSelector(#selector(ProbeBox.runProbeThread(appObject:)), toTarget: box, with: app.id)
    }

    @objc private final class ProbeBox: NSObject {
        @objc func runProbeThread(appObject raw: Any) {
            let id = (raw as? NSNumber)?.uint32Value ?? 0
            autoreleasepool {
                do {
                    let device = CoreAudioDevice()
                    let tap = try device.createTap(for: [id])
                    Thread.sleep(forTimeInterval: 1.5)
                    try? device.destroyTap(tap)
                } catch { }
            }
            // probe 성공 여부와 무관하게 TCC 기록은 남는다.
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        engine.shutdown()
    }

    func refreshApps() {
        do {
            let list = try device.listAudioProcesses()
            apps = list
            errorMessage = nil
            for app in list where volumes[app.id] == nil {
                volumes[app.id] = 1.0    // 기본: tap 없음 = 원본 그대로
            }
        } catch {
            errorMessage = "\(error)"
        }
        // ★ 크래시 수정: MediaRemote 비공개 API 콜백이 런루프 autorelease 풀을 오염시켜
        // objc over-release crash(SIGSEGV)를 유발. 기능은 살려두되 호출 자체를 비활성화.
        // (NSAudioCapture 쪽과 무관 — 런처 크래시 요인 제거 목적)
        // let title = CoreAudioDevice.mediaTitle()
        // if !title.isEmpty || apps.isEmpty { nowPlayingTitle = title }
    }

    /// 실시간 드래그(RULE-006: 슬라이더 놀 때 즉시 적용)
    func setLiveVolume(app: AudioApp, gain: Float) {
        volumes[app.id] = gain
        apply(app: app, gain: gain)
    }

    /// 손 뗐을 때 최종 커밋
    func commitVolume(app: AudioApp) {
        guard let gain = volumes[app.id] else { return }
        apply(app: app, gain: gain)
    }

    /// 100%에 가까우면 tap 해제(원본), 아니면 tap + 게인 적용
    private func apply(app: AudioApp, gain: Float) {
        do {
            try engine.setVolume(processObjectID: app.id, gain: gain)
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// 이 앱이 현재 조절 중(탭 동작 중)인지 - UI 표시용
    func isControlled(_ app: AudioApp) -> Bool {
        guard let g = volumes[app.id] else { return false }
        return g < 0.999
    }
}
