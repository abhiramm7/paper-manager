import SwiftUI

/// Decides whether to show onboarding or the main library UI.
struct RootView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var showOnboarding: Bool = !UserDefaults.standard.bool(
        forKey: AppConfig.onboardingDoneKey
    )

    var body: some View {
        ContentView()
            .sheet(isPresented: $showOnboarding) {
                WelcomeView(isPresented: $showOnboarding)
                    .environmentObject(store)
            }
    }
}
