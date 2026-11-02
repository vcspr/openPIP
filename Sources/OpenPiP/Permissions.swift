import AppKit
import CoreGraphics

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Clears this app's Screen Recording entry so macOS asks again for the copy that is running now.
    /// Needed when the entry was saved for an older build: the switch shows "on" but this build is not allowed.
    /// Only touches this app's own entry.
    static func resetScreenRecording() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", id]
        try? task.run()
        task.waitUntilExit()
    }

    /// Starts a fresh copy of OpenPiP and quits this one. macOS tells an app about a new Screen
    /// Recording permission only when it starts.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Screen Recording window: opens by itself on first launch only, and from the menu any time.
@MainActor
final class WelcomeWindowController: NSWindowController {
    private let status = NSTextField(labelWithString: "")
    private var timer: Timer?
    var onGranted: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OpenPiP"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let line1 = NSTextField(wrappingLabelWithString:
            "OpenPiP shows a small live copy of the window an AI agent is using.")
        let line2 = NSTextField(wrappingLabelWithString:
            "It needs Screen Recording. Frames stay in memory. Nothing is saved or sent.")
        let button = NSButton(title: "Allow Screen Recording…", target: self, action: #selector(allow))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        status.font = .systemFont(ofSize: 12, weight: .medium)
        let hint = NSTextField(wrappingLabelWithString:
            "Switch already on? macOS tells OpenPiP only after a restart: click Restart OpenPiP. "
            + "Still not working? The switch belongs to an older copy of OpenPiP: click Fix Permission, "
            + "allow it once more, then restart.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let restart = NSButton(title: "Restart OpenPiP", target: self, action: #selector(restart))
        restart.bezelStyle = .rounded
        let fix = NSButton(title: "Fix Permission", target: self, action: #selector(fixPermission))
        fix.bezelStyle = .rounded
        let buttons = NSStackView(views: [restart, fix])
        buttons.spacing = 8
        let note = NSTextField(wrappingLabelWithString:
            "This window opens by itself only once. Find it again in the OpenPiP menu → Screen Recording…. "
            + "Session and image cards work without Screen Recording.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [line1, line2, button, status, hint, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        window.center()

        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    @objc private func allow() {
        if !CGRequestScreenCaptureAccess() {
            Permissions.openScreenRecordingSettings()
        }
    }

    @objc private func restart() {
        Permissions.relaunch()
    }

    @objc private func fixPermission() {
        Permissions.resetScreenRecording()
        _ = CGRequestScreenCaptureAccess()
        Permissions.openScreenRecordingSettings()
    }

    private func update() {
        if Permissions.hasScreenRecording {
            status.stringValue = "✅ Screen Recording is on. You can close this window."
            status.textColor = .systemGreen
            timer?.invalidate()
            onGranted?()
        } else {
            status.stringValue = "⚪️ Not seen yet. If you just turned it on, click Restart OpenPiP."
            status.textColor = .secondaryLabelColor
        }
    }
}
