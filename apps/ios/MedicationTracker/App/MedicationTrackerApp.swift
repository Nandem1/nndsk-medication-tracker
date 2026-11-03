import SwiftUI
import UserNotifications

@main
struct MedicationTrackerApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Debe asignarse antes de terminar el arranque para recibir el toque que abrió la app.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.locale, Locale(identifier: "es_CL"))
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.becameActive() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    Task { await model.becameActive() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Cargando")
            case .misconfigured:
                ContentUnavailableView("La app no está configurada", systemImage: "wrench.and.screwdriver", description: Text("Falta la configuración del servidor o de inicio de sesión."))
            case .storageUnavailable:
                ContentUnavailableView("No se pudieron abrir los datos", systemImage: "externaldrive.badge.exclamationmark", description: Text("Reinicia el teléfono. Si continúa, revisa el espacio disponible."))
            case .signedOut:
                LoginView(notice: nil)
            case .expired:
                LoginView(notice: "La sesión venció. Tus registros pendientes siguen guardados en este dispositivo.")
            case .signedIn:
                MainTabs()
            }
        }
        .alert("No se pudo completar", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            TodayView()
                .tabItem { Label("Hoy", systemImage: "sun.max") }
                .tag(AppTab.today)
            HistoryView()
                .tabItem { Label("Historial", systemImage: "calendar") }
                .tag(AppTab.history)
            SettingsView()
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
