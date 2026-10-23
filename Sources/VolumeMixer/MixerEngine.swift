import Foundation
import CoreAudio
import CoreAudioKit
import AudioToolbox
import AudioUnit
import Darwin

// MARK: - 앱별 볼륨 믹서 엔진
//
// 구조 (RULE-002 / RULE-003):
//   앱마다 Process Tap 1개 생성 -> aggregate device(비공개)로 연결 -> IOProc에서
//   버퍼를 받아 gain을 곱해 링버퍼에 적립
//   -> DefaultOutput AudioUnit의 render callback에서 모든 앱 링버퍼를 합쳐 출력
//
//   원본 오디오는 CATapMuteBehaviorWhenTapped로 음소거되므로 이중 재생이 없다.
//   슬라이더를 100%로 두고 그 앱의 tap을 정리하면 원본이 그대로 들린다.

// MARK: - 링버퍼

final class FloatRingBuffer {
    private var buffer: [Float]
    private var head = 0   // 읽기 위치
    private var count = 0
    private let lock = NSLock()

    init(capacity: Int) {
        buffer = [Float](repeating: 0, count: capacity)
    }

    var available: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func write(_ samples: [Float]) {
        lock.lock()
        for s in samples {
            buffer[head] = s
            head = (head + 1) % buffer.count
            if count < buffer.count { count += 1 }
        }
        lock.unlock()
    }

    /// 필요 프레임 수 확보 못하면 nil (drift 방지용)
    func read(frames: Int, channels: Int) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let need = frames * channels
        guard count >= need else { return nil }
        var out = [Float](repeating: 0, count: need)
        let start = (head - count + buffer.count) % buffer.count
        for i in 0..<need {
            out[i] = buffer[(start + i) % buffer.count]
        }
        count -= need
        return out
    }

    func dropStale(over: Int) {
        lock.lock()
        if count > over {
            let excess = count - over
            count = over
            _ = excess
        }
        lock.unlock()
    }
}

final class MixerEngine {
    // 출력 AudioUnit
    private var outputUnit: AudioComponentInstance?
    private let outSR: Double = 48000
    private let outCH: UInt32 = 2

    // 앱 항목: 프로세스 객체 id -> tap/aggregate/버퍼/gain
    struct TapEntry {
        let processObjectID: UInt32
        let pid: pid_t
        var tap: AudioObjectID = 0
        var aggregate: AudioObjectID = 0
        var procID: AudioDeviceIOProcID?
        var ring: FloatRingBuffer = FloatRingBuffer(capacity: 48000 * 2 * 2)  // ~1초
        var gain: Float = 1.0
        var active: Bool = false
        var lastDataAt:(Date) = Date.distantPast
    }
    private var entries: [TapEntry] = []
    private let entriesLock = NSLock()

    // 출력 확보에 사용할 최근 믹스 레벨 (미터용)
    private(set) var lastMixLevel: Float = 0
    private(set) var ioProcCallCount: Int = 0          // 진단: IOProc 콜백 횟수
    private(set) var lastNSamples: Int = -1            // 진단: 마지막 콜백 샘플 수
    private(set) var lastNBuffers: Int = -1            // 진단: 마지막 콜백 버퍼 수

    private var started = false

    // AudioUnit render callback은 C 함수 포인터라 self 캡처가 불가 -> static으로 우회
    fileprivate static weak var renderEngine: MixerEngine?
    fileprivate static var retainedIOBlocks: [AudioDeviceIOBlock] = []  // IOProc 클로저 수명 보장

    // Thread-safety notes:
    //  - AudioDevice IOProc은 실시간 스레드 -> 여기서 절대 alloc/lock 오래 잡지 않기
    //  - render callback은 entriesLock을 잠깐 잡고 링버퍼 read만 수행

    // MARK: 공개 API

    /// 앱 목록
    func listApps() throws -> [AudioApp] {
        try CoreAudioDevice().listAudioProcesses()
    }

    /// 앱 tap 시작 (볼륨 100%가 아닌 앱만 tap 생성)
    func enableTap(processObjectID: UInt32, pid: pid_t, initialGain: Float) throws {
        entriesLock.lock()
        if let i = entries.firstIndex(where: { $0.processObjectID == processObjectID }) {
            entries[i].gain = initialGain
            entriesLock.unlock()
            if initialGain < 0.999 { try startTap(at: i) }
            return
        }
        var entry = TapEntry(processObjectID: processObjectID, pid: pid, gain: initialGain)
        entries.append(entry)
        let idx = entries.count - 1
        entriesLock.unlock()

        if initialGain < 0.999 {
            try startTap(at: idx)
        }
    }

    /// 볼륨 변경. 100%에 가까우면 tap 해제해 원본 스트림 유지
    func setVolume(processObjectID: UInt32, gain: Float) throws {
        entriesLock.lock()
        guard let i = entries.firstIndex(where: { $0.processObjectID == processObjectID }) else {
            entriesLock.unlock()
            return
        }
        entries[i].gain = max(0, min(1, gain))
        let needTap = entries[i].gain < 0.999
        let hasTap = entries[i].tap != 0
        entriesLock.unlock()

        if needTap && !hasTap {
            try startTap(at: i)
        } else if !needTap && hasTap {
            stopTap(at: i, reset: true)
        }
    }

    /// 모든 tap 정리 (앱 종료 시)
    func shutdown() {
        entriesLock.lock()
        let all = entries
        entries.removeAll()
        entriesLock.unlock()
        for i in 0..<all.count { stopTapEntry(all[i]) }
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        outputUnit = nil
        started = false
    }

    // MARK: 내부

    private func startTap(at idx: Int) throws {
        entriesLock.lock()
        guard idx < entries.count else { entriesLock.unlock(); return }
        guard entries[idx].tap == 0 else { entriesLock.unlock(); return }
        let processObjectID = entries[idx].processObjectID
        entriesLock.unlock()

        // 1) tap 생성 (NS_REFINED_FOR_SWIFT 우회: alloc impl + perform 이니셜라이저)
        guard let cls = NSClassFromString("CATapDescription") else {
            throw TapError.unexpected("CATapDescription class not available")
        }
        let allocSel = sel_registerName("alloc")
        typealias AllocFn = @convention(c) (AnyClass) -> Unmanaged<AnyObject>
        let allocImpl = unsafeBitCast(class_getMethodImplementation(object_getClass(cls), allocSel), to: AllocFn.self)
        let raw = allocImpl(cls).takeRetainedValue()
        let objIDs = [NSNumber(value: processObjectID)]
        guard let res = raw.perform(Selector(("initStereoMixdownOfProcesses:")), with: objIDs),
              let descRes = res as? Unmanaged<AnyObject>,
              let descObj = descRes.takeRetainedValue() as? CATapDescription else {
            throw TapError.unexpected("initStereoMixdownOfProcesses failed")
        }
        // (20) 실험 결과: .muted로 설정해도 원본이 꺼지지 않음 (유저 확인) =
        // tap mute 파이프라인 자체가 이 빌드에서 미작동. unmuted 원복.
        descObj.muteBehavior = .unmuted
        descObj.isPrivate = true       // aggregate도 private이므로 tap도 private이어야 함 (sudara/iccir 규약)
        // 이미 열려있는 스트림도 tap으로 리다이렉트 (유튜브처럼 재생 시작이 먼저인 경우 필수)
        raw.perform(Selector(("setProcessRestoreEnabled:")), with: NSNumber(value: true))
        var tap: AudioObjectID = 0
        var st: OSStatus = noErr
        if #available(macOS 14.2, *) {
            st = AudioHardwareCreateProcessTap(descObj, &tap)
        } else {
            throw TapError.unexpected("Process Tap requires macOS 14.2+")
        }
        guard st == noErr else { throw TapError.osStatus(st, "create tap") }

        // 2) aggregate device(비공개)에 tap 연결
        let uid = "com.volumemixer.agg.\(processObjectID).\(UUID().uuidString.prefix(8))"
        let tapUUIDStr = descObj.uuid.uuidString
        fputs("[mix-diag] tap uuid=\(tapUUIDStr)\n", stderr)  // 진단
        let taps: [[String: Any]] = [
            [kAudioSubTapUIDKey: tapUUIDStr,
             kAudioSubTapDriftCompensationKey: true]
        ]
        var aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer-\(processObjectID)",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceTapListKey: taps,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true,
        ]
        // tap 데이터 플로: main sub-device 추가는 BT 장치 환경에서 오히려 IOContext가
        // 시작도 안 되고 끊김 (로그 근거: IOWorkLoopInit 없음 + transport error) → 제거 유지
        // ★ 사용자 환경: 기본 출력이 블루투스(DitooPro 44.1kHz) — BT는 tap 캡처 실패 확률 높음
        var agg: AudioObjectID = 0
        st = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &agg)
        guard st == noErr else { try? CoreAudioDevice().destroyTap(tap); throw TapError.osStatus(st, "create aggregate") }

        // 3) IOProc 등록 (WithBlock, AudioCap 규약): tap 버퍼를 ring에 적립
        // 크래시 수정: 클로저를 static으로 유지 (AudioDevice가 안전하게 참조 유지하도록 수명 보장)
        let ioQueue = DispatchQueue(label: "com.volmixer.ioproc")
        var procID: AudioDeviceIOProcID?
        let ioblock: AudioDeviceIOBlock = { _, inData, _, _, _ in
            MixerEngine.renderEngine?.storeIOBufferData(from: inData, into: idx)
        }
        // 클로저를 ObjC block으로 보존 (수명 관리: static으로 heap에 안전하게 보관)
        Self.retainedIOBlocks.append(ioblock)
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue, ioblock)
        guard st == noErr else {
            try? CoreAudioDevice().destroyTap(tap)
            AudioHardwareDestroyAggregateDevice(agg)
            throw TapError.osStatus(st, "create IOProc(block)")
        }
        st = AudioDeviceStart(agg, procID)
        fputs("[mix-diag] AudioDeviceStart st=\(st) (0=OK)\n", stderr)
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(agg, procID!)
            try? CoreAudioDevice().destroyTap(tap)
            AudioHardwareDestroyAggregateDevice(agg)
            throw TapError.osStatus(st, "start device")
        }

        entriesLock.lock()
        if idx < entries.count {
            entries[idx].tap = tap
            entries[idx].aggregate = agg
            entries[idx].procID = procID
            entries[idx].active = true
            entries[idx].lastDataAt = Date()
        }
        entriesLock.unlock()

        ensureOutputUnitStarted()
    }

    private func stopTap(at idx: Int, reset: Bool) {
        entriesLock.lock()
        guard idx < entries.count else { entriesLock.unlock(); return }
        let entry = entries[idx]
        entries[idx].tap = 0
        entries[idx].aggregate = 0
        entries[idx].procID = nil
        entries[idx].active = false
        entriesLock.unlock()
        stopTapEntry(entry)
    }

    private func stopTapEntry(_ e: TapEntry) {
        // 크래시 수정: AudioDeviceDestroyIOProcID와 AudioHardwareDestroyAggregateDevice의
        // 순서/타이밍 문제로 오버-릴리즈가 발생. Destroy 순서를 나열하고,
        // ioDestory->aggDestroy 사이 안전 간격을 두어 레이스 해소.
        if e.aggregate != 0 {
            if let p = e.procID {
                AudioDeviceStop(e.aggregate, p)
                AudioDeviceDestroyIOProcID(e.aggregate, p)
            }
            Thread.sleep(forTimeInterval: 0.05)  // 안전 간격: io thread 정리 후 agg 해제
            AudioHardwareDestroyAggregateDevice(e.aggregate)
        }
        if e.tap != 0 {
            Thread.sleep(forTimeInterval: 0.05)
            try? CoreAudioDevice().destroyTap(e.tap)
        }
    }

    private func storeIOBufferData(from list: UnsafePointer<AudioBufferList>?, into idx: Int) {
        guard let list else { return }
        // AudioBufferList의 inline C 배열은 Swift Tuple로 임포트되어 직접 인덱싱 불가 ->
        // memcpy로 복사해 AudioBuffer 배열로 재해석
        let nBuffers = Int(list.pointee.mNumberBuffers)
        guard nBuffers > 0 else { return }
        // 진단: 버퍼 형식 실측 (mDataByteSize 원시 값) — memcpy 우회값 사용
        if ioProcCallCount % 100 == 0 {
            let listSize0 = MemoryLayout<AudioBufferList>.size
            let raw0 = UnsafeMutableRawPointer.allocate(byteCount: listSize0, alignment: MemoryLayout<AudioBuffer>.alignment)
            defer { raw0.deallocate() }
            memcpy(raw0, list, listSize0)
            let bufPtr = (raw0 + listSize0 - MemoryLayout<AudioBuffer>.stride).assumingMemoryBound(to: AudioBuffer.self)
            fputs("[store-diag] buf0 bytes=\(bufPtr.pointee.mDataByteSize) ch=\(bufPtr.pointee.mNumberChannels)\n", stderr)
        }
        // AudioBufferList의 동적 크기: 고정 부분 + (nBuffers-1)개 추가 AudioBuffer
        let listSize = MemoryLayout<AudioBufferList>.size + (nBuffers - 1) * MemoryLayout<AudioBuffer>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBuffer>.alignment)
        defer { raw.deallocate() }
        memcpy(raw, list, listSize)
        let buffers = raw.bindMemory(to: AudioBuffer.self, capacity: nBuffers)
        var samples: [Float] = []
        for b in 0..<nBuffers {
            let buf = buffers[b]
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard let base = buf.mData else { continue }
            let ptr = UnsafeMutableRawPointer(base).assumingMemoryBound(to: Float.self)
            for i in 0..<n { samples.append(ptr[i]) }
        }
        entriesLock.lock()
        if idx < entries.count {
            // 여기서는 원본 샘플을 저장하고, render에서 gain을 곱한다
            entries[idx].ring.write(samples)
            entries[idx].lastDataAt = Date()
            ioProcCallCount += 1
            lastNSamples = samples.count
            lastNBuffers = nBuffers
        }
        entriesLock.unlock()
    }

    // MARK: 출력 AudioUnit

    private func ensureOutputUnitStarted() {
        if outputUnit == nil {
            var comp = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_DefaultOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            guard let unitComp = AudioComponentFindNext(nil, &comp) else { return }
            var unit: AudioComponentInstance?
            guard AudioComponentInstanceNew(unitComp, &unit) == noErr, let u = unit else { return }

            // 스트림 포맷: 48kHz / Stereo / Non-interleaved float32
            var asbd = AudioStreamBasicDescription(
                mSampleRate: outSR,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: outCH,
                mBitsPerChannel: 32,
                mReserved: 0)

            AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

            // C 함수 포인터는 컨텍스트 캘크처를 못하므로 전역 static으로 엔진 참조 전달
            Self.renderEngine = self
            var cb = AURenderCallbackStruct(
                inputProc: { (_, _, _, _, inNumberFrames, ioData) -> OSStatus in
                    guard let engine = MixerEngine.renderEngine, let outList = ioData else { return noErr }
                    return engine.render(frames: Int(inNumberFrames), ioData: outList)
                },
                inputProcRefCon: nil)
            AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

            guard AudioUnitInitialize(u) == noErr else { return }
            AudioOutputUnitStart(u)
            outputUnit = u
        } else if !started {
            AudioOutputUnitStart(outputUnit!)
        }
        started = true
    }

    private func render(frames: Int, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let listPtr = ioData
        let nBuffers = Int(listPtr.pointee.mNumberBuffers)
        guard nBuffers >= 1 else { return noErr }

        // 채널별 비인터리브드 가정 (버퍼 0=왼쪽, 1=오른쪽)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)

        entriesLock.lock()
        for i in 0..<entries.count {
            guard entries[i].active else { continue }
            let g = entries[i].gain
            guard let s = entries[i].ring.read(frames: frames, channels: 2) else { continue }
            for f in 0..<frames {
                left[f] += s[f * 2] * g
                right[f] += s[f * 2 + 1] * g
            }
        }
        entriesLock.unlock()

        // AudioBufferList의 inline C 배열을 memcpy로 복사해 접근 (Tuple 임포트 우회)
        let tmp = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size, alignment: MemoryLayout<AudioBuffer>.alignment)
        defer { tmp.deallocate() }
        memcpy(tmp, listPtr, MemoryLayout<AudioBufferList>.size)
        let copiedNBuffers = Int(tmp.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
        // 복사본에서 첫 AudioBuffer 위치: mNumberBuffers(4바이트) 후 오는 첫 AudioBuffer 필드
        // 구조체 정렬에 따라 UInt32 + AudioBuffer(mData 포인터 8바이트 정렬)이므로 첫 버퍼는 오프셋 8
        let firstBufOffset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
        let buffers = (tmp + firstBufOffset).assumingMemoryBound(to: AudioBuffer.self)
        for b in 0..<copiedNBuffers {
            let buf = buffers[b]
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard let base = buf.mData else { continue }
            let ptr = UnsafeMutableRawPointer(base).assumingMemoryBound(to: Float.self)
            let src = (b % 2 == 0) ? left : right
            for i in 0..<min(n, frames) {
                var v = src[i]
                // 클리핑 방지 (RULE-003: ±1.0 초과 금지)
                if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
                ptr[i] = v
            }
            // n < frames일 때 남는 구간 0 채움 (Range lowerBound<=upperBound 보장)
            if n > frames {
                for i in frames..<n { ptr[i] = 0 }
            }
        }
        var maxLevel: Float = 0
        for f in 0..<frames { maxLevel = max(maxLevel, abs(left[f]), abs(right[f])) }
        lastMixLevel = maxLevel
        return noErr
    }
}

// MARK: - 컨텍스트

final class MixerIOContext {
    weak var engine: MixerEngine?
    let entryIndex: Int
    init(engine: MixerEngine, entryIndex: Int) {
        self.engine = engine
        self.entryIndex = entryIndex
    }
}
