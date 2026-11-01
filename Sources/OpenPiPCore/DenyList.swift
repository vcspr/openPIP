import Foundation

/// Apps whose windows are never mirrored. The panel shows a blank "hidden for privacy" card instead.
public struct DenyList: Sendable {
    public static let builtIn: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc",
    ]

    public static let `default` = DenyList()

    private let ids: Set<String>

    public init(extra: [String] = []) {
        ids = Set((DenyList.builtIn + extra).map { $0.lowercased() })
    }

    public func isDenied(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ids.contains(bundleID.lowercased())
    }
}
