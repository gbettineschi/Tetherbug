import Foundation
import Security

/// Exact-item lookup using public Security APIs. Apple's EAPOL item naming is documented by
/// apple-oss-distributions/eap8021x/EAP8021X.fproj/EAPOLClientItemID.c.
enum WifiCredentialStore {
    struct Credentials { var username: String?; var password: String }
    typealias Lookup = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    static func query(service: String, interactive: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrDescription as String: "802.1X Password",
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        ]
    }

    static func read(ssid: String, interactive: Bool = false,
                     lookup: Lookup = SecItemCopyMatching) throws -> Credentials {
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else { throw CoreWLANAssociation.Failure.notSaved }
        let services = [
            "com.apple.network.eap.user.item.wlan.ssid." + ssid,
            "com.apple.network.eap.system.item.wlan.ssid." + ssid
        ]
        for service in services {
            var result: CFTypeRef?
            let status = lookup(query(service: service, interactive: interactive) as CFDictionary, &result)
            guard try CoreWLANAssociation.credentialFound(status) else { continue }
            guard let attributes = result as? [String: Any],
                  let bytes = attributes[kSecValueData as String] as? Data,
                  let password = String(data: bytes, encoding: .utf8), !password.isEmpty else {
                throw CoreWLANAssociation.Failure.credentialsUnavailable
            }
            let account = attributes[kSecAttrAccount as String]
            let username = (account as? String) ?? (account as? Data).flatMap { String(data: $0, encoding: .utf8) }
            if username?.isEmpty != false { throw CoreWLANAssociation.Failure.credentialsUnavailable }
            return Credentials(username: username, password: password)
        }
        throw CoreWLANAssociation.Failure.credentialsUnavailable
    }
}
