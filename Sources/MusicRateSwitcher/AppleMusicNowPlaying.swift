import AppKit
import ImageIO

/// Optional presentation layer. Audio-format detection never depends on it.
/// No periodic metadata polling: refresh on panel open, player notification or user action.
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

    init(model: PanelModel) {
        self.model = model
        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo ?? [:]
            let key = "\(info["PersistentID"] ?? "")|\(info["Name"] ?? "")|\(info["Artist"] ?? "")|\(info["Album"] ?? "")"
            if key != self.lastTrackKey {
                self.lastTrackKey = key
                self.generation += 1
                self.model?.artwork = nil
                self.model?.trackTitle = info["Name"] as? String ?? "Apple Music"
                self.model?.trackArtist = info["Artist"] as? String ?? "歌曲信息暂不可用"
            }
            self.model?.isPlaying = (info["Player State"] as? String) == "Playing"
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
    }
    deinit { stop() }

    func setVisible(_ value: Bool) {
        visible = value
        if value { refresh() }
        else { generation += 1 }
    }

    private func clear() {
        generation += 1
        lastTrackKey = nil
        model?.trackTitle = "Apple Music"
        model?.trackArtist = "打开 Apple Music，开始聆听"
        model?.artwork = nil
        model?.isPlaying = false
        model?.canControlPlayback = false
        model?.metadataHint = nil
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
                    try
                        set imageBytes to raw data of artwork 1 of t
                        set f to open for access POSIX file "\(art.path)" with write permission
                        try
                            set eof f to 0
                            write imageBytes to f
                        end try
                        close access f
                    end try
                    return titleText & (ASCII character 31) & artistText & (ASCII character 31) & albumText & (ASCII character 31) & playbackState
                end tell
            end timeout
            """
            let result = Self.run(script)
            var image: NSImage?
            // Bound decoded artwork memory regardless of the embedded cover resolution.
            if let source = CGImageSourceCreateWithURL(art as CFURL, nil),
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
                    if result.success && parts.count == 4 {
                        self.model?.trackTitle = parts[0]
                        self.model?.trackArtist = [parts[1], parts[2]].filter { !$0.isEmpty }.joined(separator: " · ")
                        self.model?.isPlaying = parts[3] == "playing"
                        self.model?.canControlPlayback = true
                        self.model?.artwork = cover
                        self.model?.metadataHint = cover == nil ? "此曲目暂无可读取封面" : nil
                    } else {
                        self.model?.artwork = nil
                        self.model?.canControlPlayback = false
                        self.model?.metadataHint = "歌曲信息暂不可用 · 不影响采样率匹配"
                    }
                }
                if self.needsRefresh && self.visible { self.refresh() }
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
