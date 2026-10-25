import AppKit
import CoreAudio
import CoreGraphics

/// Moments when Miku shouldn't start talking on her own, even with reading aloud on and
/// not muted: you're on a call or recording (another app is using the microphone), or
/// something is full screen in front (a film, a game, a presentation). Neither needs any
/// permission. Replays and previews you ask for still play.
///
/// macOS Focus itself isn't read: that needs the Communication Notifications entitlement
/// and a provisioning profile, which this app doesn't have.
enum SpeechQuietTimes {
    static func isQuietNow() -> Bool {
        microphoneInUse() || frontmostAppIsFullScreen()
    }

    /// A process has active input streams: a call, a meeting, or a recording.
    static func microphoneInUse() -> Bool {
        if #available(macOS 14.2, *), let running = processIsRunningInput() {
            return running
        }

        // Before 14.2 Core Audio only reports whether a whole device is running. That is
        // unambiguous for an input-only device; a duplex device may merely be playing audio.
        guard let deviceID = defaultInputDevice(),
              let hasOutputStreams = deviceHasOutputStreams(deviceID),
              let isRunning = deviceIsRunning(deviceID) else { return false }
        return inputOnlyDeviceIsCapturing(isRunning: isRunning, hasOutputStreams: hasOutputStreams)
    }

    @available(macOS 14.2, *)
    private static func processIsRunningInput() -> Bool? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        guard size > 0 else { return false }
        var processes = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        let status = processes.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return nil }

        var readRunningState = false
        let processCount = Int(size) / MemoryLayout<AudioObjectID>.size
        for process in processes.prefix(processCount) {
            var running: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &valueSize, &running) == noErr else {
                continue
            }
            readRunningState = true
            guard running != 0 else { continue }

            var processID = pid_t(0)
            valueSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &valueSize, &processID) == noErr,
               processID == ProcessInfo.processInfo.processIdentifier {
                continue
            }
            return true
        }
        return readRunningState ? false : nil
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func deviceHasOutputStreams(_ deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
        return size > 0
    }

    private static func deviceIsRunning(_ deviceID: AudioDeviceID) -> Bool? {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }

    static func inputOnlyDeviceIsCapturing(isRunning: Bool, hasOutputStreams: Bool) -> Bool {
        isRunning && !hasOutputStreams
    }

    /// The app in front has a window covering a whole screen (full screen video, games,
    /// presentations). Window bounds and owners are available without Screen Recording.
    static func frontmostAppIsFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let screens = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            // CGWindow bounds use Quartz's top-left global coordinate system. CGDisplayBounds
            // supplies matching coordinates; NSScreen.frame uses AppKit's bottom-left system.
            return CGDisplayBounds(number.uint32Value)
        }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { continue }
            if coversScreen(CGRect(x: x, y: y, width: width, height: height), screens: screens) { return true }
        }
        return false
    }

    /// A window covers one actual display, including its position in a multi-display layout.
    static func coversScreen(_ bounds: CGRect, screens: [CGRect]) -> Bool {
        screens.contains {
            abs($0.minX - bounds.minX) < 1
                && abs($0.minY - bounds.minY) < 1
                && abs($0.width - bounds.width) < 1
                && abs($0.height - bounds.height) < 1
        }
    }
}
