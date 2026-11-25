import AppKit
import CoreLocation
import CoreWLAN
import Observation
import SwiftUI

/// Settings owns authorization requests. The worker only reads authorization and never asks for GPS.
@Observable
final class WifiPreferencesModel: NSObject, CLLocationManagerDelegate {
    private let defaults: UserDefaults
    private let location = CLLocationManager()
    var networks: [String] { didSet { defaults.set(networks, forKey: "preferredWifiNetworks") } }
    private(set) var authorization = CLAuthorizationStatus.notDetermined
    private(set) var currentNetwork: String?
    private(set) var savedNetworks: [String] = []
    var error: String?

    var authorized: Bool { WifiAccess.authorized(authorization) }
    var permissionDenied: Bool { authorization == .denied || authorization == .restricted }

    init(defaults: UserDefaults = Settings.defaults) {
        self.defaults = defaults
        networks = defaults.stringArray(forKey: "preferredWifiNetworks") ?? []
        super.init()
        location.delegate = self
        refresh()
    }

    func refresh() {
        authorization = location.authorizationStatus
        guard authorized, let interface = CWWiFiClient.shared().interface() else {
            currentNetwork = nil
            savedNetworks = []
            return
        }
        currentNetwork = interface.ssid()
        savedNetworks = WifiAccess.savedNetworks(interface).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func requestPermission() { location.requestWhenInUseAuthorization() }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { refresh() }

    @discardableResult
    func add(_ name: String, hotspot: String?) -> Bool {
        error = WifiNetworkNames.error(for: name, existing: networks, hotspot: hotspot)
        guard error == nil else { return false }
        networks.append(name)
        return true
    }

    func remove(_ name: String) { networks.removeAll { $0 == name }; error = nil }
}

struct PreferredWifiSection: View {
    var hotspotSSID: String?
    var message: String?
    var prefersHotspot = false
    @State private var model = WifiPreferencesModel()
    @State private var name = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section("Preferred Wi-Fi") {
            Group {
                Text(prefersHotspot ? "Hotspot preference is active. Nearby Wi-Fi will not turn the hotspot off until it ends." : "Automatic Mode turns the hotspot off when a listed Wi-Fi is nearby. macOS handles connecting to it.")
                    .font(.callout).foregroundStyle(.secondary)
                if !model.authorized {
                    Text("macOS requires Location access to identify nearby Wi-Fi. Tetherbug does not track your location.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.permissionDenied {
                        Link("Allow Location access in System Settings…", destination:
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                    } else {
                        Button("Allow Wi-Fi Network Access…") { model.requestPermission() }
                    }
                }
                ForEach(model.networks, id: \.self) { network in
                    HStack {
                        Label(network, systemImage: "wifi").textSelection(.enabled)
                        Spacer()
                        Button { model.remove(network) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(network)")
                        .help("Remove network")
                    }
                }
                HStack {
                    TextField("Network name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTypedNetwork() }
                    Button("Add") { addTypedNetwork() }.disabled(name.isEmpty)
                }
                HStack {
                    Menu("Add Saved Network…") {
                        ForEach(model.savedNetworks.filter { !model.networks.contains($0) && $0 != hotspotSSID }, id: \.self) { network in
                            Button(network) { model.add(network, hotspot: hotspotSSID) }
                        }
                    }
                    .disabled(!model.authorized || model.savedNetworks.isEmpty)
                    Button("Use Current Network") {
                        model.refresh()
                        if let current = model.currentNetwork { model.add(current, hotspot: hotspotSSID) }
                    }
                    .disabled(!model.authorized || model.currentNetwork == nil || model.currentNetwork == hotspotSSID ||
                        model.networks.contains(model.currentNetwork ?? ""))
                }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
                if let message { Text(message).foregroundStyle(.secondary).font(.callout) }
                Text("Use networks saved in macOS with Auto-join enabled. Presence is checked at most once a minute and does not verify internet access. Turning off Automatic Mode also disables this rule.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: scenePhase) { if scenePhase == .active { model.refresh() } }
    }

    private func addTypedNetwork() {
        if model.add(name, hotspot: hotspotSSID) { name = "" }
    }
}
