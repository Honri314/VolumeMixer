import Foundation
import AppKit
import SwiftUI

// MARK: - 엔트리포인트
//   - args 에 --cli 가 있으면 CLI (CliTool.swift)
//   - 없으면 메뉴바 앱 (아래 AppShim)

@main
struct VolumeMixerEntry {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "--cli" {
            let code = CliTool.run(Array(args.dropFirst()))
            exit(code)
        } else {
            MenuBarApp().run()
        }
    }
}

// MARK: - 메뉴바 앱 (RULE-004: Dock 없음, RULE-007: SF Symbols 벡터 아이콘)

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let vm = MixerViewModel()
    private var monitor: Any?

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        vm.start()
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Volume Mixer")
            img?.isTemplate = true
            button.image = img
            button.action = #selector(toggle(_:))
            button.target = self
        }
        statusItem = item

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 330, height: 330)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: MixerPanelView(vm: vm))
        pop.contentSize = NSSize(width: 330, height: 340)
        popover = pop

        // 첫 실행 안내: 메뉴바 앱이라 창이 없어 어디 떴는지 헷갈릴 수 있어
        // 실행 시 팝오버를 1회 자동으로 열어준다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showPopover()
        }
    }

    @objc func toggle(_ sender: Any?) {
        guard let pop = popover, let button = statusItem?.button else { return }
        if pop.isShown {
            pop.performClose(sender)
            stopMonitor()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let pop = popover, let button = statusItem?.button else { return }
        vm.refreshApps()
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startMonitor()
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                if let pop = self?.popover, pop.isShown { pop.performClose(nil) }
                self?.stopMonitor()
            }
        }
    }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
