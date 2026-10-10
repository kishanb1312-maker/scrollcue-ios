import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var scripts: ScriptStore
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var search = ""
    @State private var path: [UUID] = []
    @State private var importing = false
    @State private var launch: Script?

    private var filtered: [Script] {
        let visible = scripts.scripts.filter { settingsStore.settings.showDemoScript || !$0.isDemo }
        guard !search.isEmpty else { return visible }
        return visible.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.body.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "No scripts yet" : "No results", systemImage: "text.page")
                    } description: {
                        Text(search.isEmpty ? "Tap + to write or paste your first script." : "Try a different search.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(filtered) { script in
                    NavigationLink(value: script.id) {
                        ScriptRow(script: script)
                    }
                    .swipeActions(edge: .leading) {
                        Button { launch = script } label: { Label("Start", systemImage: "play.fill") }
                            .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { scripts.delete([script.id]) } label: { Label("Delete", systemImage: "trash") }
                        Button { scripts.duplicate(script) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            .tint(.indigo)
                    }
                    .contextMenu {
                        Button { launch = script } label: { Label("Start prompter", systemImage: "play.fill") }
                        Button { UIPasteboard.general.string = script.body } label: { Label("Copy text", systemImage: "doc.on.doc") }
                        Button { scripts.duplicate(script) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { scripts.delete([script.id]) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search scripts")
            .navigationTitle("ScrollCue")
            .navigationDestination(for: UUID.self) { id in
                ScriptEditorView(scriptID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newScript() } label: { Label("New script", systemImage: "square.and.pencil") }
                        Button { pasteScript() } label: { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                        Button { importing = true } label: { Label("Import text file", systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    } primaryAction: {
                        newScript()
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .utf8PlainText, .rtf]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let text = Self.readText(url) {
                    let s = scripts.create(title: url.deletingPathExtension().lastPathComponent, body: text)
                    path.append(s.id)
                }
            }
            .fullScreenCover(item: $launch) { script in
                PrompterView(scriptID: script.id)
            }
        }
    }

    private func newScript() {
        let s = scripts.create()
        path.append(s.id)
    }

    private func pasteScript() {
        let text = UIPasteboard.general.string ?? ""
        let s = scripts.create(body: text)
        path.append(s.id)
    }

    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "rtf",
           let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return attr.string
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1)
    }
}

struct ScriptRow: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(script.displayTitle).font(.headline).lineLimit(1)
            Text(script.body.replacingOccurrences(of: "\n", with: " "))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                Text("\(script.wordCount) words")
                Text("·")
                Text("~\(script.readTime)")
                Spacer()
                Text(script.updatedAt, style: .relative) + Text(" ago")
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct ScriptEditorView: View {
    let scriptID: UUID
    @EnvironmentObject var scripts: ScriptStore
    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var launch = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $title)
                .font(.title2.bold())
                .padding(.horizontal).padding(.top, 8)
            TextEditor(text: $text)
                .focused($editing)
                .font(.system(.body, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
            HStack {
                let words = text.split(whereSeparator: { $0.isWhitespace }).count
                Text("\(words) words · ~\(Script(title: "", body: text).readTime)")
                    .font(.caption).foregroundStyle(.secondary)
                if let s = scripts.script(id: scriptID), s.lastWordIndex > 0, s.lastWordIndex < words {
                    Text("· resumes at word \(s.lastWordIndex + 1)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    save()
                    editing = false
                    launch = true
                } label: {
                    Label("Start", systemImage: "play.fill").font(.headline).padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editing { Button("Done") { editing = false } }
                Menu {
                    Button { UIPasteboard.general.string = text } label: { Label("Copy text", systemImage: "doc.on.doc") }
                    Button { text = UIPasteboard.general.string ?? text } label: { Label("Replace with clipboard", systemImage: "doc.on.clipboard") }
                    Button { if var s = scripts.script(id: scriptID) { s.lastWordIndex = 0; scripts.update(s, touch: false) } } label: {
                        Label("Reset reading position", systemImage: "arrow.counterclockwise")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            guard !loaded, let s = scripts.script(id: scriptID) else { return }
            title = s.title
            text = s.body
            loaded = true
            if s.body.isEmpty { editing = true }
        }
        .onDisappear { save() }
        .onChange(of: text) { _, _ in debounceSave() }
        .onChange(of: title) { _, _ in debounceSave() }
        .fullScreenCover(isPresented: $launch) {
            PrompterView(scriptID: scriptID)
        }
    }

    @State private var saveTask: Task<Void, Never>?

    private func debounceSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { save() }
        }
    }

    private func save() {
        guard loaded, var s = scripts.script(id: scriptID) else { return }
        guard s.title != title || s.body != text else { return }
        s.title = title
        s.body = text
        scripts.update(s)
    }
}
