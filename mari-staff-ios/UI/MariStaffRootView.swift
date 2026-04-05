import SwiftUI

struct MariStaffRootView: View {
    let snapshot: MariStaffSnapshot
    let session: StaffSession
    @ObservedObject var sessionStore: AppSessionStore
    let onLogout: () -> Void
    @State private var selectedTab: MariStaffTab

    init(
        snapshot: MariStaffSnapshot,
        session: StaffSession,
        sessionStore: AppSessionStore,
        onLogout: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.session = session
        self.sessionStore = sessionStore
        self.onLogout = onLogout
        _selectedTab = State(initialValue: mariAllowedTabs(for: session).first ?? .more)
    }

    private var allowedTabs: [MariStaffTab] {
        mariAllowedTabs(for: sessionStore.currentSession ?? session)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            if allowedTabs.contains(.journal) {
                NavigationStack {
                    JournalScreen(sessionStore: sessionStore)
                }
                .tabItem {
                    Label(MariStaffTab.journal.title, systemImage: MariStaffTab.journal.symbol)
                }
                .tag(MariStaffTab.journal)
            }

            if allowedTabs.contains(.schedule) {
                NavigationStack {
                    ScheduleScreen(sessionStore: sessionStore)
                }
                .tabItem {
                    Label(MariStaffTab.schedule.title, systemImage: MariStaffTab.schedule.symbol)
                }
                .tag(MariStaffTab.schedule)
            }

            if allowedTabs.contains(.clients) {
                NavigationStack {
                    ClientsScreen(sessionStore: sessionStore)
                }
                .tabItem {
                    Label(MariStaffTab.clients.title, systemImage: MariStaffTab.clients.symbol)
                }
                .tag(MariStaffTab.clients)
            }

            if allowedTabs.contains(.services) {
                NavigationStack {
                    ServicesScreen(sessionStore: sessionStore)
                }
                .tabItem {
                    Label(MariStaffTab.services.title, systemImage: MariStaffTab.services.symbol)
                }
                .tag(MariStaffTab.services)
            }

            if allowedTabs.contains(.more) {
                NavigationStack {
                    MoreScreen(sessionStore: sessionStore, onLogout: onLogout)
                }
                .tabItem {
                    Label(MariStaffTab.more.title, systemImage: MariStaffTab.more.symbol)
                }
                .tag(MariStaffTab.more)
            }
        }
        .tint(MariPalette.accent)
        .environment(\.locale, MariLocale.ru)
        .onAppear {
            ensureSelectedTabIsAllowed()
        }
        .onChange(of: allowedTabs) { _, _ in
            ensureSelectedTabIsAllowed()
        }
    }

    private func ensureSelectedTabIsAllowed() {
        guard !allowedTabs.contains(selectedTab) else { return }
        selectedTab = allowedTabs.first ?? .more
    }
}

#Preview {
    MariStaffRootView(
        snapshot: MariStaffSampleData.primary,
        session: StaffSession(
            staff: .init(
                id: "preview",
                name: "Айарпи Акопян",
                role: "OWNER",
                phoneE164: "+79786778130",
                email: "beautymari2024@gmail.com",
                permissions: []
            ),
            tokens: .init(accessToken: "access", refreshToken: "refresh", expiresInSec: 900)
        ),
        sessionStore: AppSessionStore(configuration: AppConfigurationStore()),
        onLogout: {}
    )
}
