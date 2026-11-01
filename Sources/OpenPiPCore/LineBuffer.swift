import Foundation

/// Splits a byte stream into text lines. A line longer than the limit is dropped whole.
public struct LineBuffer {
    private var pending = Data()
    private var discarding = false
    private let maxLineBytes: Int

    public init(maxLineBytes: Int = Event.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    public mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                if !discarding { emit(&lines) }
                pending.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                pending.append(byte)
                if pending.count > maxLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    discarding = true
                }
            }
        }
        return lines
    }

    /// Returns whatever is left when the stream closes.
    public mutating func flush() -> [String] {
        var lines: [String] = []
        if !discarding { emit(&lines) }
        pending.removeAll()
        discarding = false
        return lines
    }

    private func emit(_ lines: inout [String]) {
        guard var line = String(data: pending, encoding: .utf8) else { return }
        if line.hasSuffix("\r") { line.removeLast() }
        if !line.isEmpty { lines.append(line) }
    }
}
