import Foundation

/// User settings in UserDefaults (domain app.hemii.openpip when run as the .app).
enum Settings {
    private static let d = UserDefaults.standard

    static var opacity: Double {
        get { d.object(forKey: "opacity") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "opacity") }
    }

    static var clickThrough: Bool {
        get { d.bool(forKey: "clickThrough") }
        set { d.set(newValue, forKey: "clickThrough") }
    }

    /// Keep the panel on screen even with no agent activity.
    static var alwaysShow: Bool {
        get { d.bool(forKey: "alwaysShow") }
        set { d.set(newValue, forKey: "alwaysShow") }
    }

    /// Switch the mirror to the window named in events. Off after a manual pick.
    static var followAgent: Bool {
        get { d.object(forKey: "followAgent") as? Bool ?? true }
        set { d.set(newValue, forKey: "followAgent") }
    }

    /// Draw the agent's pointer and click ripples on the live card when events carry x/y.
    static var showCursor: Bool {
        get { d.object(forKey: "showCursor") as? Bool ?? true }
        set { d.set(newValue, forKey: "showCursor") }
    }

    /// Add agent sessions to the stack on their own when their log starts changing.
    static var autoTrackAgents: Bool {
        get { d.bool(forKey: "autoTrackAgents") }
        set { d.set(newValue, forKey: "autoTrackAgents") }
    }

    /// Image cards also list every new image in the agent's work folder, not only the ones it
    /// opened or shared.
    static var showAllNewImages: Bool {
        get { d.bool(forKey: "showAllNewImages") }
        set { d.set(newValue, forKey: "showAllNewImages") }
    }

    /// The Screen Recording window opened on its own once already.
    static var welcomeShown: Bool {
        get { d.bool(forKey: "welcomeShown") }
        set { d.set(newValue, forKey: "welcomeShown") }
    }

    /// How many windows the stack keeps (front one live, the rest frozen and blurred).
    static var maxCards: Int {
        get { d.object(forKey: "maxCards") as? Int ?? 3 }
        set { d.set(newValue, forKey: "maxCards") }
    }

    /// Extra bundle ids to blank, on top of the built-in password-manager list.
    /// `defaults write app.hemii.openpip extraDenyList -array com.example.app`
    static var extraDenyList: [String] {
        d.stringArray(forKey: "extraDenyList") ?? []
    }
}
