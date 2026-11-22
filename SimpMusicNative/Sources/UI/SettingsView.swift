import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var effects: AudioEffects
    @EnvironmentObject private var player: PlayerEngine
    @State private var normalize = PlayerEngine.shared.normalizeVolume
    @State private var crossfade = PlayerEngine.shared.crossfadeEnabled
    @State private var skipSilence = PlayerEngine.shared.skipSilence
    @State private var sponsorBlock = SponsorBlock.enabled
    @AppStorage("download.liked") private var downloadLiked = false
    @AppStorage("eightd.enabled") private var eightD = false
    @AppStorage("eightd.direction") private var eightDDirection = 1.0
    @AppStorage("eightd.period") private var eightDPeriod = 10.0
    @State private var crossfadeSeconds = PlayerEngine.shared.crossfadeSeconds
    @ObservedObject private var account = Account.shared
    @State private var showLogin = false
    @State private var showSync = false
    @State private var backupURL: URL?
    @State private var importing = false
    @State private var message: String?
    @State private var romanize = Romanizer.enabled
    @State private var translate = LyricsStore.translateEnabled
    @State private var lyricsSource = LyricsSource.preferred
    @AppStorage("lyrics.style") private var lyricsStyle = "classic"
    @AppStorage("quality.audio") private var audioQuality = "high"
    @AppStorage("player.style") private var playerStyle = "classic"
    @AppStorage("theme.accent") private var accent = "seed"
    @AppStorage("quality.video") private var videoQuality = 720
    @AppStorage("lyrics.offsetMs") private var lyricsOffset = 0

    var body: some View {
        Form {
            Section("Conta do YouTube") {
                if account.isSignedIn {
                    Label("Conectado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Sair da conta", role: .destructive) { account.signOut() }
                }
                Button("Sincronizar login (Android / computador)") { showSync = true }
                if !account.isSignedIn {
                    Button("Entrar com Google") { showLogin = true }
                    Text("Opcional. Personaliza o início e mostra suas músicas curtidas. A senha é digitada só na página do Google.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Backup") {
                Button("Criar backup") {
                    do { backupURL = try Backup.export() } catch { message = "Falha ao criar o backup." }
                }
                if let backupURL {
                    ShareLink(item: backupURL) { Label("Compartilhar backup", systemImage: "square.and.arrow.up") }
                }
                Button("Restaurar backup") { importing = true }
            }
            Section("Aparência") {
                Picker("Estilo do player", selection: $playerStyle) {
                    Text("Classic").tag("classic")
                    Text("M3 Expressive").tag("expressive")
                    Text("Apple Music").tag("apple")
                }
                Picker("Cor de destaque", selection: $accent) {
                    ForEach(Theme.accents, id: \.key) { Text($0.name).tag($0.key) }
                }
                Text("A cor de destaque vale depois de reabrir o app.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Qualidade") {
                Picker("Áudio", selection: $audioQuality) {
                    Text("Alta (AAC 128 kbps)").tag("high")
                    Text("Economia (AAC 48 kbps)").tag("low")
                }
                Picker("Vídeo", selection: $videoQuality) {
                    ForEach([360, 480, 720, 1080], id: \.self) { Text("\($0)p").tag($0) }
                }
            }
            Section("Áudio") {
                Toggle("Normalizar volume", isOn: $normalize)
                    .onChange(of: normalize) { _, value in player.normalizeVolume = value }
                Toggle("Pular trechos patrocinados (SponsorBlock)", isOn: $sponsorBlock)
                    .onChange(of: sponsorBlock) { _, value in SponsorBlock.enabled = value }
                Toggle("Baixar músicas curtidas automaticamente", isOn: $downloadLiked)
                Toggle("Pular silêncio", isOn: $skipSilence)
                    .onChange(of: skipSilence) { _, value in player.skipSilence = value }
                Toggle("Crossfade", isOn: $crossfade)
                    .onChange(of: crossfade) { _, value in player.crossfadeEnabled = value }
                if crossfade {
                    Stepper("Duração: \(Int(crossfadeSeconds)) s", value: $crossfadeSeconds, in: 1 ... 12)
                        .onChange(of: crossfadeSeconds) { _, value in player.crossfadeSeconds = value }
                }
            }
            Section("Letras") {
                Toggle("Romanizar japonês, chinês e coreano", isOn: $romanize)
                    .onChange(of: romanize) { _, value in Romanizer.enabled = value }
                Toggle("Mostrar tradução da comunidade", isOn: $translate)
                    .onChange(of: translate) { _, value in LyricsStore.translateEnabled = value }
                Picker("Fonte preferida", selection: $lyricsSource) {
                    ForEach(LyricsSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: lyricsSource) { _, value in
                    LyricsSource.preferred = value
                    LyricsStore.shared.reload(for: player.current, duration: player.duration)
                }
                Picker("Estilo", selection: $lyricsStyle) {
                    Text("Classic").tag("classic")
                    Text("Apple Music").tag("apple")
                }
                Stepper("Atraso: \(lyricsOffset) ms", value: $lyricsOffset, in: -3000 ... 3000, step: 100)
                Text("Use o atraso se a letra adiantar no fone Bluetooth.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Equalizador") {
                Toggle("Ativado", isOn: $effects.eqEnabled)
                NavigationLink {
                    AutoEqView()
                } label: {
                    LabeledContent("Perfil do fone (AutoEq)", value: UserDefaults.standard.string(forKey: "eq.autoeqName") ?? "Nenhum")
                }
                if effects.eqEnabled {
                    Picker("Predefinição", selection: Binding(
                        get: { AudioEffects.presets.firstIndex { $0.gains == effects.gains } ?? -1 },
                        set: { if AudioEffects.presets.indices.contains($0) { effects.gains = AudioEffects.presets[$0].gains } }
                    )) {
                        Text("Personalizado").tag(-1)
                        ForEach(AudioEffects.presets.indices, id: \.self) { Text(AudioEffects.presets[$0].name).tag($0) }
                    }
                    ForEach(0 ..< 10, id: \.self) { band in
                        HStack {
                            Text(AudioEffects.bandLabels[band]).font(.caption.monospacedDigit()).frame(width: 34, alignment: .leading)
                            Slider(value: Binding(get: { effects.gains[band] }, set: { effects.gains[band] = $0.rounded() }), in: -12 ... 12)
                            Text("\(Int(effects.gains[band]))").font(.caption.monospacedDigit()).frame(width: 28)
                        }
                    }
                }
            }
            Section("Áudio 8D") {
                Toggle("Ativado", isOn: $eightD).onChange(of: eightD) { _, _ in PlayerEngine.applyEightD() }
                if eightD {
                    Picker("Direção", selection: $eightDDirection) {
                        Text("Esquerda → direita").tag(1.0)
                        Text("Direita → esquerda").tag(-1.0)
                    }
                    .onChange(of: eightDDirection) { _, _ in PlayerEngine.applyEightD() }
                    Stepper("Uma volta a cada \(eightDPeriod, specifier: "%.1f") s", value: $eightDPeriod, in: 3 ... 30, step: 0.5)
                        .onChange(of: eightDPeriod) { _, _ in PlayerEngine.applyEightD() }
                    Text("Melhor com fones de ouvido.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Reverb") {
                Toggle("Ativado", isOn: $effects.reverbEnabled)
                if effects.reverbEnabled {
                    Picker("Ambiente", selection: $effects.reverbPreset) {
                        ForEach(ReverbPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledSlider(title: "Mistura", value: $effects.reverbMix, range: 0 ... 1, unit: "")
                }
            }
            Section("Eco (Delay)") {
                Toggle("Ativado", isOn: $effects.delayEnabled)
                if effects.delayEnabled {
                    LabeledSlider(title: "Tempo", value: $effects.delayTimeMs, range: 50 ... 1000, unit: "ms")
                    LabeledSlider(title: "Repetição", value: $effects.delayFeedback, range: 0 ... 0.9, unit: "")
                    LabeledSlider(title: "Mistura", value: $effects.delayMix, range: 0 ... 1, unit: "")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        // SimpMusic's settings look: near-black page, translucent rounded groups, Poppins
        // throughout, group titles in sentence case.
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .font(Theme.poppins(15))
        .textCase(nil)
        .tint(Theme.seed)
        .navigationTitle("Ajustes")
        .sheet(isPresented: $showLogin) { LoginView() }
        .sheet(isPresented: $showSync) { LoginSyncView().preferredColorScheme(.dark) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case let .success(url) = result else { return }
            do {
                try Backup.restore(from: url)
                message = "Backup restaurado. Reabra o app para aplicar os ajustes de áudio."
            } catch { message = "Arquivo de backup inválido." }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(title): \(unit == "ms" ? "\(Int(value)) ms" : String(format: "%.2f", value))").font(.caption)
            Slider(value: $value, in: range)
        }
    }
}
