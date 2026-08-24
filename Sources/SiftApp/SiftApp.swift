import SwiftUI

@main
struct SiftApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup("Sift") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    await store.rescan()
                    // Detect the LLM provider on launch — otherwise the
                    // Re-extract and AI-menu actions stay greyed out until
                    // the user opens Settings (which triggers refresh as a
                    // side effect).
                    await store.refreshLLMProvider()
                    // Check watched folders for importable PDFs. Runs after
                    // rescan so the library hashes are loaded for dedupe.
                    await store.scanWatchedFolders()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add paper…") {
                    NotificationCenter.default.post(name: .showAddSheet, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Refresh library") {
                    NotificationCenter.default.post(name: .refreshLibrary, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                // Safari's ⌘W: closes the reader tab you're on, and falls
                // through to closing the window when you're on Library.
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeActiveTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            // Find lives in the Edit menu, where ⌘F belongs. ⌘F focuses the
            // one toolbar search field — library filter or find-in-PDF,
            // depending on the tab you're on; ⌘G walks the PDF matches.
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find") {
                    NotificationCenter.default.post(name: .focusSearchField, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") {
                    NotificationCenter.default.post(name: .findNext, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") {
                    NotificationCenter.default.post(name: .findPrevious, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.shift, .command])
            }
            CommandGroup(replacing: .help) {
                Link("Open repo README",
                     destination: URL(string: "https://github.com/abhiramm7")!)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(minWidth: 620, idealWidth: 660, minHeight: 560, idealHeight: 640)
        }
    }
}

extension Notification.Name {
    static let showAddSheet = Notification.Name("Sift.showAddSheet")
    static let refreshLibrary = Notification.Name("Sift.refreshLibrary")
    static let showImportReview = Notification.Name("Sift.showImportReview")
    static let showDuplicates = Notification.Name("Sift.showDuplicates")
    static let closeActiveTab = Notification.Name("Sift.closeActiveTab")
    static let focusSearchField = Notification.Name("Sift.focusSearchField")
    static let findNext = Notification.Name("Sift.findNext")
    static let findPrevious = Notification.Name("Sift.findPrevious")
}
