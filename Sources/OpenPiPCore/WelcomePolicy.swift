/// When the Screen Recording window opens on its own. Only once: a build can look "not allowed" even
/// with the switch on (the switch belongs to an older ad-hoc build, or the app has not restarted), and
/// asking on every launch does not help. The window stays in the menu (Screen Recording…).
public enum WelcomePolicy {
    public static func showAtLaunch(granted: Bool, shownBefore: Bool) -> Bool {
        !granted && !shownBefore
    }
}
