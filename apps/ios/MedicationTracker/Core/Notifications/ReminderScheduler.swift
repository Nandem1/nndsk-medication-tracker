import Foundation
import UserNotifications

enum ReminderPermission: Sendable, Equatable {
    case notDetermined
    case enabled
    case denied
    /// Autorizada, pero el sistema puede agrupar, silenciar o retrasar los avisos.
    case limited
}

struct ReminderDiagnostic: Sendable, Equatable {
    var permission: ReminderPermission = .notDetermined
    var scheduledCount = 0
    var scheduledThrough: Date?
}

/// La hora se programa como intervalo hacia el instante UTC de la dosis. Así un viaje o un cambio
/// de horario no la desplaza: la pauta del backend sigue su zona IANA.
actor ReminderScheduler {
    private let center = UNUserNotificationCenter.current()

    func requestPermission() async -> ReminderPermission {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await permission()
    }

    func permission() async -> ReminderPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral:
            let limited = settings.authorizationStatus != .authorized || settings.alertSetting != .enabled || settings.scheduledDeliverySetting == .enabled
            return limited ? .limited : .enabled
        @unknown default: return .limited
        }
    }

    func reconcile(plan: [PlannedReminder], now: Date) async -> ReminderDiagnostic {
        let permission = await permission()
        let requests = await center.pendingNotificationRequests()
        let pending = Set(requests.map(\.identifier))
        guard permission != .denied, permission != .notDetermined else {
            center.removePendingNotificationRequests(withIdentifiers: Array(pending))
            return ReminderDiagnostic(permission: permission)
        }
        let changes = ReminderPlanner.reconcile(pending: pending, plan: plan)
        center.removePendingNotificationRequests(withIdentifiers: changes.remove)
        var failed = Set<String>()
        for reminder in changes.add {
            let interval = reminder.fireAt.timeIntervalSince(now)
            guard interval >= 1 else { continue }
            let content = UNMutableNotificationContent()
            // Sin nombre de medicamento: el texto se ve en la pantalla bloqueada.
            content.title = "Recordatorio de medicamento"
            content.body = "Abre la app para revisar tu toma."
            content.sound = .default
            content.userInfo = ["dose_id": reminder.doseID]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
            } catch {
                failed.insert(reminder.identifier)
            }
        }
        let scheduled = plan.filter { !failed.contains($0.identifier) }
        return ReminderDiagnostic(permission: permission, scheduledCount: scheduled.count, scheduledThrough: scheduled.last?.fireAt)
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}

/// Abre la dosis tocada. Nunca registra una declaración por sí sola.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (String) -> Void)?
    private var waiting: String?

    func connect(_ newHandler: @escaping @MainActor @Sendable (String) -> Void) {
        let held: String? = lock.withLock {
            handler = newHandler
            defer { waiting = nil }
            return waiting
        }
        if let held { Task { @MainActor in newHandler(held) } }
    }

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Variante con completion: la versión `async` lo reanuda fuera del hilo principal y UIKit aborta la app.
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let dose = response.notification.request.content.userInfo["dose_id"] as? String
        let target: (@MainActor @Sendable (String) -> Void)? = lock.withLock {
            if handler == nil, let dose { waiting = dose }
            return handler
        }
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let target, let dose { target(dose) }
                done()
            }
        }
    }
}
