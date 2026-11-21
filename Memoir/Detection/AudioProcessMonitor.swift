import CoreAudio
import Foundation

/// Which apps hold the microphone, from Core Audio's per-process objects. Needs no permission.
///
/// Core Audio notifies reliably when the process list changes and when a process's
/// `IsRunning` flips, but not when `IsRunningInput` alone changes (measured on macOS 27.2:
/// listeners on `IsRunningInput` and `IsRunningOutput` never fired). A call app that already
/// plays audio and then opens the microphone produces no event, so while any meeting app or
/// browser is running audio the owner polls (`needsPolling`).
final class AudioProcessMonitor {
    /// Called on the main actor after anything that may change `microphoneUsers()`.
    var onChange: (() -> Void)?

    private struct Tracked {
        let pid: pid_t
        let user: MicrophoneUser
        let listener: AudioObjectPropertyListenerBlock
    }

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var tracked: [AudioObjectID: Tracked] = [:]
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private(set) var isRunning = false

    private static let processRunning = address(kAudioProcessPropertyIsRunning)
    private static let processRunningInput = address(kAudioProcessPropertyIsRunningInput)
    private static let systemProperties = [
        address(kAudioHardwarePropertyProcessObjectList),
        address(kAudioHardwarePropertyDevices),
    ]
    private static let deviceRunningSomewhere = address(kAudioDevicePropertyDeviceIsRunningSomewhere)

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let listener = Self.makeListener { [weak self] in self?.systemChanged() }
        systemListener = listener
        for var property in Self.systemProperties {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        }
        syncProcesses()
        syncInputDevices()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let systemListener {
            for var property in Self.systemProperties {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &property, .main, systemListener
                )
            }
        }
        systemListener = nil
        for id in Array(tracked.keys) { untrack(id) }
        for (id, listener) in deviceListeners {
            var property = Self.deviceRunningSomewhere
            AudioObjectRemovePropertyListenerBlock(id, &property, .main, listener)
        }
        deviceListeners = [:]
    }

    /// Owning apps that currently run microphone input, excluding Memoir itself.
    func microphoneUsers() -> [MicrophoneUser] {
        guard isRunning else { return [] }
        var users: [MicrophoneUser] = []
        for (id, entry) in tracked where entry.pid != ownPID && Self.bool(id, Self.processRunningInput) {
            if !users.contains(entry.user) {
                users.append(entry.user)
            }
        }
        return users
    }

    /// True while a meeting app or browser runs any audio, the only time a microphone change
    /// can go unannounced.
    var needsPolling: Bool {
        guard isRunning else { return false }
        return tracked.contains { id, entry in
            entry.user.category != .other && Self.bool(id, Self.processRunning)
        }
    }

    // MARK: - Listeners

    private func systemChanged() {
        syncProcesses()
        syncInputDevices()
        onChange?()
    }

    private func syncProcesses() {
        guard isRunning else { return }
        let ids = Set(Self.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList))
        for id in tracked.keys where !ids.contains(id) {
            untrack(id)
        }
        for id in ids where tracked[id] == nil {
            track(id)
        }
    }

    private func track(_ id: AudioObjectID) {
        let process = AudioHardwareProcess(id: id)
        guard let pid = try? process.pid, pid > 0 else { return }
        let user = ProcessIdentity.microphoneUser(pid: pid, bundleID: try? process.bundleID)
        let listener = Self.makeListener { [weak self] in self?.onChange?() }
        // IsRunningInput is registered too in case a later OS starts announcing it.
        for var property in [Self.processRunning, Self.processRunningInput] {
            AudioObjectAddPropertyListenerBlock(id, &property, .main, listener)
        }
        tracked[id] = Tracked(pid: pid, user: user, listener: listener)
    }

    private func untrack(_ id: AudioObjectID) {
        guard let entry = tracked.removeValue(forKey: id) else { return }
        // Fails harmlessly when the process object is already gone.
        for var property in [Self.processRunning, Self.processRunningInput] {
            AudioObjectRemovePropertyListenerBlock(id, &property, .main, entry.listener)
        }
    }

    /// Any input device starting or stopping is a cheap extra trigger for the gap above.
    private func syncInputDevices() {
        guard isRunning else { return }
        let inputs = Set(Self.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
            .filter(Self.hasInput))
        for (id, listener) in deviceListeners where !inputs.contains(id) {
            var property = Self.deviceRunningSomewhere
            AudioObjectRemovePropertyListenerBlock(id, &property, .main, listener)
            deviceListeners[id] = nil
        }
        for id in inputs where deviceListeners[id] == nil {
            let listener = Self.makeListener { [weak self] in self?.onChange?() }
            var property = Self.deviceRunningSomewhere
            if AudioObjectAddPropertyListenerBlock(id, &property, .main, listener) == noErr {
                deviceListeners[id] = listener
            }
        }
    }

    // MARK: - Core Audio helpers

    /// Built outside the main actor's isolation so the block carries no isolation assumption
    /// of its own; it is delivered on the main queue, which `assumeIsolated` then relies on.
    private nonisolated static func makeListener(
        _ handler: @escaping @MainActor () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func bool(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func objectIDs(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
