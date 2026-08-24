import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore

    @State private var rootPath: String = ""
    @State private var rootStatus: (message: String, isError: Bool)?

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("iCloud root") {
                    HStack {
                        TextField("", text: $rootPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                if let note = rootStatus {
                    Text(note.message)
                        .font(.caption)
                        .foregroundStyle(note.isError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Apply", action: applyRoot)
                        .disabled(rootPath.isEmpty)
                }
            }

            Section("Watched folders") {
                Text("Sift checks these folders for PDFs at launch. Review and import what it finds from the sidebar — Watched folders → Review found PDFs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.watchedFolders.isEmpty {
                    Text("No folders yet. Add one — say, Downloads — to start discovering PDFs.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(store.watchedFolders, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                            Spacer()
                            Button {
                                store.removeWatchedFolder(path)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop watching this folder")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Add folder…", action: addWatchedFolder)
                }
            }

            Section("Auto-tagging") {
                Text("Optional. The app works without an LLM — ingest, search, ratings, and delete all work the same. Configure a provider only if you want titles, tags, and summaries filled in automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Use") {
                    Picker("", selection: Binding(
                        get: { store.llmPreference },
                        set: { store.llmPreference = $0 }
                    )) {
                        ForEach(LLMTagger.Preference.allCases) { pref in
                            Text(pref.label).tag(pref)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }

                if store.llmPreference == .auto || store.llmPreference == .claude {
                    LabeledContent("Claude model") {
                        Picker("", selection: Binding(
                            get: { store.claudeModel },
                            set: { store.claudeModel = $0 }
                        )) {
                            ForEach(LLMTagger.claudeModelChoices, id: \.self) { m in
                                Text(m.capitalized).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }
                }

                if store.llmPreference == .auto || store.llmPreference == .ollama {
                    LabeledContent("Ollama model") {
                        HStack(spacing: 6) {
                            Picker("", selection: Binding(
                                get: { store.ollamaModel },
                                set: { store.ollamaModel = $0 }
                            )) {
                                Text("(auto)").tag("")
                                ForEach(store.availableOllamaModels, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 220)
                            Button {
                                Task { await store.refreshLLMProvider() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh list of installed Ollama models")
                        }
                    }
                }

                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        // Info dot, not a warning triangle: no provider is a
                        // fine, expected state for an optional feature — it
                        // shouldn't look like an error.
                        Image(systemName: store.llmProvider.isAvailable
                              ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(store.llmProvider.isAvailable ? .green : .secondary)
                        Text(store.llmProvider.isAvailable
                             ? store.llmProvider.label
                             : "No AI helper connected (that's OK)")
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(store.llmProvider.label)
                        Spacer(minLength: 8)
                        Button("Check again") {
                            Task { await store.refreshLLMProvider() }
                        }
                        .fixedSize()
                    }
                }
                if let diag = store.llmDiagnostic, !diag.isEmpty {
                    Text(diag)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Tag vocabulary") {
                let top = store.tagStore.topTags(8)
                let total = store.tagStore.vocabulary.values.filter { $0.count > 0 }.count
                LabeledContent("Distinct tags") {
                    Text("\(total)").foregroundStyle(.secondary).monospacedDigit()
                }
                if !top.isEmpty {
                    // Stack top-tags vertically below their label so it never
                    // gets squeezed into the right column of LabeledContent.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top tags").font(.caption).foregroundStyle(.secondary)
                        Text(top.map { "\($0.name) (\($0.count))" }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Reveal tags.json in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.tagStore.fileURL])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: store.tagStore.fileURL.path))
                }
                Text("Edit descriptions in tags.json to give the LLM extra semantic context. New tags are added automatically; canonicalization prefers existing tags over near-duplicates. To consolidate near-duplicate tags, use the sidebar — Tags header icon or right-click a tag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Library counts") {
                LabeledContent("Folders") {
                    Text("\(store.allFolders.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                LabeledContent("Authors") {
                    Text("\(store.allAuthors.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Manage folders and consolidate duplicate authors from the sidebar — click the icon next to each section header, or right-click an entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("About") {
                let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
                Text("Sift \(version) — collect, tag, rate, recall. Files live in the folder above as plain PDFs and JSON.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            rootPath = store.config.iCloudRoot.path
            Task { await store.refreshLLMProvider() }
        }
    }

    /// Point the app at a different library folder. Creates the standard
    /// layout first — pointing at an empty folder used to leave the user
    /// staring at an empty library with the reason buried in a property
    /// nothing displayed.
    private func applyRoot() {
        let url = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath)
        let cfg = AppConfig(iCloudRoot: url)
        do {
            try cfg.ensureLayout()
        } catch {
            rootStatus = ("Couldn't use that folder: \(error.localizedDescription)", true)
            return
        }
        store.config = cfg
        cfg.save()
        rootStatus = ("Library folder set. \(AppConfig.cloudProviderName(for: url) ?? "Not in a synced cloud folder") — \(url.path)", false)
        Task { await store.rescan() }
    }

    private func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose folders for Sift to check for importable PDFs."
        if panel.runModal() == .OK {
            for url in panel.urls {
                store.addWatchedFolder(url)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.config.iCloudRoot
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
        }
    }
}
