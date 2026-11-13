import Foundation
import Security

/// A plugin's `secret` settings, in the login Keychain. Each plugin has its own service,
/// `net.dasantos.dockstacks.plugin.<id>`, with one item per setting key. Only that plugin's
/// runtime reads it, and the values never go into the plugin's JSON storage.
enum PluginSecrets {
    static func service(_ plugin: String) -> String { "net.dasantos.dockstacks.plugin." + plugin }

    private static func query(_ plugin: String, _ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service(plugin),
         kSecAttrAccount as String: key]
    }

    static func read(plugin: String, key: String) -> String? {
        var item: CFTypeRef?
        var search = query(plugin, key)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(plugin: String, key: String) -> Bool {
        var search = query(plugin, key)
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(search as CFDictionary, nil) == errSecSuccess
    }

    /// Saves, or with nil or an empty value removes. Returns false when the Keychain refused.
    @discardableResult
    static func write(plugin: String, key: String, value: String?) -> Bool {
        let base = query(plugin, key)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Atelier plugin setting"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Removes every secret of a plugin, for when the owner removes it.
    static func removeAll(plugin: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(plugin)] as CFDictionary)
    }
}
