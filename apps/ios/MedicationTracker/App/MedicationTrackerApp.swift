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
                // Enlace de invitación: el código viaja en el fragmento y nunca sale del teléfono.
                .onOpenURL { url in
                    if url.scheme == "mistomas", url.host == "unirse", let token = url.fragment, !token.isEmpty { model.pendingJoinToken = token }
                }
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
    @State private var confirmClear = false

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .loading, .signingOut:
                ProgressView("Cargando")
            case .misconfigured:
                ContentUnavailableView("La app no está configurada", systemImage: "wrench.and.screwdriver", description: Text("Falta la configuración del servidor o de inicio de sesión."))
            case .storageUnavailable:
                VStack {
                    ContentUnavailableView("No se pudieron abrir los datos", systemImage: "externaldrive.badge.exclamationmark", description: Text("Reinicia el teléfono. Si continúa, revisa el espacio disponible."))
                    Button("Reintentar borrado local", role: .destructive) { confirmClear = true }
                        .accessibilityIdentifier("retry-local-cleanup")
                        .padding()
                }
            case .signedOut:
                LoginView(notice: nil)
            case .expired:
                LoginView(notice: "La sesión venció. Tus registros pendientes siguen guardados en este dispositivo.")
            case .signedIn:
                if model.needsOnboarding { OnboardingView() } else {
                    MainTabs()
                        .sheet(item: Binding(get: { model.pendingJoinToken.map(JoinRequest.init) }, set: { model.pendingJoinToken = $0?.token })) { request in
                            NavigationStack { FamilyView(incomingToken: request.token) }
                        }
                }
            }
        }
        .confirmationDialog("Se borrarán los datos de este dispositivo y los registros pendientes de sincronizar.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Borrar datos locales", role: .destructive) { Task { await model.signOut() } }
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
            if model.tabs.contains(.today) {
                TodayView()
                    .tabItem { Label("Hoy", systemImage: "sun.max") }
                    .tag(AppTab.today)
                HistoryView()
                    .tabItem { Label("Historial", systemImage: "calendar") }
                    .tag(AppTab.history)
            }
            if model.tabs.contains(.patients) {
                PatientsView().tabItem { Label("Pacientes", systemImage: "person.2") }.tag(AppTab.patients)
            }
            SettingsView()
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}

/// Un enlace abierto se muestra en una hoja cuando ya hay sesión y perfil.
struct JoinRequest: Identifiable {
    let token: String
    var id: String { token }
}
