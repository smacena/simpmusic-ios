import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var showPlayer = false

    var body: some View {
        TabView {
            NavigationStack { SearchView() }
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Ajustes", systemImage: "slider.horizontal.3") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                MiniPlayer { showPlayer = true }
                    .padding(.bottom, 52)
            }
        }
        .sheet(isPresented: $showPlayer) { PlayerView() }
        .alert("Erro", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(player.errorMessage ?? "") }
    }
}
