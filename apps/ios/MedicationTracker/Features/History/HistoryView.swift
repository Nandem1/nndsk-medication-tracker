import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    /// Días ya pedidos hacia atrás, además de la ventana de sincronización.
    @State private var loadedDaysBack = SyncEngine.daysBack
    @State private var error: String?
    @State private var loading = false

    private static let pageDays = 30

    var body: some View {
        NavigationStack {
            let now = Date.now
            let past = model.snapshot.doses.filter { $0.scheduledInstant <= now }
            let days = Dictionary(grouping: past, by: \.localDate).sorted { $0.key > $1.key }
            List {
                SyncBanner()
                if days.isEmpty {
                    Text("Todavía no hay tomas anteriores.").accessibilityIdentifier("history-empty")
                }
                ForEach(days, id: \.key) { day, doses in
                    Section(DoseText.day(day)) {
                        ForEach(doses) { dose in
                            NavigationLink(value: dose.id) {
                                DoseSummary(dose: dose, now: now)
                            }
                            .accessibilityIdentifier("history-\(model.treatment(for: dose)?.name ?? dose.id)")
                        }
                    }
                }
                Section {
                    if let error {
                        Text(error).foregroundStyle(Semantic.danger)
                    }
                    Button(loading ? "Cargando…" : "Ver \(Self.pageDays) días anteriores") {
                        Task { await loadMore() }
                    }
                    .frame(minHeight: 44)
                    .disabled(loading)
                    .accessibilityIdentifier("history-more")
                } footer: {
                    Text(DoseText.selfReported)
                }
            }
            .navigationTitle("Historial")
            .navigationDestination(for: String.self) { DoseDetailView(doseID: $0) }
            .refreshable { await model.syncNow() }
        }
    }

    private func loadMore() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let to = calendar.date(byAdding: .day, value: -loadedDaysBack, to: today),
              let from = calendar.date(byAdding: .day, value: -(loadedDaysBack + Self.pageDays), to: today) else { return }
        loading = true
        error = await model.loadHistory(from: from, to: to)
        if error == nil { loadedDaysBack += Self.pageDays }
        loading = false
    }
}
