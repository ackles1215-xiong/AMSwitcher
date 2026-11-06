import AppKit
import ImageIO

/// Optional presentation layer. Audio-format detection never depends on it.
/// Artwork refreshes on panel open, player notification or user action.
/// A lightweight position check runs only while the panel is visible.
final class AppleMusicNowPlaying {
    private weak var model: PanelModel?
    private var visible = false
    private var generation = 0
    private var notificationToken: NSObjectProtocol?
    private var exitToken: NSObjectProtocol?
    private let worker = DispatchQueue(label: "musicrateswitcher.am.metadata", qos: .utility)
    private var lastTrackKey: String?
    private var reading = false
    private var needsRefresh = false
    private var progressTimer: Timer?
    private var anchorPosition: Double = 0
    private var anchorTime = ProcessInfo.processInfo.systemUptime
    private var lastPositionRead: Double = 0
    private var positionReading = false
    private var progressInterval: TimeInterval = 0
    private var cachedArtworkID = ""
    private(set) var artworkReadCount = 0
    private(set) var artworkCacheHitCount = 0

    init(model: PanelModel) {
        self.model = model
        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo ?? [:]
            let key = "\(info["Name"] ?? "")|\(info["Artist"] ?? "")|\(info["Album"] ?? "")"
            if key != self.lastTrackKey {
                self.lastTrackKey = key
                self.generation += 1
                self.cachedArtworkID = ""
                if self.model?.artwork != nil { self.model?.artwork = nil }
                self.resetProgress()
                self.model?.trackTitle = info["Name"] as? String ?? "Apple Music"
                self.model?.trackArtist = info["Artist"] as? String ?? "歌曲信息暂不可用"
            }
            let playing = (info["Player State"] as? String) == "Playing"
            if self.model?.isPlaying != playing { self.model?.isPlaying = playing }
            self.updateProgressTimer()
            if self.visible { self.refresh() }
        }
        exitToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music" else { return }
            self?.clear()
        }
    }

    func stop() {
        if let notificationToken { DistributedNotificationCenter.default().removeObserver(notificationToken) }
        if let exitToken { NSWorkspace.shared.notificationCenter.removeObserver(exitToken) }
        notificationToken = nil
        exitToken = nil
        generation += 1
        progressTimer?.invalidate()
        progressTimer = nil
    }
    deinit { stop() }

    func setVisible(_ value: Bool) {
        visible = value
        if value { refresh() }
        else { generation += 1 }
        updateProgressTimer()
    }

    private func updateProgressTimer() {
        let interval: TimeInterval = visible && model?.canSeek == true ? (model?.isPlaying == true ? 0.5 : 4) : 0
        guard interval != progressInterval else { return }
        progressTimer?.invalidate()
        progressTimer = nil
        progressInterval = interval
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tickProgress() }
        timer.tolerance = interval == 0.5 ? 0.1 : 0.5
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func clear() {
        generation += 1
        lastTrackKey = nil
        cachedArtworkID = ""
        model?.trackTitle = "Apple Music"
        model?.trackArtist = "打开 Apple Music，开始聆听"
        model?.artwork = nil
        model?.isPlaying = false
        model?.canControlPlayback = false
        model?.metadataHint = nil
        resetProgress()
    }

    func refresh() {
        guard visible else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else {
            clear()
            return
        }
        if reading { needsRefresh = true; return }
        reading = true
        needsRefresh = false
        let request = generation
        let cachedID = model?.artwork != nil && Self.validID(cachedArtworkID) ? cachedArtworkID : ""
        worker.async { [weak self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mrs-art-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let art = folder.appendingPathComponent("artwork")
            let script = """
            with timeout of 5 seconds
                tell application id "com.apple.Music"
                    set playbackState to player state as text
                    set t to current track
                    set titleText to name of t
                    set artistText to artist of t
                    set albumText to album of t
                    set durationText to "-1"
                    set positionText to "-1"
                    set identityText to ""
                    try
                        set identityText to persistent ID of t as text
                        set durationText to duration of t as text
                        set positionText to player position as text
                    end try
                    set artworkState to "missing"
                    if identityText is not "" and identityText is "\(cachedID)" then
                        set artworkState to "cached"
                    else
                        try
                            set imageBytes to raw data of artwork 1 of t
                            set f to open for access POSIX file "\(art.path)" with write permission
                            try
                                set eof f to 0
                                write imageBytes to f
                                set artworkState to "loaded"
                            end try
                            close access f
                        end try
                    end if
                    return titleText & (ASCII character 31) & artistText & (ASCII character 31) & albumText & (ASCII character 31) & playbackState & (ASCII character 31) & durationText & (ASCII character 31) & positionText & (ASCII character 31) & identityText & (ASCII character 31) & artworkState
                end tell
            end timeout
            """
            let result = Self.run(script)
            var image: NSImage?
            // Bound decoded artwork memory regardless of the embedded cover resolution.
            if FileManager.default.fileExists(atPath: art.path),
               let source = CGImageSourceCreateWithURL(art as CFURL, nil),
               let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: 512,
                   kCGImageSourceCreateThumbnailWithTransform: true
               ] as CFDictionary) {
                image = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
            }
            let cover = image
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                if self.visible && request == self.generation {
                    let parts = result.text.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
                    if result.success && parts.count == 8 {
                        self.lastTrackKey = "\(parts[0])|\(parts[1])|\(parts[2])"
                        if self.model?.trackTitle != parts[0] { self.model?.trackTitle = parts[0] }
                        let artist = [parts[1], parts[2]].filter { !$0.isEmpty }.joined(separator: " · ")
                        if self.model?.trackArtist != artist { self.model?.trackArtist = artist }
                        let playing = parts[3] == "playing"
                        if self.model?.isPlaying != playing { self.model?.isPlaying = playing }
                        if self.model?.canControlPlayback != true { self.model?.canControlPlayback = true }
                        if parts[7] == "cached", parts[6] == self.cachedArtworkID, self.model?.artwork != nil {
                            self.artworkCacheHitCount += 1
                        } else {
                            self.artworkReadCount += 1
                            self.cachedArtworkID = cover != nil ? parts[6] : ""
                            self.model?.artwork = cover
                        }
                        self.acceptProgress(duration: Self.number(parts[4]), position: Self.number(parts[5]), identity: parts[6])
                        let hint: String? = self.model?.artwork == nil ? "此曲目暂无可读取封面" : nil
                        if self.model?.metadataHint != hint { self.model?.metadataHint = hint }
                    } else {
                        self.model?.artwork = nil
                        self.model?.canControlPlayback = false
                        self.resetProgress()
                        self.model?.metadataHint = "歌曲信息暂不可用 · 不影响采样率匹配"
                    }
                }
                if self.needsRefresh && self.visible { self.refresh() }
            }
        }
    }

    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? -1
    }

    private static func validID(_ identity: String) -> Bool {
        identity.count == 16 && identity.allSatisfy { $0.isHexDigit }
    }

    private func resetProgress() {
        if model?.trackID != "" { model?.trackID = "" }
        if model?.trackDuration != 0 { model?.trackDuration = 0 }
        model?.playbackPosition = 0
        if model?.canSeek != false { model?.canSeek = false }
        updateProgressTimer()
        anchorPosition = 0
        anchorTime = ProcessInfo.processInfo.systemUptime
    }

    private func acceptProgress(duration: Double, position: Double, identity: String) {
        guard duration.isFinite, position.isFinite, duration > 0, position >= 0, Self.validID(identity) else {
            resetProgress()
            return
        }
        if model?.trackID != identity { model?.trackID = identity }
        if model?.trackDuration != duration { model?.trackDuration = duration }
        if model?.canSeek != true { model?.canSeek = true }
        anchorPosition = min(duration, position)
        anchorTime = ProcessInfo.processInfo.systemUptime
        lastPositionRead = anchorTime
        model?.playbackPosition = anchorPosition
        updateProgressTimer()
    }

    private func tickProgress() {
        guard visible, let model, model.canSeek else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if model.isPlaying { model.playbackPosition = min(model.trackDuration, anchorPosition + max(0, now - anchorTime)) }
        if now - lastPositionRead >= 4 { readPosition() }
    }

    private func readPosition() {
        guard visible, !positionReading, let model, Self.validID(model.trackID) else { return }
        positionReading = true
        lastPositionRead = ProcessInfo.processInfo.systemUptime
        let request = generation
        worker.async { [weak self] in
            let script = """
            with timeout of 5 seconds
                tell application id "com.apple.Music"
                    set t to current track
                    return (persistent ID of t as text) & (ASCII character 31) & (duration of t as text) & (ASCII character 31) & (player position as text) & (ASCII character 31) & (player state as text)
                end tell
            end timeout
            """
            let result = Self.run(script)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.positionReading = false
                guard self.visible, request == self.generation else { return }
                let parts = result.text.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
                guard result.success, parts.count == 4 else {
                    self.resetProgress()
                    return
                }
                guard parts[0] == self.model?.trackID else {
                    self.generation += 1
                    self.cachedArtworkID = ""
                    if self.model?.artwork != nil { self.model?.artwork = nil }
                    self.resetProgress()
                    self.refresh()
                    return
                }
                let playing = parts[3] == "playing"
                if self.model?.isPlaying != playing { self.model?.isPlaying = playing }
                self.acceptProgress(duration: Self.number(parts[1]), position: Self.number(parts[2]), identity: parts[0])
            }
        }
    }

    func seek(to seconds: Double, trackID: String) {
        guard seconds.isFinite, let model, model.canSeek, trackID == model.trackID,
              Self.validID(trackID), model.trackDuration > 0 else { return }
        let target = min(max(0, seconds), max(0, model.trackDuration - 0.1))
        generation += 1
        let request = generation
        anchorPosition = target
        anchorTime = ProcessInfo.processInfo.systemUptime
        model.playbackPosition = target
        worker.async { [weak self] in
            let script = """
            with timeout of 5 seconds
                tell application id "com.apple.Music"
                    set t to current track
                    if (persistent ID of t as text) is not "\(trackID)" then error "Track changed"
                    set d to duration of t
                    set targetPosition to \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), target))
                    if targetPosition > d then set targetPosition to d
                    set player position to targetPosition
                    return player position as text
                end tell
            end timeout
            """
            let result = Self.run(script)
            DispatchQueue.main.async { [weak self] in
                guard let self, request == self.generation, self.model?.trackID == trackID else { return }
                let actual = Self.number(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if result.success && actual.isFinite && actual >= 0 {
                    self.anchorPosition = actual
                    self.anchorTime = ProcessInfo.processInfo.systemUptime
                    self.model?.playbackPosition = actual
                } else {
                    self.model?.metadataHint = "此曲目暂时无法跳转进度"
                }
                self.readPosition()
            }
        }
    }

    func transport(_ command: String) {
        guard ["playpause", "previous track", "next track"].contains(command),
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return }
        worker.async { [weak self] in
            let result = Self.run("with timeout of 5 seconds\ntell application id \"com.apple.Music\" to \(command)\nend timeout")
            DispatchQueue.main.async {
                if !result.success { self?.model?.metadataHint = "播放控制未获授权或暂不可用" }
                self?.refresh()
            }
        }
    }

    private static func run(_ script: String) -> (success: Bool, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Also bound the process if Music is unresponsive or a consent prompt is left open.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 7, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
        } catch { return (false, "") }
    }
}
