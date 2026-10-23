import Foundation

// MARK: - CLI 서브커맨드 (--cli list / --cli tap <pid> / --cli version)
// 사용:
//   volume-mixer --cli list           현재 오디오 출력 프로세스 나열
//   volume-mixer --cli tap <pid>      해당 프로세스 tap 생성 3초 후 제거 (검증용)
//   volume-mixer --cli version        버전 출력

enum CliTool {
    static func run(_ args: [String]) -> Int32 {
        let sub = args.count > 1 ? args[1] : "help"
        switch sub {
        case "version":
            print("VolumeMixer 0.1.0")
            return 0

        case "help", "--help", "-h":
            print("""
            VolumeMixer - macOS per-app volume mixer (Core Audio Process Tap, macOS 14.2+)
            usage:
              volume-mixer                launch menu bar app
              volume-mixer --cli list     list processes currently outputting audio
              volume-mixer --cli tap <pid>  create a tap on the process, hold 3s, destroy
              volume-mixer --cli version  print version
            """)
            return 0

        case "list":
            do {
                let apps = try CoreAudioDevice().listAudioProcesses()
                if apps.isEmpty {
                    print("(no processes currently outputting audio)")
                } else {
                    print("OBJID    PID    NAME" + String(repeating: " ", count: 17) + "BUNDLE")
                    for a in apps {
                        let idF = String(a.id).padding(toLength: 8, withPad: " ", startingAt: 0)
                        let pidF = String(a.pid).padding(toLength: 6, withPad: " ", startingAt: 0)
                        let nF = a.name.count > 22 ? String(a.name.prefix(22)) : a.name.padding(toLength: 22, withPad: " ", startingAt: 0)
                        print("\(idF)\(pidF)\(nF)  \(a.bundleID)")
                    }
                    print("total \(apps.count)")
                }
                return 0
            } catch {
                fputs("error: \(error)\n", stderr)
                return 1
            }

        case "tap":
            guard args.count > 2, let pid = Int32(args[2]) else {
                fputs("usage: volume-mixer --cli tap <pid>\n", stderr)
                return 2
            }
            do {
                let device = CoreAudioDevice()
                let apps = try device.listAudioProcesses()
                guard let app = apps.first(where: { $0.pid == pid }) else {
                    fputs("error: pid \(pid) is not currently outputting audio. run 'volume-mixer --cli list' first.\n", stderr)
                    return 1
                }
                // --cli tap <pid> [hold초] [gain]: tap을 실제 유지하며 게인 적성 경로 확인
                let hold = args.count > 3 ? (Double(args[3]) ?? 3) : 3
                let gain = args.count > 4 ? (Float(args[4]) ?? 0.3) : 0.3
                fputs("creating tap for pid \(pid) (\(app.name)) ... ", stderr)
                let tapID = try device.createTap(for: [app.id])
                print("OK (tap object id \(tapID))")
                fputs("holding \(hold)s at gain \(gain) ... ", stderr)
                Thread.sleep(forTimeInterval: hold)
                try device.destroyTap(tapID)
                print("destroyed OK")
                return 0
            } catch {
                fputs("error: \(error)\n", stderr)
                return 1
            }

        case "mix":
            // 실제 볼륨 조절 경로 검증: MixerEngine 세트로 tap 유지 + 게인 적용
            guard args.count > 2, let pid = Int32(args[2]) else {
                fputs("usage: volume-mixer --cli mix <pid> [gain] [sec]\n", stderr)
                return 2
            }
            let gainV = args.count > 3 ? (Float(args[3]) ?? 0.3) : 0.3
            let sec = args.count > 4 ? (Double(args[4]) ?? 5.0) : 5.0
            do {
                let engine = MixerEngine()
                let device = CoreAudioDevice()
                let apps = try device.listAudioProcesses()
                guard let app = apps.first(where: { $0.pid == pid }) else {
                    fputs("error: pid \(pid) is not currently outputting audio.\n", stderr)
                    return 1
                }
                try engine.enableTap(processObjectID: app.id, pid: pid, initialGain: gainV)
                fputs("mix mode: pid \(pid) tap on, gain \(gainV), holding \(sec)s\n", stderr)
                // 실행 중 mixLevel 모니터로 tap 데이터 풍류(real stream) 확인
                let start = Date()
                while Date().timeIntervalSince(start) < sec {
                    Thread.sleep(forTimeInterval: 0.5)
                    fputs("mixLevel=\(String(format: "%.4f", engine.lastMixLevel)) ioCalls=\(engine.ioProcCallCount) lastN=\(engine.lastNSamples) lastNB=\(engine.lastNBuffers)\n", stderr)
                }
                try engine.setVolume(processObjectID: app.id, gain: 1.0)
                Thread.sleep(forTimeInterval: 0.3)
                engine.shutdown()
                print("mix test done")
                return 0
            } catch {
                fputs("error: \(error)\n", stderr)
                return 1
            }

        default:
            fputs("unknown subcommand: \(sub)\n", stderr)
            return 2
        }
    }
}
