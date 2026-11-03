import Foundation
import Security

protocol SecretStore: Sendable {
    func read() -> Data?
    func write(_ data: Data) throws
    func delete()
}

struct KeychainStore: SecretStore {
    private let service = "dev.nndsk.MedicationTracker.session"
    private let account = "firebase"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data) throws {
        delete()
        var item = query
        item[kSecValueData as String] = data
        // Disponible tras el primer desbloqueo y excluido de copias y migraciones de dispositivo.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.storage }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
