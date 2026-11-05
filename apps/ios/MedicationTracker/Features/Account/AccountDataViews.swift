import SwiftUI
import UIKit

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// El archivo vive en una carpeta temporal privada y se borra al cerrar la hoja de compartir.
enum AccountExportStore {
    static var directory: URL { FileManager.default.temporaryDirectory.appending(path: "exports", directoryHint: .isDirectory) }
    static func write(_ data: Data) throws -> URL {
        clear()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "mis-datos.json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
    static func clear() { try? FileManager.default.removeItem(at: directory) }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct AccountDataSection: View {
    @Environment(AppModel.self) private var model
    @State private var file: ExportFile?
    @State private var working = false
    @State private var error: String?
    var body: some View {
        Section {
            Button(working ? "Preparando…" : "Descargar mis datos") { Task { await export() } }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("export-account")
                .sheet(item: $file, onDismiss: AccountExportStore.clear) { ActivitySheet(url: $0.url) }
                .onAppear { if file == nil { AccountExportStore.clear() } }
            NavigationLink("Eliminar mi cuenta") { DeleteAccountView() }.accessibilityIdentifier("open-delete-account")
            if let error { Label(error, systemImage: "info.circle").foregroundStyle(Semantic.muted).accessibilityIdentifier("export-error") }
        } header: { Text("Tus datos") } footer: { Text("El archivo contiene tus datos de salud. Compártelo sólo con quien corresponda.") }
    }
    private func export() async {
        working = true
        defer { working = false }
        do { file = ExportFile(url: try AccountExportStore.write(await model.exportAccount())); error = nil }
        catch { self.error = (error as? APIError)?.message ?? "No se pudieron preparar tus datos. Intenta nuevamente." }
    }
}

struct DeleteAccountView: View {
    @Environment(AppModel.self) private var model
    @State private var typed = ""
    @State private var working = false
    @State private var error: String?
    @State private var operation = UUID().uuidString.lowercased()
    var body: some View {
        Form {
            Section {
                Text("Se borrarán tus tomas, tratamientos, inventario y accesos, y tus cuidadores dejarán de verte. Si compartes inventario, el saldo se queda con quienes permanecen. Lo que registraste en la historia de otra persona se conserva sin tu nombre. Las copias de seguridad pueden conservar datos hasta que venzan. No se puede deshacer.")
            }
            Section("Escribe BORRAR para confirmar") {
                TextField("BORRAR", text: $typed).textInputAutocapitalization(.characters).autocorrectionDisabled().accessibilityIdentifier("delete-confirm")
            }
            if let error { Section { Label(error, systemImage: "info.circle").foregroundStyle(Semantic.muted).accessibilityIdentifier("delete-error") } }
            Section {
                Button("Eliminar definitivamente", role: .destructive) { Task { await delete() } }
                    .frame(minHeight: 44).disabled(working || typed != "BORRAR").accessibilityIdentifier("delete-account")
            }
        }.navigationTitle("Eliminar mi cuenta").navigationBarTitleDisplayMode(.inline)
    }
    private func delete() async {
        working = true
        defer { working = false }
        do {
            // Con éxito, cerrar sesión ya limpió este teléfono y la pantalla desaparece.
            if try await !model.deleteAccount(operation: operation) { error = "Tus datos se borraron, pero no pudimos cerrar tu acceso. Intenta nuevamente." }
        } catch {
            self.error = (error as? APIError)?.message ?? "No se pudo eliminar la cuenta. Intenta nuevamente."
        }
    }
}
