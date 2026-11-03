import CryptoKit
import Foundation
import UIKit
import UserNotifications

struct DeviceRegistration: Encodable, Sendable {
    let deviceID: String
    let platform: String
    let token: String
    let permission: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", platform, token, permission
    }
}

enum PushInstallation {
    static func deviceID(installation: String, owner: String) -> String {
        let bytes = Array(SHA256.hash(data: Data((installation + "/" + owner).utf8)).prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [String(hex.prefix(8)), String(hex.dropFirst(8).prefix(4)), "4" + String(hex.dropFirst(13).prefix(3)), "a" + String(hex.dropFirst(17).prefix(3)), String(hex.suffix(12))].joined(separator: "-")
    }
}

@MainActor
final class RemotePush {
    static let shared = RemotePush()
    var onChange: (() -> Void)?
    private(set) var token: String?
    private(set) var registrationFailed = false
    private var nextAttempt = Date.distantPast

    func requestRegistration() {
        guard Date.now >= nextAttempt else { return }
        nextAttempt = Date.now.addingTimeInterval(60)
        UIApplication.shared.registerForRemoteNotifications()
    }

    static var enabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "RemotePushEnabled") as? String == "YES"
    }

    func received(token deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        registrationFailed = false
        onChange?()
    }

    func failedRegistration() {
        registrationFailed = true
        onChange?()
    }

    func stop() {
        UIApplication.shared.unregisterForRemoteNotifications()
        token = nil
    }
}

@MainActor
final class PushRegistration {
    private let api: APIClient
    private let installation: String
    private var current: Task<Void, Never>?
    private var loggingOut = false
    private var needsRefresh = false
    private(set) var diagnostic = "Avisos remotos sin configurar."

    init(api: APIClient, defaults: UserDefaults = .standard) {
        self.api = api
        let saved = defaults.string(forKey: "push-installation") ?? UUID().uuidString.lowercased()
        defaults.set(saved, forKey: "push-installation")
        installation = saved
    }

    func reconcile(owner: String) async {
        guard RemotePush.enabled, !loggingOut else { return }
        if let current {
            needsRefresh = true
            await current.value
            return
        }
        let task = Task {
            repeat {
                needsRefresh = false
                await update(owner: owner)
            } while needsRefresh && !loggingOut
        }
        current = task
        await task.value
        current = nil
    }

    private func update(owner: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let permission: String
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permission = "granted"
        case .denied: permission = "denied"
        default: permission = "unknown"
        }
        if permission == "granted", RemotePush.shared.token == nil {
            RemotePush.shared.requestRegistration()
            diagnostic = RemotePush.shared.registrationFailed ? "No se pudo registrar este teléfono para avisos remotos." : "Esperando el registro de avisos remotos."
            return
        }
        do {
            try await api.registerDevice(DeviceRegistration(deviceID: PushInstallation.deviceID(installation: installation, owner: owner), platform: "apns", token: RemotePush.shared.token ?? "", permission: permission))
            diagnostic = permission == "granted" ? "Avisos remotos registrados. La entrega depende del sistema y la conexión." : "Avisos remotos sin permiso."
        } catch {
            diagnostic = "Registro de avisos remotos pendiente. Vuelve a sincronizar."
        }
    }

    func signedIn() { loggingOut = false }

    func signOut(owner: String) async -> Bool {
        loggingOut = true
        await current?.value
        RemotePush.shared.stop()
        guard RemotePush.enabled else { return true }
        do {
            try await api.unregisterDevice(id: PushInstallation.deviceID(installation: installation, owner: owner))
            return true
        } catch {
            return false
        }
    }
}

@MainActor
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemotePush.shared.received(token: deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        RemotePush.shared.failedRegistration()
    }
}
