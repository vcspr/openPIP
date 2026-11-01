# OpenPiP

**Picture-in-picture for AI agents on macOS.** See what your agents are doing: a live mirror of the window
a computer-use agent is working in, or a live task list and terminal for agents that work headless.

OpenPiP is a small always-on-top stack of window cards. The front card is a live mirror of the window the
agent is using right now. Older windows stay behind it, shifted up and left, lightly blurred. No bar, no
background: only the cards float. It is a menu-bar app with no Dock icon.

Any agent can drive it. Send one line of JSON to a local socket, or run one shell command, and the panel
follows the agent to the right window. It works with
[open-computer-use](https://github.com/iFurySt/open-computer-use), Claude in Chrome (through a Claude Code
hook), or your own tools.

- Native Swift (AppKit + ScreenCaptureKit). About 500 KB, no dependencies.
- Local only: no network code, no analytics, no updater. Frames stay in memory, never on disk.
- Password managers are never mirrored.

## Requirements

- macOS 14 (Sonoma) or newer, Apple silicon.
- Swift 5.10 or newer (Xcode 15.3+ or the Command Line Tools).

## Install

```bash
brew install --cask vcspr/tap/openpip
open /Applications/OpenPiP.app
```

This also puts `openpip-post` and `openpip-hook` on your PATH. Or download the zip from
[Releases](https://github.com/vcspr/openPIP/releases).

The app is ad-hoc signed, not notarized. If macOS blocks the first launch, open System Settings →
Privacy & Security and click **Open Anyway**. Then allow **Screen Recording** when OpenPiP asks.

## Build from source

```bash
git clone https://github.com/vcspr/openPIP.git && cd openPIP
scripts/build-app.sh --install     # builds, ad-hoc signs, copies to ~/Applications, installs ~/.openpip/bin tools
open ~/Applications/OpenPiP.app
swift test                         # unit tests (event parsing, auto-hide, matching, frame dedupe, layout)
```

First run shows a window asking for **Screen Recording**. Ad-hoc signing gives every build a new identity,
so after a rebuild macOS may ask again. Always run the copy in `~/Applications`.

**Switch is on but macOS keeps asking?** The switch belongs to an older build of OpenPiP. Open the menu →
**Screen Recording…** → **Fix Permission**, allow it once more, then quit and reopen OpenPiP. (It runs
`tccutil reset ScreenCapture app.hemii.openpip`, which only clears OpenPiP's own entry.)

## Use

- Menu-bar icon (PiP symbol) → **Mirror Window** to pick a window by hand. A manual pick turns off
  **Follow Agent** until you turn it back on.
- Drag a card to move the stack. Drag an edge of the front card to resize. Position is remembered.
- Click a back card to bring it to the front (this also turns off **Follow Agent**).
- **Windows in Stack** sets how many cards to keep (1 to 4, default 3). **Clear Windows** empties it.
- Empty space around the cards lets clicks through to the windows below.
- **Click-Through** (⌃⌥P anywhere) lets clicks pass through the panel.
- **Always Show Panel** keeps it up with no agent activity. **Pause Mirror** stops capture.
- Right-click the panel for the same menu.
- **Show Agent Cursor** draws the agent's pointer on the live card and a ripple on each click, when
  events carry `x`/`y`.

### Agents with no window

Many agents work headless: they run commands and edit files, with no window to mirror. **Agents** in the
menu lists every Claude Code session whose log changed in the last 15 minutes. That includes OpenBot
agents, which run Claude Code (shown by their OpenBot name, read from OpenBot's own CLI). Pick one to add a
**session card**:

- the session name and a green dot while it is working,
- its task list and progress (`TaskCreate`/`TaskUpdate`, `TodoWrite`, and the Claude desktop app's plan),
- the last step it took,
- a small terminal with its latest shell commands and the end of their output.

Click the item again to stop tracking. **Auto-Track Active Agents** adds sessions on their own as soon as
they start writing. Session cards read `~/.claude/projects/*/*.jsonl` on this Mac only, show it on your
screen, and store nothing.

The panel shows when an event arrives. It hides 5 s after an `end`/`error` event, or after 10 s with no
event and no change in the mirrored window.

While there is no window to mirror, a small pill shows the agent's last caption. The caption is also at
the top of the menu-bar menu.

Limits: minimized windows and windows on other Spaces cannot be mirrored ("Window not visible").
Password managers and Keychain Access are never mirrored ("Hidden for privacy"). Add more with
`defaults write app.hemii.openpip extraDenyList -array com.example.app`.

The panel hides itself from screen capture (`sharingType = .none`) so agents' screenshots do not see it.
It also will not show in your own screenshots. To record a demo, start it with
`OPENPIP_SHOW_IN_CAPTURE=1 ~/Applications/OpenPiP.app/Contents/MacOS/OpenPiP`.

## Event feed

Newline-delimited JSON to the socket `~/.openpip/openpip.sock` (mode 0600, this user only).
Fallback: append lines to `~/.openpip/events.jsonl` (only lines added after launch are read).

| field | | |
|---|---|---|
| `v` | required | `1` |
| `agent` | required | name, e.g. `ocu` |
| `status` | required | `start`, `step`, `end`, `error` |
| `text` | optional | caption, cut to 120 characters |
| `app` | optional | app name or bundle id to mirror |
| `window` | optional | part of the window title |
| `pid` | optional | process id of the app to mirror |
| `x`, `y` | optional | where the agent points or clicks; moves the agent cursor |
| `coords` | optional | what `x`/`y` measure: `window` (default, points from the window's top-left), `screen` (global points, top-left origin), `pixels` (window screenshot pixels) |
| `maxEdge` | optional | for `pixels`: the screenshot was shrunk so its long edge is at most this (open-computer-use uses 1280) |
| `w`, `h` | optional | size of the image `x`/`y` were measured on; wins over `coords` |

Unknown fields are ignored. Bad lines are dropped.

```bash
~/.openpip/bin/openpip-post step "Clicking Send" Mail           # status, text, [app], [window]
OPENPIP_AGENT=ocu ~/.openpip/bin/openpip-post end "Done"
OPENPIP_X=120 OPENPIP_Y=48 ~/.openpip/bin/openpip-post step "Clicking New" Notes   # cursor, window points
```

Cursor env vars: `OPENPIP_X`, `OPENPIP_Y`, `OPENPIP_COORDS`, `OPENPIP_MAXEDGE`.

`openpip-post` always exits 0, even when the app is not running.

## Claude Code hook (not installed automatically)

`openpip-hook` turns Claude Code hook input into captions. To use it, add this to
`~/.claude/settings.json` yourself. With Homebrew the path is `/opt/homebrew/bin/openpip-hook`; from
source it is `~/.openpip/bin/openpip-hook`.

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "mcp__open-computer-use__.*|mcp__claude-in-chrome__.*",
        "hooks": [{ "type": "command", "command": "~/.openpip/bin/openpip-hook" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.openpip/bin/openpip-hook" }] }
    ]
  }
}
```

It posts `click · TextEdit` style captions, mirrors the `app` named in open-computer-use tool calls, and
uses "Google Chrome" for Claude in Chrome. open-computer-use clicks with `x`/`y` move the agent cursor
(it reads the screenshot size from `~/.config/ocu/config.json`, default 1280). It prints nothing and always exits 0.

## Layout

```
Sources/OpenPiPCore/   pure logic, unit tested: Event, LineBuffer, AutoHide, WindowMatcher, DenyList,
                        FrameChange, CardStack + CardLayout, CursorMapper, SessionState, SessionLabel
Sources/OpenPiP/       app: AppDelegate (menu + wiring), PanelController, CaptureSession, WindowPicker,
                        EventServer, Permissions, HotKey, Settings, SessionWatcher, AgentScanner,
                        SessionCardRenderer
Support/Info.plist      bundle id app.hemii.openpip, LSUIElement
scripts/build-app.sh    SwiftPM release build -> .app -> codesign -s -
scripts/release.sh      version bump, zip, GitHub release, Homebrew cask update
packaging/              Homebrew cask template
bin/                    openpip-post, openpip-hook
```

## Roadmap

Cursor for Claude in Chrome (its points are page-relative), hook installer, MCP wrapper for OCU, OCU cursor-file reader, live (not frozen)
back cards, opt-in "follow frontmost window", Accessibility click-to-raise, optional caption log.

## Contributing

Issues and pull requests are welcome. Keep pure logic in `Sources/OpenPiPCore` with a unit test, and keep
AppKit and ScreenCaptureKit code in `Sources/OpenPiP`. Run `swift test` before you open a pull request.

## License

MIT. See [LICENSE](LICENSE).
