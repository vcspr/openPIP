import Foundation
import OpenPiPCore

/// Follows one agent session log and reports its state on the main thread.
///
/// Logs can be hundreds of MB. The first read skims everything before the last few MB for task
/// and title lines only, then reads the tail in full. After that it reads only what was appended.
final class SessionWatcher {
    let url: URL
    var onChange: ((SessionState) -> Void)?

    private static let fullReadBytes: UInt64 = 6 << 20
    private static let chunk = 8 << 20
    private static let maxLine = 4 << 20

    private let queue = DispatchQueue(label: "app.hemii.openpip.session", qos: .utility)
    private var state = SessionState()
    private var offset: UInt64 = 0
    private var buffer = LineBuffer(maxLineBytes: SessionWatcher.maxLine)
    private var timer: DispatchSourceTimer?

    init(url: URL) {
        self.url = url
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.initialRead()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func initialRead() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let fullFrom = size > Self.fullReadBytes ? size - Self.fullReadBytes : 0

        // Older part: task, title and image lines only.
        var skim = LineBuffer(maxLineBytes: Self.maxLine)
        var pos: UInt64 = 0
        try? handle.seek(toOffset: 0)
        while pos < fullFrom, let data = try? handle.read(upToCount: Int(min(UInt64(Self.chunk), fullFrom - pos))),
              !data.isEmpty {
            pos += UInt64(data.count)
            for line in skim.append(data) where SessionState.isTaskRelated(line) || ImageLog.isImageRelated(line) { state.apply(line) }
        }

        // Recent part: everything. A line cut at the boundary fails to parse and is skipped.
        try? handle.seek(toOffset: fullFrom)
        while let data = try? handle.read(upToCount: Self.chunk), !data.isEmpty {
            for line in buffer.append(data) { state.apply(line) }
        }
        offset = size
        publish()
    }

    private func poll() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < offset { // replaced or truncated: start over
            state = SessionState()
            buffer = LineBuffer(maxLineBytes: Self.maxLine)
            initialRead()
            return
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var changed = false
        while let data = try? handle.read(upToCount: Self.chunk), !data.isEmpty {
            offset += UInt64(data.count)
            for line in buffer.append(data) where state.apply(line) { changed = true }
        }
        if changed { publish() }
    }

    private func publish() {
        let snapshot = state
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }
}
