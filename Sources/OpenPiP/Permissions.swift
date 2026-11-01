import AppKit
import CoreGraphics

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// First-run window: two lines, one button, a live tick.
@MainActor
final class WelcomeWindowController: NSWindowController {
    private let status = NSTextField(labelWithString: "")
    private var timer: Timer?
    var onGranted: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 170),
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

        let stack = NSStackView(views: [line1, line2, button, status])
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

    private func update() {
        if Permissions.hasScreenRecording {
            status.stringValue = "✅ Screen Recording is on. You can close this window."
            status.textColor = .systemGreen
            timer?.invalidate()
            onGranted?()
        } else {
            status.stringValue = "⚪️ Not granted yet. If you just turned it on, quit and reopen OpenPiP."
            status.textColor = .secondaryLabelColor
        }
    }
}
