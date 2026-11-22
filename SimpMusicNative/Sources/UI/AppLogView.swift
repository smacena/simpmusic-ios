import SwiftUI
import UIKit

/// AppLogScreen.kt: the on-disk log read back for a person — tabs All / Errors, search, level
/// chips (Info, Warn, Error), live/paused meta line, Logcat-style toolbar (clear, pause, restart,
/// stick to bottom, share). Tapping a line copies it. Errors are newest first, with an
/// expandable stack trace.
struct AppLogView: View {
    private static let maxShown = 5_000
    private static let warn = Color(red: 1, green: 0xCF / 255, blue: 0x6B / 255)

    @State private var tab = UserDefaults.standard.string(forKey: "debugScreen") == "applog-errors" ? 1 : 0
    @State private var minLevel: Character = "I"
    @State private var query = ""
    @State private var paused = false
    @State private var clearedAt = Date.distantPast
    @State private var stick = true
    @State private var appLines: [LogLine] = []
    @State private var errorLines: [LogLine] = []
    @State private var expanded: Set<Int> = []
    @State private var toast: String?
    @State private var shareURL: URL?
    @State private var restarts = 0

    @State private var appTail = LogTail(AppLog.appLog, keep: maxShown)
    @State private var errorTail = LogTail(AppLog.errorLog, keep: .max)
    private let mono = Font.system(size: 12, design: .monospaced)

    private var shownLines: [LogLine] {
        let floor = LogLine.rank(minLevel)
        return appLines.filter { $0.date > clearedAt && LogLine.rank($0.level) >= floor && $0.matches(query) }
    }
    private var shownErrors: [LogLine] { errorLines.filter { $0.date > clearedAt && $0.matches(query) }.reversed() }
    private var errorCount: Int { errorLines.filter { $0.date > clearedAt }.count }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            searchField.padding(.horizontal, 16).padding(.top, 12)
            if tab == 0 {
                HStack(spacing: 8) {
                    chip("I", "Info"); chip("W", "Aviso"); chip("E", "Erro")
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 12)
                HStack(spacing: 6) {
                    Circle().fill(Theme.seed).frame(width: 6, height: 6)
                    Text("\(paused ? "Pausado" : "Ao vivo") · \(shownLines.count) linhas").font(Theme.bodySmall).foregroundStyle(Theme.body)
                    Spacer()
                }.padding(.leading, 16).padding(.top, 8).padding(.bottom, 4)
            }
            content.frame(maxHeight: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Log do app")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(Theme.bodySmall).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Theme.surfaceHigh)).padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { if $0 == nil { shareURL = nil } })) { item in
            ActivityView(items: [item.url])
        }
        .task(id: restarts) {
            if restarts > 0 { appTail.reset(); errorTail.reset() }
            while !Task.isCancelled {
                if !paused {
                    let a = appTail, e = errorTail
                    let (app, errs) = await Task.detached { (a.poll() ? a.lines : nil, e.poll() ? e.lines : nil) }.value
                    if let app { appLines = app }
                    if let errs { errorLines = errs }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: Pieces

    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton(0) { Text("Todos") }
            tabButton(1) {
                HStack(spacing: 6) {
                    Text("Erros")
                    if errorCount > 0 {
                        Text("\(errorCount)").font(.system(size: 11)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.red))
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5) }
    }

    private func tabButton<L: View>(_ index: Int, @ViewBuilder label: () -> L) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 8) {
                label().font(Theme.poppins(14, .medium)).foregroundStyle(tab == index ? .white : Theme.body)
                Rectangle().fill(tab == index ? Theme.seed : .clear).frame(height: 3)
            }.frame(maxWidth: .infinity).padding(.top, 8)
        }.buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.body)
            TextField("Buscar tag ou mensagem", text: $query).font(Theme.poppins(13)).autocorrectionDisabled().textInputAutocapitalization(.never)
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark").foregroundStyle(Theme.body) } }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceHigh))
    }

    private func chip(_ level: Character, _ label: String) -> some View {
        Button { minLevel = level } label: {
            Text(label).font(Theme.poppins(13, .medium)).padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(minLevel == level ? .black : .white)
                .background(Capsule().fill(minLevel == level ? Theme.seed : Theme.surfaceHigh))
        }.buttonStyle(.plain)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { clearedAt = Date() } label: { Image(systemName: "trash") }
            Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
            Button { clearedAt = .distantPast; paused = false; stick = true; restarts += 1 } label: { Image(systemName: "arrow.counterclockwise") }
            Button { stick.toggle() } label: {
                Image(systemName: "arrow.down.to.line").foregroundStyle(stick ? Theme.seed : .white)
                    .padding(4).background(RoundedRectangle(cornerRadius: 8).fill(stick ? Theme.seed.opacity(0.18) : .clear))
            }
            Button {
                if let url = AppLog.export() { shareURL = url } else { show("Não foi possível exportar o log") }
            } label: { Image(systemName: "square.and.arrow.up") }
        }
    }

    @ViewBuilder private var content: some View {
        if (tab == 0 && shownLines.isEmpty) || (tab == 1 && shownErrors.isEmpty) {
            Text("Nada registrado ainda").font(Theme.bodyMedium).foregroundStyle(Theme.body)
        } else if tab == 0 {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shownLines.enumerated()), id: \.element.id) { index, line in
                            if index > 0 { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).padding(.leading, 16) }
                            row(line)
                        }
                        Color.clear.frame(height: 90).id("end")
                    }
                }
                .simultaneousGesture(DragGesture().onChanged { v in if v.translation.height > 10 { stick = false } })
                .onChange(of: shownLines.last?.id) { _, _ in if stick { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: stick) { _, s in if s { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
                .onAppear { if stick { proxy.scrollTo("end", anchor: .bottom) } }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(shownErrors) { errorCard($0) }
                    Color.clear.frame(height: 90)
                }.padding(.horizontal, 16).padding(.top, 12)
            }
        }
    }

    private func row(_ line: LogLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(LogLine.clock(line.date)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.body)
                badge(line.level)
                Text(line.tag).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            }
            Text(line.message).font(mono).lineLimit(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(line.isError ? Color.red.opacity(0.09) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { copy(line) }
    }

    private func badge(_ level: Character) -> some View {
        let color: Color = switch level {
        case "E", "A": .red
        case "W": Self.warn
        case "I": Theme.seed
        default: Theme.body
        }
        return Text(String(level)).font(.system(size: 10, design: .monospaced)).foregroundStyle(color)
            .frame(width: 16, height: 16).background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
    }

    private func errorCard(_ line: LogLine) -> some View {
        let hasTrace = !line.detail.isEmpty
        let open = expanded.contains(line.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.system(size: 16))
                Text(line.tag).font(Theme.poppins(14, .medium)).lineLimit(1)
                Spacer()
                Text(LogLine.clock(line.date)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.body)
                Button { copy(line) } label: { Image(systemName: "doc.on.doc").foregroundStyle(Theme.body).frame(width: 40, height: 40) }
            }
            Text(line.message).font(mono).padding(.trailing, 12)
            if !hasTrace {
                Text("Sem stack trace").font(Theme.bodySmall).foregroundStyle(Theme.body).padding(.top, 8)
            } else {
                if open {
                    ScrollView(.horizontal) {
                        Text(line.detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.body)
                            .fixedSize().padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceHigh)).padding(.top, 10).padding(.trailing, 12)
                }
                HStack(spacing: 6) {
                    Image(systemName: open ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    Text(open ? "Ocultar stack trace" : "Stack trace · \(line.detail.split(separator: "\n").count) linhas").font(Theme.poppins(14, .medium))
                }.foregroundStyle(Theme.seed).padding(.top, 10)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 16).padding(.trailing, 4).padding(.top, 4).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.surface.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { if hasTrace { if open { expanded.remove(line.id) } else { expanded.insert(line.id) } } }
    }

    private func copy(_ line: LogLine) {
        UIPasteboard.general.string = line.render()
        show("Copiado para a área de transferência")
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { if toast == text { toast = nil } } }
    }
}

private struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
