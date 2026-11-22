import SwiftUI

/// Settings → Sobre (SettingScreen.kt's About group and CreditScreen): version, the original
/// project and its author, donation, and the open-source pieces this app is built on.
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(icon: "music.note").font(.system(size: 44)).foregroundStyle(Theme.seed)
                    Text("SimpMusic").font(Theme.poppins(24, .bold))
                    Text("Versão para iPhone \(version)").font(Theme.bodySmall).foregroundStyle(Theme.body)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section("Projeto original") {
                Link("SimpMusic no GitHub", destination: URL(string: "https://github.com/maxrave-dev/SimpMusic")!)
                Link("Site do SimpMusic", destination: URL(string: "https://simpmusic.org")!)
                LabeledContent("Autor", value: "maxrave-dev")
                Link("Apoiar o autor (doação)", destination: URL(string: "https://buymeacoffee.com/maxrave")!)
            }
            Section("Esta versão") {
                Text("Versão pessoal para iPhone: interface em SwiftUI, áudio em C, a mesma lógica e aparência do SimpMusic.")
                    .font(Theme.bodySmall)
            }
            Section("Bibliotecas e serviços de terceiros") {
                ForEach(Self.credits, id: \.0) { name, detail in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(Theme.poppins(15, .medium))
                        Text(detail).font(Theme.bodySmall).foregroundStyle(Theme.body)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .font(Theme.poppins(15))
        .navigationTitle("Sobre")
    }

    static let credits: [(String, String)] = [
        ("SimpMusic", "GPL-3.0 — design, lógica e recursos"),
        ("Material Symbols", "Apache-2.0 — ícones"),
        ("Poppins", "OFL — fonte"),
        ("LRCLIB", "Letras sincronizadas"),
        ("SimpMusic Lyrics", "Letras e traduções da comunidade"),
        ("BetterLyrics", "Letras palavra por palavra"),
        ("SponsorBlock", "Trechos para pular, CC BY-NC-SA"),
        ("AutoEq", "Perfis de fones, MIT"),
    ]
}
