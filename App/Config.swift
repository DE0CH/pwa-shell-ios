import Foundation

/// Build-time settings (Info.plist keys filled from the build configuration, see scripts/configure.sh).
enum Config {
    /// The web app this shell shows. A UI test may point it elsewhere with the launch argument
    /// `-PWASiteURLOverride <url>` (the argument domain of UserDefaults).
    static let siteURL: URL = {
        if let override = UserDefaults.standard.string(forKey: "PWASiteURLOverride"), let url = URL(string: override) {
            return url
        }
        let value = Bundle.main.object(forInfoDictionaryKey: "PWASiteURL") as? String ?? ""
        return URL(string: value) ?? URL(string: "https://example.com/")!
    }()

    static var siteHost: String { siteURL.host?.lowercased() ?? "" }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
    }

    /// Hosts that belong to the app: the site itself and Cloudflare Access's team domains
    /// (`<team>.cloudflareaccess.com`), where the silent re-authentication redirects pass through.
    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == siteHost || isAccessHost(host)
    }

    static func isAccessHost(_ host: String) -> Bool {
        host.hasSuffix(".cloudflareaccess.com")
    }
}

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
