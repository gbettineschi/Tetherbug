import CoreBluetooth
import Foundation

/// The phone's GATT service (see README "BLE protocol").
enum Gatt {
    static let service = CBUUID(string: "1581bac4-33fe-43a8-b97f-5dd7a01f48c9")
    static let status = CBUUID(string: "90766fca-8a24-43ae-8501-3dcef06a8479")
    static let command = CBUUID(string: "e036426f-6317-487d-8777-e6f6d91f8a4d")
    static let credentials = CBUUID(string: "355534b0-7222-480b-aa18-02a6c30feea2")
    static let enable: UInt8 = 0x01
    static let disable: UInt8 = 0x02
}

/// What the phone reports in its status characteristic.
struct PhoneStatus: Codable, Equatable {
    enum Hotspot: String, Codable { case off, starting, on, failed }

    var hotspot: Hotspot
    var battery: Int
    var signal: Int
    var ssid: String
    /// The phone can switch its hotspot (Shizuku is ready). Version 1 phones don't say; assume yes.
    var controllable: Bool
    /// The running hotspot's frequency in MHz; 0 when unknown (or a phone older than version 3).
    var frequency: Int

    /// v1: `version, hotspot, battery, signal, ssid...`; v2 adds `flags` (bit 0: controllable) before
    /// the ssid; v3 adds `frequency` (u16 little-endian) after the flags.
    init?(_ data: Data) {
        let b = [UInt8](data)
        guard let header = [1: 4, 2: 5, 3: 7][Int(b.first ?? 0)], b.count >= header else { return nil }
        hotspot = [.off, .starting, .on, .failed][Int(min(b[1], 3))]
        battery = Int(b[2])
        signal = Int(b[3])
        controllable = b[0] == 1 || b[4] & 1 != 0
        frequency = b[0] >= 3 ? Int(b[5]) | Int(b[6]) << 8 : 0
        ssid = String(decoding: b[header...], as: UTF8.self)
    }
}

/// Everything the agent knows, sent to the app and CLI over the local socket.
struct AgentState: Codable, Equatable {
    var bluetooth = "unknown"
    var phone: String?
    var connected = false
    var status: PhoneStatus?
    var wifiOffline = false
    var lastRequest: String?
    /// Optional so clients can still decode snapshots from older agents.
    var automatic: Bool?
    var automaticPausedUntil: Date?
    var automaticSuspended: Bool { automaticPausedUntil != nil }
    var requestPending: Bool?
    var requestError: String?
    /// An explicit menu Quit also tells an open settings window not to restart the agent.
    var stopping: Bool?
    /// The launchd job running the agent when it isn't the app's own login item (e.g. nix-darwin's
    /// `org.nixos.tetherbug`); nil for the login item, the window's own agent or a terminal.
    var managedBy: String? = {
        guard let job = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
              job != "0", job != "ie.xav.tetherbug.agent", !job.hasPrefix("application.") else { return nil }
        return job
    }()
    /// Only filled in the reply to an explicit `password` request, never in the `watch` stream.
    var password: String?
}

/// Settings shared by the app, agent and CLI. An explicit domain keeps it the same however the
/// binary is launched (inside the bundle or through a symlink).
enum Settings {
    static let defaults = UserDefaults(suiteName: "ie.xav.tetherbug.settings") ?? .standard

    static var preferredPhone: UUID? {
        get { defaults.string(forKey: "preferredPhone").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "preferredPhone") }
    }

    /// Ask for the hotspot when the Mac's Wi-Fi has no connection.
    static var onNoWifi: Bool {
        get { defaults.object(forKey: "onNoWifi") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "onNoWifi") }
    }

    /// How long Wi-Fi stays disconnected before asking for the hotspot, giving macOS's own
    /// auto-join (which bursts on wake) a head start.
    static var disconnectWait: Int {
        get { defaults.object(forKey: "disconnectWait") as? Int ?? 5 }
        set { defaults.set(newValue, forKey: "disconnectWait") }
    }

    /// Ask for the hotspot whenever the Wi-Fi menu opens. Off by default: every glance at the
    /// menu would wake the phone's hotspot.
    static var onWifiMenuOpen: Bool {
        get { defaults.object(forKey: "onWifiMenuOpen") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "onWifiMenuOpen") }
    }

    /// Post a notification for everything the agent does, for debugging.
    static var debugNotifications: Bool {
        get { defaults.bool(forKey: "debugNotifications") }
        set { defaults.set(newValue, forKey: "debugNotifications") }
    }
}

/// The agent's local socket, used by the app and the CLI.
enum Socket {
    static var path: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tetherbug")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent.sock").path
    }
}
