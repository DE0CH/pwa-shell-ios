import Foundation

/// Build-time settings (Info.plist keys filled from the build configuration, see scripts/configure.sh).
enum Config {
    /// The server. Debug builds (UI tests) may point elsewhere with `-PWASiteURLOverride <url>`.
    static let siteURL: URL = {
        #if DEBUG
        if let o = UserDefaults.standard.string(forKey: "PWASiteURLOverride"), let u = URL(string: o) { return u }
        #endif
        let s = Bundle.main.object(forInfoDictionaryKey: "PWASiteURL") as? String ?? ""
        return URL(string: s) ?? URL(string: "https://example.com/")!
    }()

    /// The server's sign-in endpoint (DE0CH/claudecodeui jarvis/router.mjs).
    static let signInPath = "api/jarvis/app-signin"

    /// The sign-in callback scheme: the bundle id (the server's JARVIS_APP_SCHEME).
    static var signInScheme: String { Bundle.main.bundleIdentifier ?? "pwashell" }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AI"
    }

    /// A token handed in by a UI test (Debug builds only), instead of signing in.
    static var testToken: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "PWATestToken")
        #else
        return nil
        #endif
    }

    static func url(_ path: String) -> URL {
        URL(string: path, relativeTo: siteURL)!.absoluteURL
    }
}

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(key, comment: ""), arguments: args) }

/// The UI language: zh-HK unless the app runs in English.
var uiIsChinese: Bool { (Bundle.main.preferredLocalizations.first ?? "zh-HK").hasPrefix("zh") }
