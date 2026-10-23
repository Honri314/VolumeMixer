import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import Darwin
import ObjectiveC

// MARK: - 앱(프로세스) 정보

struct AudioApp: Identifiable, Hashable {
    let id: UInt32          // CoreAudio process object id
    let pid: pid_t
    let name: String
    let bundleID: String
    var mediaTitle: String = ""   // 재생 중인 미디어 제목 (유튜브 등)
}

// MARK: - 오류

enum TapError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)
    case unexpected(String)

    var description: String {
        switch self {
        case .osStatus(let s, let ctx): return "OSStatus \(s) (\(Self.fourCC(s))) @ \(ctx)"
        case .unexpected(let m): return m
        }
    }

    static func fourCC(_ code: OSStatus) -> String {
        let n = UInt32(bitPattern: Int32(code))
        var chars: [Character] = []
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = (n >> UInt32(shift)) & 0xFF
            if byte >= 0x20 && byte < 0x7F { chars.append(Character(UnicodeScalar(byte)!)) }
            else { chars.append("?") }
        }
        return String(chars)
    }
}

// MARK: - 제어 프로토콜

protocol AudioDeviceControlling {
    func listAudioProcesses() throws -> [AudioApp]
    func createTap(for processes: [UInt32]) throws -> AudioObjectID
    func destroyTap(_ tap: AudioObjectID) throws
}

// MARK: - 실제 CoreAudio 구현

final class CoreAudioDevice: AudioDeviceControlling {
    /// 시스템에서 오디오 출력 중인 프로세스 목록
    func listAudioProcesses() throws -> [AudioApp] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var st = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard st == noErr else { throw TapError.osStatus(st, "ProcessObjectList size") }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objIDs = [AudioObjectID](repeating: 0, count: count)
        st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objIDs)
        guard st == noErr else { throw TapError.osStatus(st, "ProcessObjectList get") }

        var apps: [AudioApp] = []
        for objID in objIDs {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid: Int32 = 0
            var sz = UInt32(MemoryLayout<Int32>.size)
            st = AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &sz, &pid)
            guard st == noErr, pid > 1 else { continue }

            var isRunning: UInt32 = 0
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var rsz = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(objID, &runAddr, 0, nil, &rsz, &isRunning)
            guard isRunning == 1 else { continue }

            let (name, bundleID) = Self.appInfo(pid: pid)
            apps.append(AudioApp(id: objID, pid: pid, name: name, bundleID: bundleID))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func appInfo(pid: pid_t) -> (String, String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
           let localName = app.localizedName {
            return (localName, app.bundleIdentifier ?? "")
        }
        var name = "pid \(pid)"
        if let path = procPath(pid: pid) {
            let url = URL(fileURLWithPath: path)
            name = url.deletingPathExtension().lastPathComponent
        }
        return (name, "")
    }

    /// 재생 중인 미디어 제목 (MRMediaRemoteGetNowPlayingInfo — 시스템 Now Playing 정보)
    static func mediaTitle() -> String {
        var result = ""
        let sema = DispatchSemaphore(value: 0)
        MediaRemoteAdapter.shared.getNowPlayingTitle { title in
            result = title
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 0.5)
        return result
    }

    /// 기본 출력 장치 UID (aggregate main sub-device용)
    static func defaultOutputDeviceUID() -> String? {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
        var uidUnmanaged: CFString? = nil
        var sz = UInt32(MemoryLayout<CFString?>.size)
        var a2 = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &a2, 0, nil, &sz, &uidUnmanaged) == noErr, let uid = uidUnmanaged else { return nil }
        return uid as String
    }

    static func procPath(pid: pid_t) -> String? {
        let maxPathLen = 4096
        var buf = [CChar](repeating: 0, count: maxPathLen)
        let len = proc_pidpath(pid, &buf, UInt32(maxPathLen))
        guard len > 0 else { return nil }
        return String(cString: buf)
    }

    /// 특정 프로세스들만 스테레오 믹스다운 탭 생성
    func createTap(for processes: [UInt32]) throws -> AudioObjectID {
        let objIDs = processes.map { NSNumber(value: $0) }
        // NS_REFINED_FOR_SWIFT 우회: 메타클래스 impl함수로 alloc 후, 인스턴스에 perform으로 이니셜라이저 호출
        guard let cls = NSClassFromString("CATapDescription") else {
            throw TapError.unexpected("CATapDescription class not available")
        }
        let allocSel = sel_registerName("alloc")
        typealias AllocFn = @convention(c) (AnyClass) -> Unmanaged<AnyObject>
        let allocImpl = unsafeBitCast(class_getMethodImplementation(object_getClass(cls), allocSel), to: AllocFn.self)
        let raw = allocImpl(cls).takeRetainedValue()
        guard let res = raw.perform(Selector(("initStereoMixdownOfProcesses:")), with: objIDs),
              let descUnm = res as? Unmanaged<AnyObject> else {
            throw TapError.unexpected("initStereoMixdownOfProcesses failed")
        }
        guard let desc = descUnm.takeRetainedValue() as? CATapDescription else {
            throw TapError.unexpected("CATapDescription type mismatch")
        }
        desc.muteBehavior = .unmuted
        if #available(macOS 14.2, *) {
            var tap: AudioObjectID = 0
            let st = AudioHardwareCreateProcessTap(desc, &tap)
            guard st == noErr else { throw TapError.osStatus(st, "AudioHardwareCreateProcessTap") }
            return tap
        } else {
            throw TapError.unexpected("Process Tap requires macOS 14.2+")
        }
    }

    func destroyTap(_ tap: AudioObjectID) throws {
        if #available(macOS 14.2, *) {
            let st = AudioHardwareDestroyProcessTap(tap)
            guard st == noErr else { throw TapError.osStatus(st, "AudioHardwareDestroyProcessTap") }
        } else {
            throw TapError.unexpected("Process Tap requires macOS 14.2+")
        }
    }
}

// MARK: - 테스트용 더블

final class MockAudioDevice: AudioDeviceControlling {
    var fakeApps: [AudioApp] = [
        AudioApp(id: 100, pid: 1000, name: "Safari", bundleID: "com.apple.Safari"),
        AudioApp(id: 101, pid: 1001, name: "Spotify", bundleID: "com.spotify.client"),
    ]
    var createdTaps: [[UInt32]] = []
    var destroyedTaps: [AudioObjectID] = []

    func listAudioProcesses() throws -> [AudioApp] { fakeApps }
    func createTap(for processes: [UInt32]) throws -> AudioObjectID {
        createdTaps.append(processes)
        return AudioObjectID(createdTaps.count + 50)
    }
    func destroyTap(_ tap: AudioObjectID) throws {
        destroyedTaps.append(tap)
    }
}
