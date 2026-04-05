import SwiftUI

struct ContentView: View {
    @StateObject private var sessionStore: AppSessionStore

    init(configuration: AppConfigurationStore) {
        _sessionStore = StateObject(wrappedValue: AppSessionStore(configuration: configuration))
    }

    var body: some View {
        ZStack {
            switch sessionStore.phase {
            case .loading:
                MariBackground()
                    .ignoresSafeArea()

                ProgressView("Подключаю Mari Staff")
                    .font(.headline.weight(.bold))
                    .tint(MariPalette.accent)
            case .unauthenticated:
                LoginScreen(sessionStore: sessionStore)
            case .authenticated(let session):
                MariStaffRootView(
                    snapshot: MariStaffSampleData.primary,
                    session: session,
                    sessionStore: sessionStore,
                    onLogout: {
                        Task { await sessionStore.logout() }
                    }
                )
            }
        }
        .task {
            await sessionStore.bootstrapIfNeeded()
        }
    }
}

#Preview {
    ContentView(configuration: AppConfigurationStore())
}
