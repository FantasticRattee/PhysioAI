import Foundation

enum NativeConfig {
    /// Public production endpoint shared by the Patient app and Therapist web.
    /// Build settings and local overrides still take precedence for development.
    static let productionAPIBaseURL = URL(string: "https://therapist-web.example.com")!

    static var apiBaseURL: URL? {
        let candidates = [
            UserDefaults.standard.string(forKey: "native.apiBaseURL"),
            Bundle.main.object(forInfoDictionaryKey: "PHYSIOAI_API_BASE_URL") as? String,
            ProcessInfo.processInfo.environment["PHYSIOAI_API_BASE_URL"],
        ]
        for raw in candidates.compactMap({ $0 }) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let url = URL(string: value), url.scheme != nil, url.host != nil {
                return url
            }
        }
        return productionAPIBaseURL
    }

    static var isSimulatorFixtureDefault: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }

    static var supabaseURL: URL? {
        configuredURL(named: "SUPABASE_URL")
    }

    static var supabasePublishableKey: String? {
        configuredString(named: "SUPABASE_PUBLISHABLE_KEY")
    }

    private static func configuredURL(named name: String) -> URL? {
        guard let value = configuredString(named: name),
              let url = URL(string: value),
              url.scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private static func configuredString(named name: String) -> String? {
        let candidates = [
            Bundle.main.object(forInfoDictionaryKey: name) as? String,
            ProcessInfo.processInfo.environment[name],
        ]
        for raw in candidates.compactMap({ $0 }) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !value.hasPrefix("$(") { return value }
        }
        return nil
    }
}
