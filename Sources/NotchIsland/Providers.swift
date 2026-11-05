import AppKit
import CoreAudio
import CoreMediaIO
import ApplicationServices
import Carbon.HIToolbox
import IOBluetooth
import IOKit.ps
import IslandCore

enum SystemReader {
    static func battery() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = max(d[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            return BatteryState(
                percent: current * 100 / maxCapacity,
                onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                charging: d[kIOPSIsChargingKey] as? Bool ?? false
            )
        }
        return nil
    }
}

enum MusicControl: String {
    case playPause = "playpause"
    case next = "next track"
    case previous = "previous track"

    /// Scripts only the player that sent us its state, so nothing launches by surprise.
    func send(to source: MusicSource) {
        let script = "tell application \"\(source.rawValue)\" to \(rawValue)"
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }
}

// MARK: - Volume (CoreAudio)


final class VolumeWatcher {
    private let onChange: (Double, Bool) -> Void
    private let onDeviceChange: ((String) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var last: (Double, Bool)?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var systemListener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping (Double, Bool) -> Void, onDeviceChange: ((String) -> Void)? = nil) {
        self.onChange = onChange
        self.onDeviceChange = onDeviceChange
        attach()
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.detachDevice()
                self.attach()
                self.emit(force: false)
                if let name = Self.name(of: self.device) { self.onDeviceChange?(name) }
            }
        }
        systemListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private static func name(of id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName) == noErr, let cfName else { return nil }
        return cfName.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private func attach() {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return }
        device = id
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.emit(force: false) }
        }
        deviceListener = block
        for (selector, element) in Self.watched {
            var a = Self.address(selector, element: element)
            AudioObjectAddPropertyListenerBlock(device, &a, .main, block)
        }
        last = read()
    }

    private func detachDevice() {
        guard let block = deviceListener, device != kAudioObjectUnknown else { return }
        for (selector, element) in Self.watched {
            var a = Self.address(selector, element: element)
            AudioObjectRemovePropertyListenerBlock(device, &a, .main, block)
        }
    }

    private static let watched: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
        (kAudioDevicePropertyVolumeScalar, 0), (kAudioDevicePropertyVolumeScalar, 1), (kAudioDevicePropertyVolumeScalar, 2),
        (kAudioDevicePropertyMute, 0), (kAudioDevicePropertyMute, 1),
    ]

    private func float(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float32? {
        var a = Self.address(selector, element: element)
        guard AudioObjectHasProperty(device, &a) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func read() -> (Double, Bool)? {
        guard device != kAudioObjectUnknown else { return nil }
        let level = float(kAudioDevicePropertyVolumeScalar, element: 0)
            ?? [float(kAudioDevicePropertyVolumeScalar, element: 1), float(kAudioDevicePropertyVolumeScalar, element: 2)].compactMap { $0 }.max()
        guard let level else { return nil }
        var muted = false
        for element in [AudioObjectPropertyElement(0), 1] {
            var a = Self.address(kAudioDevicePropertyMute, element: element)
            guard AudioObjectHasProperty(device, &a) else { continue }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr { muted = value != 0; break }
        }
        return (Double(level), muted)
    }

    private func emit(force: Bool) {
        guard let now = read() else { return }
        defer { last = now }
        if let last, last.0 == now.0, last.1 == now.1, !force { return }
        if last == nil { return }
        onChange(now.0, now.1)
    }
}

// MARK: - Brightness (private DisplayServices, resolved at runtime)

enum BrightnessReader {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let getFn: GetFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetFn.self)
    }()

    static var available: Bool { getFn != nil }

    static func read() -> Double? {
        guard let getFn else { return nil }
        var id = CGMainDisplayID()
        var online = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(8, &online, &count) == .success, let builtin = online.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            id = builtin
        }
        var value: Float = 0
        return getFn(id, &value) == 0 ? Double(value) : nil
    }
}

// MARK: - Focus

enum FocusReader {
    private static let dir = NSHomeDirectory() + "/Library/DoNotDisturb/DB/"

    static func active() -> (id: String?, readable: Bool) {
        guard let data = FileManager.default.contents(atPath: dir + "Assertions.json") else { return (nil, false) }
        return (FocusParser.activeModeIdentifier(assertions: data), true)
    }

    static func modes() -> [String: FocusMode] {
        FileManager.default.contents(atPath: dir + "ModeConfigurations.json").map(FocusParser.modes(configurations:)) ?? [:]
    }
}

// MARK: - Caps Lock

enum KeyboardState {
    /// Reads the live modifier state; needs no Accessibility or Input Monitoring permission.
    static var capsLockOn: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }
}

// MARK: - Camera / microphone in use

enum PrivacyReader {
    static func state() -> PrivacyState {
        PrivacyState(camera: cameraRunning(), mic: micRunning())
    }

    private static func micRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &running, 0, nil, &valueSize, &value) == noErr, value != 0 { return true }
        }
        return false
    }

    private static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var ids = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == 0 else { return false }
        for id in ids {
            var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var value: UInt32 = 0
            var valueUsed: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &valueUsed, &value) == 0, value != 0 { return true }
        }
        return false
    }
}

// MARK: - Bluetooth connections

final class BluetoothWatcher: NSObject {
    private let onConnect: (String) -> Void
    private var registration: IOBluetoothUserNotification?

    init(onConnect: @escaping (String) -> Void) {
        self.onConnect = onConnect
        super.init()
        registration = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:fromDevice:)))
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        guard let name = device.name, !name.isEmpty else { return }
        DispatchQueue.main.async { self.onConnect(name) }
    }

    /// system_profiler is slow (about a second), so it runs off the main thread.
    static func batteryPercent(for name: String, completion: @escaping (Int?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            task.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            var result: Int?
            if (try? task.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                result = BluetoothInfo.battery(profilerJSON: data, deviceName: name)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// MARK: - Now playing details (position and artwork)

enum PlayerQuery {
    private static let queue = DispatchQueue(label: "notchisland.player", qos: .userInitiated)

    static func position(of source: MusicSource, completion: @escaping (Double?) -> Void) {
        queue.async {
            let value = NSAppleScript(source: "tell application \"\(source.rawValue)\" to get player position")?
                .executeAndReturnError(nil).stringValue.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// Spotify exposes an artwork URL; Music exposes raw image bytes.
    static func artwork(of source: MusicSource, completion: @escaping (NSImage?) -> Void) {
        queue.async {
            var image: NSImage?
            switch source {
            case .spotify:
                if let urlString = NSAppleScript(source: "tell application \"Spotify\" to get artwork url of current track")?
                    .executeAndReturnError(nil).stringValue, let url = URL(string: urlString),
                   let data = try? Data(contentsOf: url) {
                    image = NSImage(data: data)
                }
            case .music:
                if let data = NSAppleScript(source: "tell application \"Music\" to get data of artwork 1 of current track")?
                    .executeAndReturnError(nil).data {
                    image = NSImage(data: data) ?? NSImage(data: data.dropFirst(4))
                }
            }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

// MARK: - Touch ID / password prompt

enum AuthPromptReader {
    /// Window owner names are visible without Screen Recording permission.
    static func visible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return isAuthPromptVisible(owners: list.compactMap { $0[kCGWindowOwnerName as String] as? String })
    }
}

// MARK: - Global hotkey (Carbon; needs no permission)

final class HotKey {
    private var ref: EventHotKeyRef?
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false

    init?(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        Self.handlers[id] = handler
        if !Self.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                DispatchQueue.main.async { HotKey.handlers[hotKeyID.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            Self.installed = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E495348), id: id)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }
}

// MARK: - Incoming call / AirDrop banners (Accessibility)

/// Reads Notification Center banners through the Accessibility API and can press their buttons.
/// Needs the Accessibility permission; without it every call is a cheap no-op.
final class IncomingWatcher {
    private struct Target {
        let element: AXUIElement
        let action: String
    }

    private var targets: [String: Target] = [:]

    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func scan() -> IncomingRequest? {
        guard Self.trusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first,
              let windows = Self.value(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement],
              !windows.isEmpty else { targets = [:]; return nil }
        var texts: [String] = []
        var buttons: [String: Target] = [:]
        var budget = 150
        // Banners are system dialogs; desktop widgets in the same process are not, and must not be read.
        for window in windows where Self.value(window, kAXSubroleAttribute) as? String == "AXSystemDialog" {
            walk(window, depth: 0, texts: &texts, buttons: &buttons, budget: &budget)
        }
        guard let request = classifyBanner(texts: texts, buttons: Array(buttons.keys)) else { targets = [:]; return nil }
        targets = buttons
        return request
    }

    func press(_ label: String) {
        guard let target = targets[label] else { return }
        AXUIElementPerformAction(target.element, target.action as CFString)
    }

    private func walk(_ element: AXUIElement, depth: Int, texts: inout [String], buttons: inout [String: Target], budget: inout Int) {
        guard depth < 9, budget > 0 else { return }
        budget -= 1
        let role = Self.value(element, kAXRoleAttribute) as? String ?? ""
        if role == "AXStaticText", let text = Self.value(element, kAXValueAttribute) as? String, !text.isEmpty { texts.append(text) }
        if role == "AXButton" {
            let label = (Self.value(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.value(element, kAXDescriptionAttribute) as? String
            if let label, !label.isEmpty { buttons[label] = Target(element: element, action: kAXPressAction as String) }
        }
        // Banners expose buttons as custom actions named "Name:Accept\nTarget:..."
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success {
            for case let action as String in (names as? [Any] ?? []) where action.hasPrefix("Name:") {
                let label = action.dropFirst(5).prefix { $0 != "\n" }
                if !label.isEmpty { buttons[String(label)] = Target(element: element, action: action) }
            }
        }
        for child in Self.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            walk(child, depth: depth + 1, texts: &texts, buttons: &buttons, budget: &budget)
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out : nil
    }
}
