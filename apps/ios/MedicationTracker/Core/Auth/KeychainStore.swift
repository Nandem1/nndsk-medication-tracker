import Foundation
import Security

protocol SecretStore: Sendable {
    func read() -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

struct KeychainStore: SecretStore {
    let service: String

    init(service: String = "dev.nndsk.MedicationTracker.session") { self.service = service }

    private var deletionMarker: String { service + ".deleting" }
    private let account = "firebase"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> Data? {
        guard !UserDefaults.standard.bool(forKey: deletionMarker) else { return nil }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data) throws {
        try delete()
        var item = query
        item[kSecValueData as String] = data
        // Disponible tras el primer desbloqueo y excluido de copias y migraciones de dispositivo.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.storage }
    }

    func delete() throws {
        UserDefaults.standard.set(true, forKey: deletionMarker)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.storage }
        UserDefaults.standard.removeObject(forKey: deletionMarker)
    }
}
