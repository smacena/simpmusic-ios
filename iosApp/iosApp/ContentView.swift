import SwiftUI
import UIKit
import ComposeApp

/// Hosts the shared Compose Multiplatform UI (composeApp/src/iosMain/.../MainViewController.kt).
struct ComposeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        // Compose draws its own system-bar backgrounds and handles the keyboard itself.
        ComposeView()
            .ignoresSafeArea()
    }
}
