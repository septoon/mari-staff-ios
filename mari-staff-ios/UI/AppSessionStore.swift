import Foundation
import Combine

@MainActor
final class AppSessionStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        case unauthenticated
        case authenticated(StaffSession)
    }

    @Published private(set) var phase: Phase = .loading
    @Published var phone = ""
    @Published var pin = ""
    @Published var isSubmitting = false
    @Published var errorMessage = ""
    @Published var diagnosticsMessage = ""

    let configuration: AppConfigurationStore
    private let apiClient: MariAPIClient
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keychainService = "mari-staff-ios.session"
    private let keychainAccount = "staff-session"
    private var hasBootstrapped = false

    init(configuration: AppConfigurationStore) {
        self.configuration = configuration
        self.apiClient = MariAPIClient(baseURL: configuration.baseURL)
    }

    var currentSession: StaffSession? {
        if case let .authenticated(session) = phase {
            return session
        }
        return nil
    }

    var api: MariAPIClient {
        apiClient
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        await apiClient.updateBaseURL(configuration.baseURL)

        guard let persisted = loadPersistedSession() else {
            phase = .unauthenticated
            return
        }

        await apiClient.hydrate(session: persisted)

        do {
            let refreshed = try await apiClient.refresh()
            try persistSession(refreshed)
            phase = .authenticated(refreshed)
        } catch {
            await apiClient.clearSession()
            clearPersistedSession()
            phase = .unauthenticated
        }
    }

    func updateBaseURL(_ value: String) async {
        configuration.baseURL = value
        await apiClient.updateBaseURL(value)
    }

    func login() async {
        errorMessage = ""
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            await apiClient.updateBaseURL(configuration.baseURL)
            let session = try await apiClient.login(phone: phone, pin: pin)
            _ = try await apiClient.me()
            try persistSession(session)
            pin = ""
            phase = .authenticated(session)
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func runDiagnostics() async {
        diagnosticsMessage = "Проверяю API..."
        let result = await apiClient.probeHealth()
        diagnosticsMessage = result.summary
    }

    func logout() async {
        do {
            try await apiClient.logout()
        } catch {
            errorMessage = localizedMessage(for: error)
        }

        await apiClient.clearSession()
        clearPersistedSession()
        phase = .unauthenticated
    }

    func syncCurrentSession(with staff: MariAPIClient.StaffRecord) async {
        guard case let .authenticated(session) = phase else { return }
        guard session.staff.id == staff.id else { return }

        let updated = StaffSession(
            staff: .init(
                id: session.staff.id,
                name: staff.name,
                role: staff.role,
                phoneE164: staff.phoneE164,
                email: staff.email,
                permissions: staff.permissions?.map(\.code) ?? session.staff.permissions
            ),
            tokens: session.tokens
        )

        do {
            try persistSession(updated)
        } catch {
            errorMessage = localizedMessage(for: error)
        }

        await apiClient.hydrate(session: updated)
        phase = .authenticated(updated)
    }

    private func persistSession(_ session: StaffSession) throws {
        let data = try encoder.encode(session)
        try KeychainStore.save(data: data, service: keychainService, account: keychainAccount)
    }

    private func loadPersistedSession() -> StaffSession? {
        do {
            guard let data = try KeychainStore.load(service: keychainService, account: keychainAccount) else {
                return nil
            }
            return try decoder.decode(StaffSession.self, from: data)
        } catch {
            return nil
        }
    }

    private func clearPersistedSession() {
        KeychainStore.delete(service: keychainService, account: keychainAccount)
    }

    private func localizedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
