import Foundation

/// Bounded line streaming: retain only the latest active and fallback observations.
public struct AppleMusicLogHistory {
    private var buffer = Data()
    private var discardingOversizedLine = false
    private var latestActive: AppleMusicLogObservation?
    private var latestFallback: AppleMusicLogObservation?
    public var observation: AppleMusicLogObservation? { latestActive ?? latestFallback }
    public var bufferedByteCount: Int { buffer.count }
    public init() {}

    public mutating func append(_ data: Data) {
        // Logs normally arrive in 64 KB chunks. A malformed line cannot grow without limit.
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0a) {
            if !discardingOversizedLine, buffer.distance(from: buffer.startIndex, to: end) <= 512 * 1024 { consume(Data(buffer.prefix(upTo: end))) }
            buffer.removeSubrange(...end)
            discardingOversizedLine = false
        }
        if buffer.count > 512 * 1024 {
            buffer.removeAll(keepingCapacity: false)
            discardingOversizedLine = true
        }
    }

    public mutating func finish() {
        if !discardingOversizedLine && !buffer.isEmpty { consume(buffer) }
        buffer.removeAll(keepingCapacity: false)
        discardingOversizedLine = false
    }

    private mutating func consume(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["eventMessage"] as? String ?? object["message"] as? String ?? object["composedMessage"] as? String,
              let value = AppleMusicLogParser.parse(message: message) else { return }
        if value.confidence == .activePlayback { latestActive = value }
        else { latestFallback = value }
    }
}
