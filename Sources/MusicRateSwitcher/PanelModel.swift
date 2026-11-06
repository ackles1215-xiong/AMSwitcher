import AppKit
import CoreImage
import RateSwitcherCore

/// Commands the panel can send back to the app delegate.
protocol PanelActions: AnyObject {
    func setAutomatic(_ enabled: Bool)
    func openPlayer(_ player: MusicPlayerID)
    func selectDevice(uid: String?)
    func setMenuBarStyle(_ style: MenuBarStyle)
    func refreshNow()
    func openAudioMIDISetup()
    func showDiagnostics()
    func openLog()
    func copyDiagnostics()
    func showAbout()
    func transport(_ command: String)
    func seek(to seconds: Double, trackID: String)
    func quit()
}

enum PlayerPhase: Equatable {
    case disabled
    case notRunning
    case waiting
    case detecting
    case playing(SourceAudioFormat)
    case permissionRequired
    case error(String)
}

struct PlayerRowState: Identifiable, Equatable {
    let player: MusicPlayerID
    var phase: PlayerPhase
    var isEnabled: Bool
    var isInstalled: Bool
    var isActive: Bool

    var id: MusicPlayerID { player }
}

enum SyncState: Equatable {
    case idle
    case switching(Double)
    case matched(Double)
    case fallback(requested: Double, applied: Double)
    case failed(String)
}

final class PlaybackProgressModel: ObservableObject {
    @Published var position: Double = 0
}

/// Snapshot of everything the status item and popover render.
final class PanelModel: ObservableObject {
    @Published var players: [PlayerRowState] = [MusicPlayerID.appleMusic].map {
        PlayerRowState(player: $0, phase: .notRunning, isEnabled: true, isInstalled: false, isActive: false)
    }
    @Published var activeDetection: DetectedSourceFormat?
    @Published var devices: [AudioOutputDevice] = []
    @Published var selectedDevice: AudioOutputDevice?
    @Published var followsSystemDefault = true
    @Published var autoSwitch = true
    @Published var menuBarStyle: MenuBarStyle = .compact
    @Published var sync: SyncState = .idle
    @Published var trackTitle = "Apple Music"
    @Published var trackArtist = "打开面板后读取当前歌曲"
    @Published var artwork: NSImage? {
        didSet { artworkPalette = artwork.flatMap(Self.makePalette) ?? Self.defaultPalette }
    }
    @Published private(set) var artworkPalette: [NSColor] = PanelModel.defaultPalette
    let progress = PlaybackProgressModel()
    var playbackPosition: Double {
        get { progress.position }
        set { if progress.position != newValue { progress.position = newValue } }
    }
    @Published var trackDuration: Double = 0
    @Published var trackID = ""
    @Published var canSeek = false
    @Published var isPlaying = false
    @Published var canControlPlayback = false
    @Published var metadataHint: String?

    weak var actions: PanelActions?

    static let defaultPalette = [NSColor(srgbRed: 0.38, green: 0.17, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.10, green: 0.23, blue: 0.38, alpha: 1)]
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    // Only two average colours are retained. No artwork texture behind the player.
    private static func makePalette(_ image: NSImage) -> [NSColor]? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        return (0..<2).map { half in
            let area = CGRect(x: 0, y: CGFloat(half) * input.extent.height / 2, width: input.extent.width, height: input.extent.height / 2)
            let average = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: area)])
            var pixel = [UInt8](repeating: 0, count: 4)
            imageContext.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let color = NSColor(srgbRed: CGFloat(pixel[0])/255, green: CGFloat(pixel[1])/255, blue: CGFloat(pixel[2])/255, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return NSColor(calibratedHue: hue, saturation: min(0.8, max(0.35, saturation)), brightness: min(0.52, max(0.32, brightness)), alpha: 1)
        }
    }

    var version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

extension MusicPlayerID {
    var fallbackSymbol: String {
        switch self {
        case .appleMusic: return "music.note"
        case .neteaseMusic: return "waveform"
        case .qqMusic: return "music.note.list"
        case .sodaMusic: return "sparkles"
        }
    }

    /// Brand-ish tint used for the fallback glyph when the app is not installed.
    var tint: NSColor {
        switch self {
        case .appleMusic: return NSColor(srgbRed: 0.98, green: 0.24, blue: 0.33, alpha: 1)
        case .neteaseMusic: return NSColor(srgbRed: 0.87, green: 0.15, blue: 0.16, alpha: 1)
        case .qqMusic: return NSColor(srgbRed: 0.18, green: 0.75, blue: 0.47, alpha: 1)
        case .sodaMusic: return NSColor(srgbRed: 0.22, green: 0.47, blue: 0.98, alpha: 1)
        }
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var applicationIcon: NSImage? {
        if let cached = Self.iconCache[self] { return cached }
        guard let url = applicationURL else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache[self] = icon
        return icon
    }

    private static var iconCache: [MusicPlayerID: NSImage] = [:]
}

extension SourceAudioFormat {
    /// "96" / "44.1" — the number without the unit, for large typography.
    static func rateNumber(_ rate: Double) -> String {
        let kHz = rate / 1_000
        if abs(kHz.rounded() - kHz) < 0.001 { return String(format: "%.0f", kHz) }
        return String(format: "%.1f", kHz)
    }

    var channelDescription: String? {
        switch channels {
        case nil: return nil
        case 1: return "单声道"
        case 2: return "立体声"
        case let count?: return "\(count) 声道"
        }
    }

    var qualityLabel: String {
        if sampleRate > 48_000.5 || (bitDepth ?? 16) > 16 { return "Hi-Res" }
        let lossy = ["MP3", "AAC", "OGG", "OPUS", "VORBIS"].contains { codec.uppercased().hasPrefix($0) }
        return lossy ? "标准" : "无损"
    }
}
