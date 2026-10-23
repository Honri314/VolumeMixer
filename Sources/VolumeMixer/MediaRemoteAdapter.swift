import Foundation
import AppKit

// MARK: - MediaRemote 프레임워크 어댑터 (비공개지만 널리 쓰이는 Now Playing 조회)
// 실패해도 UI에 영향 없이 빈 문자열 반환 (기능은 아니고 '재생 중 제목 표시' 보조 기능)

enum MediaRemoteAdapter {
    static let shared = MediaRemoteAdapterImpl()
}

final class MediaRemoteAdapterImpl {
    private var mrMediaRemoteGetNowPlayingInfo: (@convention(c) (DispatchQueue, @escaping (CFDictionary) -> Void) -> Void)?

    init() {
        // MediaRemote.framework 로드
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")) else { return }
        guard let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) else { return }
        mrMediaRemoteGetNowPlayingInfo = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping (CFDictionary) -> Void) -> Void).self)
    }

    func getNowPlayingTitle(completion: @escaping (String) -> Void) {
        guard let fn = mrMediaRemoteGetNowPlayingInfo else { completion(""); return }
        fn(DispatchQueue.main) { info in
            guard let info = info as? [String: Any] else { completion(""); return }
            let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            if !artist.isEmpty, !title.isEmpty {
                completion("\(title) — \(artist)")
            } else {
                completion(title)
            }
        }
    }
}
