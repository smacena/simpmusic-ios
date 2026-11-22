import SwiftUI

/// SimpMusic's shell: content behind a floating mini player and a floating capsule tab bar
/// (Início / Biblioteca) with the round search button beside it.
struct RootView: View {
    enum Tab { case home, library, search }
    @EnvironmentObject private var player: PlayerEngine
    @State private var tab: Tab = .home
    @State private var showPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()
            Group {
                switch tab {
                case .home: NavigationStack { HomeView() }
                case .library: NavigationStack { LibraryView() }
                case .search: NavigationStack { SearchView() }
                }
            }
            VStack(spacing: 10) {
                if player.current != nil {
                    MiniPlayer { showPlayer = true }
                }
                TabBar(tab: $tab)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        .tint(Theme.seed)
        .routerSheets(enabled: !showPlayer)
        .fullScreenCover(isPresented: $showPlayer) { PlayerView().routerSheets() }
        #if DEBUG
        // Test hook for headless simulator runs: `simctl launch … -debugScreen applog`.
        .sheet(isPresented: .constant(UserDefaults.standard.string(forKey: "debugScreen")?.hasPrefix("applog") == true)) {
            NavigationStack { AppLogView() }
        }
        .sheet(isPresented: .constant(UserDefaults.standard.string(forKey: "debugScreen")?.hasPrefix("artist:") == true)) {
            let id = String(UserDefaults.standard.string(forKey: "debugScreen")!.dropFirst(7))
            NavigationStack {
                if id.hasPrefix("MPAD") { MoreAlbumsView(browseId: id, params: "ggMIegYIARoCAQI%3D") } else { ArtistView(browseId: id, fallbackName: "") }
            }.environmentObject(PlayerEngine.shared)
        }
        .sheet(isPresented: .constant(UserDefaults.standard.string(forKey: "debugScreen")?.hasPrefix("browse:") == true)) {
            // `browse:<browseId>[|params]` or `mood:<params>` style hook for headless tests.
            let raw = String(UserDefaults.standard.string(forKey: "debugScreen")!.dropFirst(7)).split(separator: "|").map(String.init)
            NavigationStack { BrowseView(browseId: raw[0], params: raw.count > 1 ? raw[1] : nil, title: nil) }.environmentObject(PlayerEngine.shared)
        }
        .sheet(isPresented: .constant(UserDefaults.standard.string(forKey: "debugScreen")?.hasPrefix("mood:") == true)) {
            NavigationStack { MoodView(params: String(UserDefaults.standard.string(forKey: "debugScreen")!.dropFirst(5)), fallbackTitle: "") }.environmentObject(PlayerEngine.shared)
        }
        #endif
        .alert("Erro", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(player.errorMessage ?? "") }
    }
}

private struct TabBar: View {
    @Binding var tab: RootView.Tab

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                item(.home, "house.fill", "Início")
                item(.library, "music.note.list", "Biblioteca")
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.06)))
            Button { tab = .search } label: {
                Image(icon: "magnifyingglass").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tab == .search ? Theme.seed : .white)
                    .frame(width: 60, height: 60)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.06)))
            }
        }
    }

    private func item(_ value: RootView.Tab, _ icon: String, _ title: String) -> some View {
        Button { tab = value } label: {
            VStack(spacing: 2) {
                Image(icon: icon).font(.system(size: 20, weight: .semibold))
                Text(title).font(Theme.poppins(12, .medium))
            }
            .foregroundStyle(tab == value ? Theme.seed : Color.white.opacity(0.85))
            .frame(width: 100, height: 48)
            .background(tab == value ? Color.white.opacity(0.08) : .clear, in: Capsule())
        }
    }
}
