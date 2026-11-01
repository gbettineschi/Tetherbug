import AppKit
import Darwin
import IOKit
import IOKit.pwr_mgt
import SystemConfiguration

/// No sleep assertion: promptly acknowledge sleep after invalidating the agent's work.
final class SystemPowerMonitor {
    private typealias ReadCapabilities = @convention(c) () -> UInt32
    private static let readCapabilities: ReadCapabilities? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let symbol = dlsym(handle, "IOPMConnectionGetSystemCapabilities") else { return nil }
        return unsafeBitCast(symbol, to: ReadCapabilities.self)
    }()
    static func capabilities() -> UInt32? { readCapabilities?() }

    private var port: IONotificationPortRef?
    private var root: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var capabilitiesStore: SCDynamicStore?
    private var wakeObserver: NSObjectProtocol?
    private let onEvent: (PowerActivity.Event) -> Void

    init(onEvent: @escaping (PowerActivity.Event) -> Void) { self.onEvent = onEvent }

    func start() -> Bool {
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let monitor = Unmanaged<SystemPowerMonitor>.fromOpaque(context).takeUnretainedValue()
            switch message {
            // IOMessage.h's function-like macros are not imported by Swift.
            case 0xe0000280: // kIOMessageSystemWillSleep
                monitor.onEvent(.willSleep)
                IOAllowPowerChange(monitor.root, Int(bitPattern: argument))
            case 0xe0000270: // kIOMessageCanSystemSleep
                IOAllowPowerChange(monitor.root, Int(bitPattern: argument))
            case 0xe0000300: monitor.onEvent(.didWake) // kIOMessageSystemHasPoweredOn
            default: break
            }
        }, &notifier)
        guard root != 0, let port else { stop(); return false }
        IONotificationPortSetDispatchQueue(port, .main)
        // powerd updates this store before publishing each power-capability transition,
        // including a promotion from DarkWake to FullWake without another hardware wake.
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "Tetherbug power" as CFString, { _, _, context in
            guard let context else { return }
            Unmanaged<SystemPowerMonitor>.fromOpaque(context).takeUnretainedValue().onEvent(.capabilitiesChanged)
        }, &context),
        SCDynamicStoreSetNotificationKeys(store, ["State:/IOKit/SystemPowerCapabilities"] as CFArray, nil),
        SCDynamicStoreSetDispatchQueue(store, .main) else { stop(); return false }
        capabilitiesStore = store
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onEvent(.workspaceWake) }
        return true
    }

    func stop() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let capabilitiesStore { SCDynamicStoreSetDispatchQueue(capabilitiesStore, nil) }
        capabilitiesStore = nil
        if notifier != 0 { IODeregisterForSystemPower(&notifier); notifier = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        if root != 0 { IOServiceClose(root); root = 0 }
    }

    deinit { stop() }
}
