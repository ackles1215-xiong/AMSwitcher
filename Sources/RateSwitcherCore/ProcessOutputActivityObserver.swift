import CoreAudio
import Foundation

/// Main-thread observer for one player's audio-engine output state.
/// Callers retain a low-frequency fallback for unsupported or rejected listeners.
public final class ProcessOutputActivityObserver {
    public var onChange: (() -> Void)?
    public private(set) var isAttached = false
    private var pid: pid_t?
    private var processObject = AudioObjectID(kAudioObjectUnknown)
    private var processBlock: AudioObjectPropertyListenerBlock?
    private var listBlock: AudioObjectPropertyListenerBlock?
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    public init() {
        guard #available(macOS 14.2, *) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebind()
            self?.onChange?()
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(systemObject, &address, .main, block) == noErr { listBlock = block }
    }
    deinit { stop() }

    public func update(pid: pid_t?) {
        guard self.pid != pid || !isAttached else { return }
        self.pid = pid
        rebind()
    }

    public func stop() {
        detachProcess()
        if #available(macOS 14.2, *), let block = listBlock {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, .main, block)
        }
        listBlock = nil
        pid = nil
    }

    private func rebind() {
        guard #available(macOS 14.2, *) else { return }
        var object = AudioObjectID(kAudioObjectUnknown)
        if var value = pid {
            var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let result = withUnsafePointer(to: &value) {
                AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), $0, &size, &object)
            }
            if result != noErr { object = AudioObjectID(kAudioObjectUnknown) }
        }
        if object == processObject && isAttached { return }
        detachProcess()
        guard object != kAudioObjectUnknown else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        var address = Self.address(kAudioProcessPropertyIsRunningOutput)
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            processObject = object
            processBlock = block
            isAttached = true
        }
    }

    private func detachProcess() {
        if #available(macOS 14.2, *), let block = processBlock {
            var address = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(processObject, &address, .main, block)
        }
        processBlock = nil
        processObject = AudioObjectID(kAudioObjectUnknown)
        isAttached = false
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// A paused Music app may keep its Core Audio output engine running silently.
public enum PlaybackActivityGate {
    public static func isPlaying(outputRunning: Bool, playerState: String?) -> Bool {
        if playerState == "Paused" || playerState == "Stopped" { return false }
        return outputRunning
    }
}
