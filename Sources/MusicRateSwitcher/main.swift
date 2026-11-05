import AppKit
import RateSwitcherCore

let application = NSApplication.shared

#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--metadata-check"), index + 1 < CommandLine.arguments.count {
    application.setActivationPolicy(.accessory)
    let model = PanelModel()
    let audio = CoreAudioController()
    model.devices = audio.outputDevices()
    model.selectedDevice = model.devices.first(where: \.isDefault)
    model.version = "1.4.0"
    let source = AppleMusicPlaybackMonitor()
    source.onFormatChanged = { detection in
        DispatchQueue.main.async {
            model.activeDetection = detection
            if let output = model.selectedDevice, abs(output.sampleRate - detection.format.sampleRate) < 0.5 {
                model.sync = .matched(output.sampleRate)
            }
        }
    }
    source.start()
    let monitor = AppleMusicNowPlaying(model: model)
    monitor.setVisible(true)
    let deadline = Date().addingTimeInterval(10)
    while (model.artwork == nil || model.activeDetection == nil) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    SnapshotRenderer.render(PanelView(model: model), to: output.appendingPathComponent("panel-live.png"), appearance: .darkAqua)
    print("Metadata=\(model.trackTitle != "Apple Music"); artwork=\(model.artwork != nil); boundedArtwork=\((model.artwork?.size.width ?? 0) <= 512); gradientPalette=\(model.artworkPalette.count == 2); controls=\(model.canControlPlayback)")
    monitor.setVisible(false)
    monitor.stop()
    source.stop()
    exit(model.artwork != nil && model.canControlPlayback ? 0 : 2)
}
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    application.setActivationPolicy(.accessory)
    SnapshotRenderer.run(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}
#endif

let delegate = AppDelegate()
application.delegate = delegate
application.run()
