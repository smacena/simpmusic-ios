import SwiftUI
import WebKit

/// Google's own sign-in page in a web view; the app never sees the password. Once the page lands
/// on music.youtube.com with a session cookie, the cookies are saved and the sheet closes.
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWebView { cookie in
                Account.shared.signIn(cookieHeader: cookie)
                dismiss()
            }
            .navigationTitle("Entrar no YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }
}

private struct LoginWebView: UIViewRepresentable {
    let onSignedIn: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = InnerTube.webUserAgent
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com")!))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: (String) -> Void
        private var done = false
        init(onSignedIn: @escaping (String) -> Void) { self.onSignedIn = onSignedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, webView.url?.host?.hasSuffix("music.youtube.com") == true else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let yt = cookies.filter { $0.domain.hasSuffix("youtube.com") }
                guard yt.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) else { return }
                let header = yt.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                DispatchQueue.main.async {
                    guard !self.done else { return }
                    self.done = true
                    self.onSignedIn(header)
                }
            }
        }
    }
}
