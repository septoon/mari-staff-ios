import Foundation
import Combine

@MainActor
final class AppConfigurationStore: ObservableObject {
    private static let baseURLKey = "mari.staff.api-base-url"
    static let productionBaseURL = "https://api.maribeauty.ru"

    @Published var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: Self.baseURLKey)
        }
    }

    init() {
        let persisted = UserDefaults.standard.string(forKey: Self.baseURLKey)
        let resolved = Self.resolvedBaseURL(from: persisted)
        baseURL = resolved
        UserDefaults.standard.set(resolved, forKey: Self.baseURLKey)
    }

    static func resolvedBaseURL(from value: String?) -> String {
        guard let value else { return productionBaseURL }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return productionBaseURL }

        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }
        candidate = candidate.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme,
              let host = components.host,
              !scheme.isEmpty,
              !host.isEmpty
        else {
            return productionBaseURL
        }

        let normalizedHost = host.lowercased()
        if normalizedHost != "api.maribeauty.ru" {
            return productionBaseURL
        }

        return components.url?.absoluteString ?? candidate
    }
}
