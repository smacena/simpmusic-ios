import SwiftUI

struct AutoEqView: View {
    @EnvironmentObject private var effects: AudioEffects
    @Environment(\.dismiss) private var dismiss
    @State private var all: [AutoEq.Entry] = []
    @State private var query = ""
    @State private var failed = false
    @State private var applying: String?

    private var filtered: [AutoEq.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? Array(all.prefix(200)) : Array(all.filter { $0.name.lowercased().contains(q) }.prefix(200))
    }

    var body: some View {
        List {
            if all.isEmpty && !failed { ProgressView().frame(maxWidth: .infinity).listRowBackground(Theme.background) }
            if failed { Text("Não foi possível carregar a lista de fones.").foregroundStyle(Theme.body).listRowBackground(Theme.background) }
            ForEach(filtered) { entry in
                Button {
                    applying = entry.id
                    Task {
                        defer { applying = nil }
                        guard let curve = try? await AutoEq.curve(entry) else { return }
                        effects.gains = curve.gains
                        effects.preamp = curve.preamp
                        effects.eqEnabled = true
                        UserDefaults.standard.set(entry.name, forKey: "eq.autoeqName")
                        dismiss()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(Theme.poppins(15, .medium)).foregroundStyle(.white)
                            Text(entry.source).font(Theme.bodySmall).foregroundStyle(Theme.body)
                        }
                        Spacer()
                        if applying == entry.id { ProgressView() }
                    }
                }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .searchable(text: $query, prompt: "Modelo do fone")
        .navigationTitle("AutoEq")
        .task {
            guard all.isEmpty else { return }
            do { all = try await AutoEq.index() } catch { failed = true }
        }
    }
}
