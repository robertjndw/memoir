import CoreMediaIO
import Foundation

/// Whether any camera is in use by any process. Reading this needs no camera permission.
final class CameraMonitor {
    /// Called on the main actor when `isActive` may have changed.
    var onChange: (() -> Void)?

    private var systemListener: CMIOObjectPropertyListenerBlock?
    private var deviceListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private(set) var isRunning = false

    private static let devicesAddress = address(kCMIOHardwarePropertyDevices)
    private static let runningSomewhereAddress = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
    private static let systemObject = CMIOObjectID(kCMIOObjectSystemObject)

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let listener = Self.makeListener { [weak self] in
            self?.syncDevices()
            self?.onChange?()
        }
        var address = Self.devicesAddress
        if CMIOObjectAddPropertyListenerBlock(Self.systemObject, &address, .main, listener) == noErr {
            systemListener = listener
        }
        syncDevices()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let systemListener {
            var address = Self.devicesAddress
            CMIOObjectRemovePropertyListenerBlock(Self.systemObject, &address, .main, systemListener)
        }
        systemListener = nil
        for (id, listener) in deviceListeners {
            var address = Self.runningSomewhereAddress
            CMIOObjectRemovePropertyListenerBlock(id, &address, .main, listener)
        }
        deviceListeners = [:]
    }

    var isActive: Bool {
        guard isRunning else { return false }
        return deviceListeners.keys.contains { id in
            var address = Self.runningSomewhereAddress
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return CMIOObjectGetPropertyData(id, &address, 0, nil, size, &size, &value) == noErr && value != 0
        }
    }

    private func syncDevices() {
        guard isRunning else { return }
        let devices = Set(Self.deviceIDs())
        for (id, listener) in deviceListeners where !devices.contains(id) {
            var address = Self.runningSomewhereAddress
            CMIOObjectRemovePropertyListenerBlock(id, &address, .main, listener)
            deviceListeners[id] = nil
        }
        for id in devices where deviceListeners[id] == nil {
            let listener = Self.makeListener { [weak self] in self?.onChange?() }
            var address = Self.runningSomewhereAddress
            if CMIOObjectAddPropertyListenerBlock(id, &address, .main, listener) == noErr {
                deviceListeners[id] = listener
            }
        }
    }

    private static func deviceIDs() -> [CMIOObjectID] {
        var address = devicesAddress
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemObject, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    /// See `AudioProcessMonitor.makeListener` for why this is nonisolated.
    private nonisolated static func makeListener(
        _ handler: @escaping @MainActor () -> Void
    ) -> CMIOObjectPropertyListenerBlock {
        { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private nonisolated static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}
