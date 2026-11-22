import SwiftUI

@main
struct SimpMusicApp: App {
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var effects = AudioEffects.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(effects)
                .preferredColorScheme(.dark)
                .font(Theme.bodyMedium)
                .onChange(of: phase) { _, value in if value == .active { Backup.autoBackupIfDue() } }
        }
    }
}
