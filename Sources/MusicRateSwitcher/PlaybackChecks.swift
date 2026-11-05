#if DEBUG
import AppKit
import RateSwitcherCore

/// Exercise rendered frames and the actual Music seek path without running rate switching.
enum PlaybackChecks {
    static func checkFrames() -> Bool {
        let format = SourceAudioFormat(sampleRate: 96_000, bitDepth: 24, channels: 2, codec: "ALAC")
        for style in MenuBarStyle.allCases {
            let a = StatusItemRenderer.image(style: style, phase: .playing, format: format, frame: 0)
            let b = StatusItemRenderer.image(style: style, phase: .playing, format: format, frame: 5)
            let idleA = StatusItemRenderer.image(style: style, phase: .idle, format: format, frame: 0)
            let idleB = StatusItemRenderer.image(style: style, phase: .idle, format: format, frame: 5)
            guard a.size == b.size, a.tiffRepresentation != b.tiffRepresentation,
                  idleA.tiffRepresentation == idleB.tiffRepresentation,
                  idleA.size == a.size else { return false }
            for rate in [44_100.0, 48_000, 96_000, 192_000, 352_800] {
                let other = SourceAudioFormat(sampleRate: rate, bitDepth: 16, channels: 2, codec: "ALAC")
                let image = StatusItemRenderer.image(style: style, phase: .playing, format: other)
                guard image.size == a.size else { return false }
            }
        }
        return true
    }

    static func seekRoundtrip(monitor: AppleMusicNowPlaying, model: PanelModel) -> Bool {
        guard model.canSeek, model.trackDuration > 10, let original = readPosition(), original.id == model.trackID else { return false }
        let start = ProcessInfo.processInfo.systemUptime
        let playing = model.isPlaying
        let target = min(model.trackDuration - 3, max(1, original.position + 1.5))
        monitor.seek(to: target, trackID: original.id)
        spin(0.7)
        guard let moved = readPosition(), moved.id == original.id else { return false }
        let movedOK = abs(moved.position - target - (playing ? ProcessInfo.processInfo.systemUptime - start : 0)) < 1.0
        let naturalPosition = original.position + (playing ? ProcessInfo.processInfo.systemUptime - start : 0)
        let restoreTime = ProcessInfo.processInfo.systemUptime
        monitor.seek(to: naturalPosition, trackID: original.id)
        spin(0.6)
        guard let restored = readPosition(), restored.id == original.id else { return false }
        let restoredOK = abs(restored.position - naturalPosition - (playing ? ProcessInfo.processInfo.systemUptime - restoreTime : 0)) < 1.0
        // A stale drag must be rejected before it reaches Music.
        let beforeStale = model.playbackPosition
        monitor.seek(to: 0, trackID: "FFFFFFFFFFFFFFFF")
        let staleRejected = model.playbackPosition == beforeStale
        print("Seek roundtrip=\(movedOK && restoredOK); stale-track drag rejected=\(staleRejected)")
        return movedOK && restoredOK && staleRejected
    }

    static func spin(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func readPosition() -> (id: String, position: Double)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "with timeout of 5 seconds\ntell application id \"com.apple.Music\" to return (persistent ID of current track as text) & (ASCII character 31) & (player position as text)\nend timeout"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let parts = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
        guard task.terminationStatus == 0, parts.count == 2, let position = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (parts[0], position)
    }
}
#endif
