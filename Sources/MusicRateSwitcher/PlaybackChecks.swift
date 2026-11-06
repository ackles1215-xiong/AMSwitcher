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

    static func performanceChecks(monitor: AppleMusicNowPlaying, model: PanelModel) -> Bool {
        guard model.artwork != nil, model.canSeek else { return false }
        let initialID = model.trackID
        let initialCover = model.artwork
        let reads = monitor.artworkReadCount
        let hits = monitor.artworkCacheHitCount
        for attempt in 1...2 {
            monitor.refresh()
            let deadline = Date().addingTimeInterval(4)
            while monitor.artworkCacheHitCount < hits + attempt && Date() < deadline { spin(0.05) }
        }
        let cached = model.trackID == initialID && model.artwork === initialCover && monitor.artworkReadCount == reads && monitor.artworkCacheHitCount >= hits + 2
        var panelChanges = 0
        let cancellable = model.objectWillChange.sink { panelChanges += 1 }
        let previous = model.playbackPosition
        model.playbackPosition = previous + 0.01
        let isolated = panelChanges == 0
        model.playbackPosition = previous
        cancellable.cancel()
        let observer = ProcessOutputActivityObserver()
        var audioEvents = 0
        observer.onChange = { audioEvents += 1 }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.processIdentifier
        observer.update(pid: pid)
        let attached = observer.isAttached
        var notifiedStates: [String] = []
        let token = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { note in
            if let state = note.userInfo?["Player State"] as? String { notifiedStates.append(state) }
        }
        var transitions = true
        if model.isPlaying {
            notifiedStates.removeAll()
            monitor.transport("playpause")
            let pauseDeadline = Date().addingTimeInterval(3)
            while !notifiedStates.contains("Paused") && Date() < pauseDeadline { spin(0.05) }
            let paused = readPlayerState() == "paused" && notifiedStates.contains("Paused")
            if readPlayerState() == "paused" {
                let resumeStart = notifiedStates.count
                monitor.transport("playpause")
                let playDeadline = Date().addingTimeInterval(3)
                while !notifiedStates.dropFirst(resumeStart).contains("Playing") && Date() < playDeadline { spin(0.05) }
                let actualState = readPlayerState()
                let resumed = actualState == "playing" && notifiedStates.dropFirst(resumeStart).contains("Playing")
                print("Notification states=\(notifiedStates); actual state=\(actualState)")
                transitions = paused && resumed && !PlaybackActivityGate.isPlaying(outputRunning: true, playerState: "Paused")
                print("Pause notification=\(paused); resume notification=\(resumed); optional audio callbacks=\(audioEvents)")
            } else { transitions = false }
        }
        DistributedNotificationCenter.default().removeObserver(token)
        observer.stop()
        monitor.setVisible(false)
        let readsBeforeHidden = monitor.artworkReadCount
        monitor.refresh()
        spin(0.6)
        let hidden = monitor.artworkReadCount == readsBeforeHidden
        monitor.setVisible(true)
        print("Same-track artwork reused=\(cached); progress updates isolated=\(isolated); audio listener attached=\(attached); play/pause events=\(transitions); hidden refresh suppressed=\(hidden)")
        return cached && isolated && attached && transitions && hidden
    }

    private static func readPlayerState() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "with timeout of 5 seconds\ntell application id \"com.apple.Music\" to return player state as text\nend timeout"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
