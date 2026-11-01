# OpenPiP for Windows and Linux: build spec

Date: 2026-11-01. Status: spec only, decisions made (section 14). Nothing is built yet. The macOS app (Swift, this repo) was only read while researching.

Evidence tags used in this file:

- **[V]** verified on the web or from the repo on 2026-11-01 (source named).
- **[K]** known from experience, not re-checked in this run.
- **[U]** unverified. Treat as a hypothesis and test it in the spike (section 12).

---

## 1. Recommendation

**Build it in Rust, as one workspace with a platform-free core and three thin native backends (Windows, X11, Wayland). Do not use a GUI toolkit or a WebView.**

Why, in five lines:

1. The parts that matter are OS APIs, not widgets. Rust reaches all of them first-class: WinRT capture through `windows` 0.62.2, X11 through `x11rb` 0.14.0, the Wayland portal through `ashpd` 0.13.13, PipeWire through `pipewire` 0.10.1, layer-shell through `smithay-client-toolkit` 0.21.1. All are maintained as of 2026-11-01 (section 8).
2. The 10 pure-logic modules port 1:1, with about 100 Swift tests to mirror. Rust's compiler and test loop suit an AI agent doing that.
3. It stays small and quiet. No runtime, no WebView, no network crates. That matches "no network code, about 500 KB, quiet idle".
4. Packaging is easy: one static-ish exe on Windows, one binary plus a `.deb`/AppImage on Linux.
5. Rust was the first guess, and it holds. One correction: **do not pick Tauri, egui or Slint.** The overlay needs per-pixel alpha, click-through regions, layer-shell and capture exclusion. Toolkits get in the way. Draw the cards yourself with a small software renderer (`tiny-skia`) and hand the pixels to each OS.

What this means per platform (details in sections 4, 5 and 13):

- Windows gets full parity, including hiding the panel from screen capture.
- Linux X11 gets near parity, minus hiding the panel from capture.
- Linux Wayland is a reduced product. The user picks windows through a system dialog. On GNOME there is no true always-on-top overlay.

### What works where

| Feature | Windows 10 2004+ / 11 | Linux X11 | Wayland: KDE, sway, Hyprland, niri, COSMIC | Wayland: GNOME |
|---|---|---|---|---|
| Mirror one window even when covered | Yes (WGC) | Yes (XComposite) | Yes, after user picks in portal dialog | Yes, after user picks in portal dialog |
| Auto-follow by `app`/`window`/`pid` | Yes | Yes | No by default. Only on compositors with `ext-foreign-toplevel-list` + `ext-image-copy-capture` (phase 4) | No. Picker only, with remembered picks |
| Always-on-top overlay | Yes | Yes, depends on window manager | Yes (layer-shell, layer `overlay`) | No protocol for it. XWayland trick (untested) or user sets it by hand |
| Click-through | Yes | Yes (XShape) | Yes (empty input region) | X11 path only |
| See-through (per-pixel alpha) | Yes | Needs a compositing manager | Yes | Yes |
| Panel hidden from screen capture | **Yes** (`WDA_EXCLUDEFROMCAPTURE`) | **No** | **No** | **No** |
| Agent cursor from `window` / `pixels` coords | Yes | Yes | Yes | Yes |
| Agent cursor from `screen` coords | Yes | Yes | **No** (window position hidden) | **No** |
| Password-manager deny list | Yes (exe name) | Yes (`WM_CLASS`) | Only where we know the app id | **No** (we cannot see what the user picked) |
| Global click-through hotkey | Yes | Yes (X11 only) | Portal `GlobalShortcuts`: KDE yes | GNOME 48 added it, but a GNOME 49 breakage is reported [U] |
| Tray icon | Yes | StatusNotifierItem | KDE yes | Needs the AppIndicator extension [K] |

---

## 2. Language and stack comparison

Scores run 1 (bad) to 5 (best). They are my judgment from the checks below, not benchmarks. Weights: capture 25%, overlay 20%, Wayland 15%, size and idle 15%, packaging 10%, AI maintainability 15%.

| Stack | Per-window capture | Topmost, see-through, click-through overlay | Wayland | Size and idle | Packaging | AI-maintainable | Weighted |
|---|---|---|---|---|---|---|---|
| **Rust (native shells)** | 5 | 4 | 4 | 5 | 3 | 4 | **4.30** |
| C++ / Qt 6 | 4 | 4 | 4 | 2 | 3 | 2 | 3.30 |
| C# / .NET + Avalonia | 3 | 3 | 2 | 3 | 4 | 4 | 3.10 |
| Electron | 3 | 3 | 2 | 1 | 5 | 5 | 3.05 |
| Tauri 2 | 3 | 3 | 2 | 3 | 4 | 3 | 2.95 |
| Go | 2 | 2 | 2 | 4 | 4 | 4 | 2.80 |
| Flutter | 2 | 3 | 2 | 3 | 3 | 3 | 2.60 |

Reasons per row (short):

- **Rust.**
  - Capture: `windows` has the full WinRT projection (Windows.Graphics.Capture, D3D11). `windows-capture` 2.0.1 exists as a shortcut. `x11rb` covers Composite, Damage, Shm, Shape. `ashpd` + `pipewire` cover the portal. All pushed to in the last 5 weeks [V crates.io + GitHub, 2026-11-01].
  - Overlay: no single crate does everything. `winit` 0.30.13 documents `WindowLevel` as **unsupported on Wayland** [V docs.rs], so use `winit` only for a prototype. Thin per-OS shells give exact control.
  - Weak spots: MSI tooling is thin (`cargo-wix` last released 2025-03-13). `unsafe` FFI needs care.
- **C++ / Qt 6.**
  - Everything is reachable, but by hand.
  - Qt's own `QWindowCapture` works only with the FFmpeg backend and lists X11 limits [V doc.qt.io, excerpt]. Wayland support for it is **[U]**.
  - Qt DLLs and LGPL linking make it large. CMake plus vcpkg is slow for an agent to iterate on.
- **C# / Avalonia.**
  - Excellent on Windows (WinRT projections, MSIX/WiX tooling).
  - On Linux you P/Invoke PipeWire and X11 yourself.
  - Avalonia has no layer-shell.
  - If the product were Windows-only, C# would be a fair pick. Linux is the hard half, so it loses.
- **Electron.**
  - Fastest route to a demo, and its picker handles the portal for you.
  - `setContentProtection` works on **macOS and Windows only** [V electronjs.org].
  - Click-through is supported on X11 and Wayland [V], but Electron 43 had a regression on X11 where clicks were absorbed. It was fixed in 43.7.6 [V github.com/electron/electron/issues/52456]. That shows how brittle overlay features are on top of Chromium.
  - Idle memory in the hundreds of MB and a Chromium network stack contradict "small, quiet, no network code".
- **Tauri 2.**
  - Has `setContentProtected` and `setIgnoreCursorEvents` [V v2.tauri.app]. Linux behavior of each is **[U]**.
  - Capture still needs a Rust plugin, so you carry Rust plus a WebView and gain little. `windowEffects` is unsupported on Linux [V].
- **Go.**
  - No WinRT projection (COM by hand).
  - Toolkits such as Fyne and Gio lack topmost/click-through.
  - Fine for the CLI client, wrong for the app.
- **Flutter.**
  - Capture and overlay both need native code through FFI, so it has no advantage over Rust. It adds an engine and plugin churn.

---

## 3. Architecture and file layout

One workspace, added to the existing repo under `cross/` so the Swift app stays untouched. A shared `testdata/vectors/` folder is read by both Swift tests and Rust tests. It is the parity guard.

```
cross/
  Cargo.toml                       workspace
  crates/
    openpip-core/                  pure logic, no OS deps. 1:1 ports of OpenPiPCore
      src/event.rs line_buffer.rs auto_hide.rs window_matcher.rs deny_list.rs
          frame_change.rs card_stack.rs (CardStack + CardLayout) cursor_mapper.rs
          session_state.rs session_label.rs geometry.rs
    openpip-app/                   platform-free app model (the logic now inside AppDelegate)
      src/model.rs                 follow agent, pin, pause, stack, auto-hide ticks, "Window not visible"
          settings.rs              JSON file, see section 9
          session_watcher.rs agent_scanner.rs events_tail.rs
    openpip-render/                tiny-skia + cosmic-text: card compositor
      src/compose.rs               cards, blur of frozen back cards, veil, border
          session_card.rs          port of SessionCardRenderer (vector icons, no emoji glyphs)
          overlay_fx.rs            agent cursor, click ripple, caption pill
    openpip-platform/              traits and shared types only
      src/lib.rs                   WindowSource, Capture, Overlay, Hotkey, Tray, Frame
    openpip-win/                   Windows backend (windows crate)
    openpip-x11/                   X11 backend (x11rb)
    openpip-wayland/               Wayland backend (SCTK layer-shell, ashpd + pipewire)
    openpip-cli/                   one tiny multi-call bin: openpip-post, openpip-hook (no GUI deps)
    openpip/                       main binary. cfg(target_os) and runtime session detection pick backend
  testdata/vectors/                events.jsonl, session logs, matcher cases, layout cases
  packaging/windows/ packaging/linux/
  .github/workflows/ci.yml release.yml
```

Rules:

- `openpip-core` and `openpip-app` compile and test on every OS with no system libraries.
- UI thread owns the overlay. Capture, socket, file watching run on `std::thread`s and send messages over `crossbeam-channel`. **No async runtime** in the main app. It costs size and idle memory. `ashpd`'s default feature pulls tokio, so use `default-features = false, features = ["async-io", "screencast", "global_shortcuts"]` and drive it with `pollster` on one thread. That feature combination is **[U]** to build. Feature names are [V] from crates.io.
- Core `WindowInfo` differs from Swift on purpose:
  - `id: u64` (an HWND is pointer-sized).
  - `app_ids: Vec<String>` instead of one `bundleID`. It holds every identifier the `app` hint may match, lower-cased:
    - Windows: exe name, exe stem, product name.
    - X11: `WM_CLASS` class and instance, `.desktop` id.
    - Wayland: `app_id`.
  - Add a small alias table in core (for example "Google Chrome" matches `chrome`, `chrome.exe`, `google-chrome`, `chromium`), because `openpip-hook` sends the macOS name for Claude in Chrome.
  - `frame` stays in **points** (physical pixels divided by monitor scale). That keeps `CursorMapper` identical to the Swift version.

---

## 4. Capture design per platform

Common rules (same as macOS): stream one window at 15 fps while it changes and 5 fps when still. Cap the long edge at 1600 px. Drop repeat frames with the FNV-1a fingerprint (every 61st byte). Frames live in memory only. Never write them to disk.

### 4.1 Windows (Windows.Graphics.Capture)

| Item | Design |
|---|---|
| Minimum OS | **Windows 10 2004 (build 19041).** `CreateForWindow` needs 1903 (18362) [V Microsoft Learn]. `WDA_EXCLUDEFROMCAPTURE` needs 2004, and on older builds it silently acts as `WDA_MONITOR` (a black box) [V Microsoft Learn]. Refuse to start below 19041. |
| Enumerate | `EnumWindows`. Keep windows that are visible or minimized, 80x60 or larger, not our own, not tool windows without a title. Skip cloaked windows (`DWMWA_CLOAKED`). Pid from `GetWindowThreadProcessId`. Exe name from `QueryFullProcessImageNameW`. Bounds from `DWMWA_EXTENDED_FRAME_BOUNDS`. `is_on_screen = visible && !iconic && !cloaked`. |
| UWP / Store apps | The top window belongs to `ApplicationFrameHost.exe`. Look for a child window owned by another pid and use that pid and exe. **[U]** test with Calculator. |
| Start | `IGraphicsCaptureItemInterop::CreateForWindow(hwnd)`, then `Direct3D11CaptureFramePool::CreateFreeThreaded` (BGRA8, 2 buffers), then `FrameArrived`. |
| Frame to CPU | Copy to a staging texture, map, fingerprint, then hand a tightly packed BGRA buffer to the renderer. For windows above about 1080p, downscale on the GPU first (generate mips, copy a small mip). **[U]** perf. |
| Covered windows | WGC delivers frames while other windows cover the target. **[K]** Verify in the spike. |
| Minimized | Frames stop. Show the "Window not visible" note, same as macOS. |
| Rate | `GraphicsCaptureSession.MinUpdateInterval` exists on newer builds. `windows-capture` wraps it as `MinimumUpdateIntervalSettings` [V README]. Gate on OS build. **[U]** the exact build number. Fallback: drop frames in our own code. |
| Cursor | `IsCursorCaptureEnabled = false`. |
| **Yellow border** | See below. |
| Fallbacks | (1) **DXGI Desktop Duplication** (`windows-capture` 2.0.1 supports it [V README]). It captures a monitor, not a window, so a covered window shows the covering window. Offer it only as "mirror screen region, not covered". (2) `PrintWindow(PW_RENDERFULLCONTENT)` at 2 fps for apps WGC refuses. **[U]** quality. |

**Yellow border.** WGC draws a yellow frame around a captured window.

- `GraphicsCaptureSession.IsBorderRequired` exists from build 20348 (Windows 11 and Server 2022) [V Microsoft Learn].
- The docs say you must call `GraphicsCaptureAccess.RequestAccessAsync(Borderless)` and declare the `graphicsCaptureWithoutBorder` capability. That is for packaged apps.
- A Microsoft engineer wrote in the WebRTC tracker that a **Win32 (unpackaged) app can call `put_IsBorderRequired(false)` without `RequestAccessAsync`** [V issues.webrtc.org/issues/42225786, comments 6 and 15]. OBS says it disables the border automatically on Windows 11 [V ideas.obsproject.com].
- Plan: unpackaged exe. On Windows 11, set `IsBorderRequired = false`. **On Windows 10 the border stays and cannot be removed.** Say so in the first-run text.
- Test that the call really works in an unpackaged exe on current Windows 11 (spike). If not, the fallback is an MSIX build with the capability. That adds a signing need (section 11).
- If another app also captures the same window with the border on, the border shows [V Microsoft Learn].

**Hide the panel from capture:** `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)`.

- Needs DWM composition, a top-level window, and the window must belong to our process [V Microsoft Learn].
- The page does not say whether layered windows are allowed. **[U]** This is the top Windows spike item (section 12). Plan B is a `WS_EX_NOREDIRECTIONBITMAP` window with a DirectComposition premultiplied-alpha swap chain.
- Add `OPENPIP_SHOW_IN_CAPTURE=1` as on macOS, for demo recordings.

**Windows that hide themselves.** Some apps set `WDA_EXCLUDEFROMCAPTURE` or `WDA_MONITOR` on their own windows. Their capture comes back empty or black. That is acceptable and even helpful for password managers. Whether any password manager does this is **[U]**.

### 4.2 Linux X11 (XComposite + Damage + Shm)

| Item | Design |
|---|---|
| Enumerate | `_NET_CLIENT_LIST` (fallback: `QueryTree` on root). Title from `_NET_WM_NAME` then `WM_NAME`. `WM_CLASS`, `_NET_WM_PID`, geometry via `GetGeometry` + `TranslateCoordinates`. `is_on_screen` = viewable and not `_NET_WM_STATE_HIDDEN`. |
| Capture | `composite::redirect_window` (automatic mode), `composite::name_window_pixmap`, then read with `shm::get_image` (or plain `GetImage`). Wake on `damage` events. Re-name the pixmap after resize or remap. The redirect keeps content off-screen, so a covered window still has pixels. |
| Pixel format | ZPixmap 24/32-bit BGRX. Force alpha to 255. |
| Not visible | Unmapped (minimized) windows have no pixels. Many window managers also unmap windows on other workspaces. Show "Window not visible". |
| Compositor | With or without a running compositing manager, redirect works. |
| Exclude panel | **Impossible.** Per-window pixmaps never contain our panel, but an agent's full-screen screenshot will. Mitigation in section 5.2. |
| In Wayland sessions | The X11 backend sees only XWayland clients. Do not use it for capture there. Pick the backend from `XDG_SESSION_TYPE` / `WAYLAND_DISPLAY`. |

### 4.3 Linux Wayland (xdg-desktop-portal ScreenCast + PipeWire)

Facts [V flatpak.github.io/xdg-desktop-portal, ScreenCast v6 page]:

- Flow: `CreateSession`, `SelectSources`, `Start`, `OpenPipeWireRemote`.
- `SelectSources` takes `types` (1 monitor, 2 window, 4 virtual), `multiple`, `cursor_mode` (default hidden), `persist_mode` and `restore_token`.
- `Start` shows a dialog to the user.
- A stored session that cannot be restored (the window is gone, permission withdrawn) is ignored and the user is asked again.
- Restore tokens are single use. Each `Start` returns a new one. Store it every time.
- Version 6 adds `pipewire-serial`; prefer it over the node id.
- Stream properties give `size`. For window streams there is no screen `position` (it is "only available for monitor streams").

Design:

1. Ask for `types = WINDOW`, `multiple = true`, `cursor_mode = Hidden`, `persist_mode = 2` (until revoked). Save the returned `restore_token` in the settings file.
2. Connect with `pipewire` 0.10.1. Ask for **shared-memory buffers only** (BGRx/BGRA). This avoids DMA-BUF and GPU import. Handle the `param_changed` event for window resizes. Whether GNOME and KDE both honor an SHM-only request is **[U]**.
3. One portal dialog can return several windows. Label them "Window 1", "Window 2". The portal does not tell us the app or title. **[U]** whether PipeWire node properties (`node.description`) carry a usable name.
4. The user can bind a name: first time an event arrives with `app=X` and nothing is bound, show "Pick the window for X". Remember the binding to a restore token. Whether GNOME restores a window source across sessions is **[U]**; plan for a prompt each time.

What cannot work on Wayland:

- Enumerating other apps' windows. Unless the compositor allows it (see 4.4), `app`/`window`/`pid` hints cannot choose a window.
- Reading global window positions, so `coords: "screen"` cannot be mapped. `window` and `pixels` work because the stream knows its own size.
- Capturing without a user dialog, on compositors without the new capture protocols.

### 4.4 Phase 4 option: no-dialog capture on wlroots-style compositors

`ext-foreign-toplevel-list-v1` lists toplevels with `app_id`, title and identifier. `ext-image-capture-source-v1` + `ext-image-copy-capture-v1` capture one toplevel continuously. With them the Wayland backend can match events and skip the dialog, as on X11.

Status [V wayland.app Wayland Explorer, fetched 2026-11-01]:

| Compositor | Support (explorer table) |
|---|---|
| Jay 1.14.0, Louvre 2.14.1, Treeland 0.8.0 | Capture-source protocol supported |
| Mir 2.26 | Partial |
| Hyprland 0.52.1, KWin 6.7, Mutter 51 | Listed as **not** supported |
| Sway / wlroots | Merged in wlroots in Jan 2025 and added to sway [V emersion.fr status update, Reddit thread title]. Not shown in the table. |

- The Rust bindings exist: `wayland-protocols` 0.32.13 has `ext::image_capture_source`, `ext::image_copy_capture` and `ext::foreign_toplevel_list` behind the `staging` feature [V docs.rs].
- Treat this as an opt-in extra for sway-like setups. Do not plan the product around it. Re-check the support table before starting phase 4.

---

## 5. Overlay window per platform

Behavior to match: a stack of cards, empty space lets clicks through, whole panel can be click-through by hotkey, opacity setting, drag to move, drag front-card edge to resize, position remembered, not in taskbar or Alt-Tab, never takes focus.

### 5.1 Windows

| Need | How |
|---|---|
| Window | One hand-made Win32 window (about 400 lines with `windows` crate). Styles: `WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`, popup, no frame. |
| See-through | `UpdateLayeredWindow` with a premultiplied BGRA DIB. Global opacity setting = `SourceConstantAlpha` in `BLENDFUNCTION`. |
| Empty space passes clicks | Expected: pixels with alpha 0 on a per-pixel-alpha layered window let mouse input fall through. **[K]** Confirm in the spike. If it fails, set a `SetWindowRgn` or handle `WM_NCHITTEST` returning `HTTRANSPARENT` outside card rects. |
| Click-through toggle | Add or remove `WS_EX_TRANSPARENT` with `SetWindowLongPtrW`. |
| Not in capture | `WDA_EXCLUDEFROMCAPTURE` (4.1). |
| Hotkey | `RegisterHotKey(MOD_CONTROL | MOD_ALT, 'P')`. Needs no extra permission. |
| DPI | Application manifest with Per-Monitor-V2 DPI awareness. Embed with `winresource` 0.1.34 [V crates.io]. |
| All virtual desktops | **[U]** A normal topmost tool window shows on one desktop. Plan: poll `IVirtualDesktopManager::IsWindowOnCurrentVirtualDesktop` while visible, and call `MoveWindowToDesktop` (documented, works on our own windows) to follow the user. The "pin to all desktops" interfaces are undocumented, so do not use them. |
| Tray | Plain `Shell_NotifyIconW` with the `windows` crate, or `tray-icon` 0.26.1 [V crates.io]. Pick the plain API to avoid pulling GTK-style loops. |
| Over fullscreen | Topmost windows show over borderless fullscreen but not over exclusive fullscreen games. Document it. |

### 5.2 Linux X11

| Need | How |
|---|---|
| Window | `x11rb`, 32-bit ARGB visual, own colormap. Managed window with `_NET_WM_WINDOW_TYPE_UTILITY`, `_NET_WM_STATE = ABOVE | STICKY | SKIP_TASKBAR | SKIP_PAGER`, `WM_HINTS.input = false`, `_NET_WM_DESKTOP = 0xFFFFFFFF`. |
| Fallback | Override-redirect window plus a periodic raise, for window managers that ignore `ABOVE`. **[U]** which ones. |
| Compositor needed | Per-pixel alpha needs a compositing manager. Detect the `_NET_WM_CM_S0` selection owner. If absent, draw an opaque panel and warn once. |
| Input region | `shape::rectangles` on `ShapeInput` = union of card rects. Empty set = full click-through. |
| Hotkey | `global-hotkey` 0.9.0, README says **Linux (X11 only)** [V]. Or raw `XGrabKey`. |
| Exclude from capture | **None.** Mitigations to offer: (a) menu "Hide panel for 30 s", (b) a CLI `openpip-post hide`. Neither is automatic. State this limit in the README. |

### 5.3 Linux Wayland

**Compositors with layer-shell** [V wayland.app wlr-layer-shell table]: KWin 6.7, Hyprland 0.52.1, niri 26.04, COSMIC 1.0.0~beta.8, Sway 1.11, Wayfire, Labwc, river and others. **Mutter 51 (GNOME) and Weston 15 do not.**

- Create a `zwlr_layer_surface_v1` on layer `overlay`, anchored top-left; position with margins; keyboard interactivity `none`.
- Draw with `wl_shm` ARGB8888 buffers (SCTK `SlotPool`).
- Click-through and empty-space pass-through: set the surface **input region** to the card rects, or to an empty region. The protocol text says to use an empty input region for no pointer events [V].
- Dragging: change margins on pointer motion. Resizing: change size. A layer surface is tied to one output; start by keeping it on one monitor.
- HiDPI: start with integer buffer scale. Fractional scale is a later task **[U]**.
- Crates: `smithay-client-toolkit` 0.21.1, `wayland-protocols-wlr` 0.3.12. Do **not** use `gtk4-layer-shell` (pulls GTK4).

**GNOME (no layer-shell).** There is no protocol for a normal app to stay above others. Options, best first:

1. **XWayland path (experimental).** Run the X11 backend with `WAYLAND_DISPLAY` unset. GNOME ships XWayland. `_NET_WM_STATE_ABOVE` on an XWayland window should be honored. **[U]** Test on a current GNOME. Capture still goes through the portal (the X11 capture code cannot see native Wayland windows).
2. **Plain window plus instructions.** An ordinary window; the user sets "Always on Top" in the window menu.
3. A GNOME Shell extension. Heavy and fragile. Not planned.

**Exclude panel from capture:** no standard Wayland mechanism. Window-source mirroring never includes our panel, but an agent's monitor screenshot will. Hyprland has a per-window `noscreenshare` rule **[U]** that users could set. Do not promise it.

**Hotkey.** Use the `GlobalShortcuts` portal through `ashpd` (feature `global_shortcuts`). KDE: yes. GNOME: GNOME 48 introduced support, and a report shows it broken on GNOME 49 with xdg-desktop-portal-gnome 49.0 [V GNOME Discourse, github.com/cjpais/Handy/issues/1236]. Always keep the tray/menu entry as the dependable way.

**Tray.** `ksni` 0.3.7 (pure Rust StatusNotifierItem, no GTK) [V crates.io]. GNOME needs the AppIndicator extension [K].

### 5.4 Drawing

- `openpip-render` composes the whole panel into one premultiplied BGRA buffer using `tiny-skia` 0.12.0. Text uses `cosmic-text` 0.19.0 with `fontdb` 0.24.0 for system fonts [V crates.io]. Use `fast_image_resize` 6.1.0 for scaling [V].
- The back cards are frozen, so blur them **once** when they leave the front (box blur on a downscaled copy). The front card is scaled per changed frame only. Idle cost is then close to zero.
- Draw check marks, dots, arrows as vector shapes. Do not depend on emoji or symbol glyphs, which differ per OS.
- Hit areas for dragging and input regions come from `CardLayout.frames`.

---

## 6. Event protocol and transport

The JSON protocol **does not change**: same fields, same limits (4096 bytes per line, caption cut to 120 characters, unknown fields ignored, bad lines dropped, `v` must be 1). Only the transport differs.

| | Windows | Linux |
|---|---|---|
| Live channel | Named pipe `\\.\pipe\openpip-<user>` | Unix stream socket `$XDG_RUNTIME_DIR/openpip/openpip.sock` |
| Access control | Explicit user-only DACL (below) | Directory `0700`, socket `0600`, peer uid check |
| Fallback file | `%USERPROFILE%\.openpip\events.jsonl` | `~/.openpip/events.jsonl` |
| Lines read from file | Only lines added after launch, polled every 1 s (same as macOS) | same |
| Single instance | `FILE_FLAG_FIRST_PIPE_INSTANCE` | bind fails if a live server answers; remove stale socket otherwise |

I keep the jsonl path as `~/.openpip/` on both OSes so docs and agent prompts stay the same as on macOS. If `XDG_RUNTIME_DIR` is unset, use `/tmp/openpip-<uid>/` created `0700` and refuse to use it if it is owned by someone else.

**Windows pipe security (important).**

- The default security descriptor of a named pipe gives full control to SYSTEM, administrators and the creator, and **read access to Everyone and the anonymous account** [V Microsoft Learn, Named Pipe Security and Access Rights].
- So set an explicit descriptor: SDDL `D:P(A;;GA;;;<current user SID>)`, converted with `ConvertStringSecurityDescriptorToSecurityDescriptorW`.
- Also use `PIPE_REJECT_REMOTE_CLIENTS` and `FILE_FLAG_FIRST_PIPE_INSTANCE` (stops another process squatting the name).
- Build it with raw `windows` crate calls (about 60 lines). I do not rely on the `interprocess` crate here. Whether it accepts a security descriptor on Windows is **[U]** (docs.rs only builds Linux docs). On Linux plain `std::os::unix::net` is enough, so drop `interprocess` entirely.
- One thread per client, max 32, as in the Swift server. We never reply.
- Windows 10 1803+ also has `AF_UNIX` sockets **[K]**. Not chosen: access control would be file ACLs only, with no peer check.

**Linux peer check.** Read `SO_PEERCRED` and require our uid. Use `rustix` 1.1.6 [V crates.io] (`std`'s peer-cred API was unstable when last checked **[U]**).

**Clients (ports of `openpip-post` and `openpip-hook`).** Ship **one tiny compiled Rust program** that behaves by file name, not PowerShell.

- Reasons: hooks run on every tool call, so a slow shell start hurts (PowerShell cold start cost is **[U]** but known to be noticeable). `nc -U` flags differ between netcat flavors on Linux.
- Claude Code runs hook commands with `sh -c` on macOS/Linux, **Git Bash on Windows, or PowerShell when Git Bash is not installed** [V code.claude.com/docs/en/hooks]. A plain `.exe` works in all three. A `.sh` script would not.
- Names: `openpip-post(.exe)` and `openpip-hook(.exe)`. Same arguments and env vars as today (`OPENPIP_AGENT`, `OPENPIP_SOCK`, `OPENPIP_X`, `OPENPIP_Y`, `OPENPIP_COORDS`, `OPENPIP_MAXEDGE`). Add `OPENPIP_PIPE` for Windows. Always exit 0. Hand-parse arguments (no `clap`) to keep it near 300 KB.
- JSON escaping rules and the "numbers must look like numbers" check are copied from the shell script into `openpip-core::event::build_line` and tested with the shared vectors.
- `openpip-hook` reads the hook JSON from stdin with `serde_json` (replaces `plutil`). The `open-computer-use` branch (reads `~/.config/ocu/config.json`) is macOS-first. Whether OCU runs on Windows or Linux is **[U]**. Keep the branch but make it a no-op if the file is missing.
- Keep a POSIX `openpip-post.sh` in `bin/` as a documented fallback for Linux.
- **WSL:** an agent running inside WSL cannot reach a Windows named pipe. It can run `openpip-post.exe` through WSL interop **[U]**, so document that. Claude Code logs from WSL live under the Linux home, not `%USERPROFILE%` (section 7).

Settings changes needed for hooks on Windows: the README hook example uses `~/.openpip/bin/openpip-hook`. On Windows use `"%USERPROFILE%\\.openpip\\bin\\openpip-hook.exe"` or the full path. Git Bash and PowerShell expand differently, so give the full path in the install text.

---

## 7. Session cards: logs and file watching

| Item | Windows | Linux |
|---|---|---|
| Default root | `%USERPROFILE%\.claude\projects\*\*.jsonl` | `~/.claude/projects/*/*.jsonl` |
| Override | `CLAUDE_CONFIG_DIR` (Claude Code's own variable, "default `~/.claude`", holds session history) [V code.claude.com/docs/en/env-vars], plus `OPENPIP_PROJECTS_DIR` as today | same |
| Home dir | `dirs` 7.0.0 `home_dir()` [V crates.io] | same |

Log format: assumed identical on all OSes (same JSONL). Only the **folder naming** was checked.

- On Windows, Claude Code names the folder from the working directory. `C:\git\cc-plus` becomes `C--git-cc-plus` [V github.com/anthropics/claude-code/issues/18829, Claude Code 2.1.11]. So `:` and `\` both become `-`. The encoding is lossy (hyphens in real names look like separators) [V same issue].
- `SessionLabel` must encode `\`, `:`, `/` and `.` as `-` when it builds the home prefix. Other characters (spaces, non-ASCII) are **[U]**. Treat every non-alphanumeric as `-` as a working rule and add test vectors captured from real Windows logs before trusting it.
- OpenBot labelling: the macOS code calls `/Applications/OpenBot.app/.../openbot-cli.mjs`. On other OSes make the CLI path a setting, default off. Whether OpenBot ships for Windows or Linux is **[U]**. The folder pattern `-OpenBot-Agents-agent-` should be checked against Windows-style names.

**Reading rules (port of `SessionWatcher`):** first read skims everything before the last 6 MB for task and title lines only, then reads the tail fully, then reads only appended bytes. Line limit 4 MB.

- Poll with `metadata().len()` every 1 s. Do not use `notify` (8.2.1 stable; 9.0.0 is still a release candidate [V crates.io]). Polling avoids watch limits and WSL/network oddities.
- Rust's `File::open` on Windows already opens with read, write and delete sharing **[K]**, so reading a log Claude Code is appending to is fine.
- Scanner: look at file modified times only, last 15 minutes, newest first. Read the title from the last 512 KB. Same as Swift.
- Time stamps: ISO 8601 with and without fractions. Use a small parser or the `time` crate (version **[U]**, not checked).
- ANSI stripping: hand-written state machine instead of `regex`, to save size.
- Text rule for captions: Swift's `prefix(120)` counts **grapheme clusters**. In Rust use `unicode-segmentation` (version **[U]**), not bytes or chars. Same for `components(separatedBy: .newlines)`, which splits on Unicode line separators. Lock this with vectors that include emoji and U+2028.

---

## 8. Crate picks

Checked 2026-11-01 against crates.io, plus GitHub or GitLab activity.

| Job | Crate | Version | Last crates.io release | Repo activity | Verdict |
|---|---|---|---|---|---|
| Windows API | `windows` | 0.62.2 | 2025-10-06 | pushed 2026-11-01 | Use. Releases are slower than commits. |
| Windows API (lean) | `windows-sys` | 0.61.2 | 2025-10-06 | same repo | Use for the tiny CLI client. |
| Windows capture helper | `windows-capture` | 2.0.1 | 2026-08-08 | pushed 2026-10-05, 524 stars | Optional. Good for spike. Plan to own the WGC code later, since it is a single-maintainer crate **[U]**. |
| Windows exe resources | `winresource` | 0.1.34 | 2026-10-12 | n/a | Use for icon and manifest. |
| Windows registry | `windows-registry` | 0.100.0 | 2026-09-03 | n/a | Only if autostart is added. |
| X11 | `x11rb` | 0.14.0 | 2026-07-16 | pushed 2026-10-30 | Use. |
| Portal (ScreenCast, GlobalShortcuts) | `ashpd` | 0.13.13 | 2026-07-17 | pushed 2026-11-01 | Use. Features `screencast`, `global_shortcuts`, `async-io` exist [V]. |
| D-Bus | `zbus` | 6.2.1 | 2026-11-01 | n/a | Comes with `ashpd`. |
| PipeWire | `pipewire` | 0.10.1 | 2026-08-19 | GitLab activity 2026-10-27 | Use. Needs `libpipewire` at build and run time, plus `clang`/`pkg-config` to build. |
| Wayland | `wayland-client` | 0.31.15 | 2026-07-22 | pushed 2026-10-30 | Use. |
| Wayland toolkit | `smithay-client-toolkit` | 0.21.1 | 2026-07-23 | pushed 2026-10-16 | Use. |
| Wayland protocols | `wayland-protocols` | 0.32.13 | 2026-06-19 | same repo | Use, feature `staging` for ext capture. |
| layer-shell bindings | `wayland-protocols-wlr` | 0.3.12 | 2026-03-31 | same repo | Use. |
| 2D drawing | `tiny-skia` | 0.12.0 | 2026-02-02 | n/a | Use. |
| Text | `cosmic-text` | 0.19.0 | 2026-04-22 | n/a | Use. |
| Font discovery | `fontdb` | 0.24.0 | 2026-07-29 | n/a | Use. |
| Image scaling | `fast_image_resize` | 6.1.0 | 2026-07-21 | n/a | Use. |
| Hotkey | `global-hotkey` | 0.9.0 | 2026-10-16 | pushed 2026-10-26 | Use on Windows and X11 only. README: "Linux (X11 Only)" [V]. |
| Linux tray | `ksni` | 0.3.7 | 2026-10-20 | n/a | Use. |
| Tray alternative | `tray-icon` | 0.26.1 | 2026-10-07 | pushed 2026-10-26 | Skip on Linux (GTK). |
| Unix sockets, peer creds | `rustix` | 1.1.6 | 2026-10-27 | n/a | Use. |
| JSON | `serde`, `serde_json` | 1.0.229, 1.0.154 | 2026-07-18, 2026-10-11 | n/a | Use. |
| Channels | `crossbeam-channel` | 0.5.17 | 2026-09-05 | n/a | Use. |
| Blocking on futures | `pollster` | 1.0.1 | 2026-07-10 | n/a | Use for `ashpd` calls. |
| Errors | `thiserror` | 2.0.21 | 2026-09-23 | n/a | Use. |
| Config dirs | `dirs` | 7.0.0 | 2026-09-05 | n/a | Use. |
| Prototype window | `winit` | 0.30.13 (0.31.0-beta.4 is a pre-release) | stable 0.30.x | pushed 2026-11-01, 731 open issues | Spike only. |
| Prototype pixels | `softbuffer` | 0.4.8 | 2025-12-13 | pushed 2026-10-26 | Spike only. |
| Release tooling | `cargo-dist` | 0.32.0 | 2026-05-22 | n/a | Optional. |
| .deb | `cargo-deb` | 3.8.0 | 2026-09-01 | n/a | Use. |
| MSI | `cargo-wix` | 0.3.9 | 2025-03-13 | n/a | Stale. Prefer WiX files by hand. |
| Bundler | `cargo-packager` | 0.11.8 | 2025-11-27 | n/a | Evaluate only. |

Looked at and rejected:

- `scap` 0.0.8 (2025-08-04): looks stale.
- `xcap` 0.9.8 (2026-08-01): maintained, but behavior on Wayland and covered windows is **[U]**. Use only as a comparison in the spike.
- `tauri` 2.12.5, `eframe/egui` 0.37.0, `slint` 1.18.1: toolkits we do not want for the overlay.
- `gtk4-layer-shell` 0.8.1: drags in GTK4.
- `interprocess` 2.4.7: not needed (section 6).

Not checked this run: MSRV of each crate, licenses of each crate (run `cargo deny` in CI), `time` and `unicode-segmentation` versions.

---

## 9. Settings and behavior parity

Same settings as `Settings.swift`, stored as JSON in `%APPDATA%\openpip\settings.json` or `$XDG_CONFIG_HOME/openpip/settings.json`.

| Key | Default | Notes |
|---|---|---|
| `opacity` | 1.0 | clamp 0.2 to 1 |
| `clickThrough` | false | toggled by Ctrl+Alt+P |
| `alwaysShow` | false | |
| `followAgent` | true | off after a manual pick or card click |
| `showCursor` | true | |
| `autoTrackAgents` | false | |
| `maxCards` | 3 | 1 to 4 |
| `extraDenyList` | [] | app ids: exe names (Windows), `WM_CLASS`/app ids (Linux) |
| `frame` | none | panel position and size |
| `waylandRestoreToken` | none | Wayland only; single-use, rewritten every start |

Behaviors that carry over unchanged: auto-hide (5 s after `end`/`error`, 10 s idle), stack of 1 to 4 cards, front live and back frozen and blurred, "Hidden for privacy" card, "Window not visible" note, caption pill when no window, 15-minute agent list, click a back card to bring it front (turns off follow).

Deny-list starting names (all **[U]**, check against real installs):

- Windows exe names: `1Password.exe`, `Bitwarden.exe`, `KeePassXC.exe`, `KeePass.exe`, `Dashlane.exe`, `Enpass.exe`, `NordPass.exe`.
- Linux `WM_CLASS`/app ids: `1password`, `Bitwarden`, `keepassxc`, `org.keepassxc.KeePassXC`, `Enpass`, `seahorse`, `org.kde.kwalletmanager`.
- Browser-based vaults are not covered, same as on macOS.

---

## 10. Porting order and milestones

Time estimates are mine, for an AI agent with a human reviewing.

| # | Milestone | Scope | Exit test | Est. |
|---|---|---|---|---|
| M0 | Spikes (section 12) | Prove or kill the risky bets before building | Pass/fail table filled in | 3 to 4 days |
| M1 | `openpip-core` | Port in this order: `LineBuffer`, `Event`, `AutoHide`, `FrameChange`, `DenyList`, `WindowMatcher`, `CursorMapper`, `CardStack`+`CardLayout`, `SessionLabel`, `SessionState`. Add shared vectors and `Swift`-side vector tests. | All ported tests green on Windows, Linux and macOS runners | 4 to 5 days |
| M2 | App model + render | `openpip-app` model, `openpip-render` card compositor, headless render tests (snapshot PNGs) | Snapshot tests pass | 4 days |
| M3 | Windows MVP | Enumerate, WGC, layered overlay, pipe server, CLI client, hotkey, tray, capture exclusion, settings | Windows manual matrix (section 12) | 8 to 10 days |
| M4 | X11 | Enumerate, Composite+Damage capture, ARGB overlay, Shape, socket server, `XGrabKey` | Xvfb + compositor integration test, then manual on Xfce/KDE/GNOME X11 | 6 to 8 days |
| M5 | Wayland | Layer-shell overlay, portal capture, restore tokens, GNOME fallback, `GlobalShortcuts`, ksni tray | Manual on KDE, GNOME, sway | 10 to 14 days |
| M6 | Session cards | Watcher, scanner, card renderer, Windows path vectors | Real Claude Code logs from Windows render correctly | 3 to 4 days |
| M7 | Packaging + CI + docs | Section 11 | Tagged release produces all artifacts | 5 to 7 days |
| M8 (optional) | Wayland no-dialog capture, compositor IPC adapters (sway, Hyprland) | Section 4.4 | Event hints pick windows on sway | open |

Porting rules for M1:

- Port each Swift test file to the matching Rust test file first, then the code. Names: `auto_hide_tests`, `card_stack_tests`, `cursor_mapper_tests`, `deny_list_tests`, `event_tests`, `frame_change_tests`, `line_buffer_tests`, `session_label_tests`, `session_state_tests`, `window_matcher_tests` (about 100 Swift test functions in total).
- Inject time as a parameter (seconds as `f64` or `Instant`), as the Swift code does with `Date`.
- Keep `FrameFingerprint` the same algorithm (FNV-1a, stride 61). Hash tightly packed rows, not row padding.
- Where Swift behavior is a quirk (a wrongly typed optional field drops the whole line; `v` must be exactly 1), copy it and add a vector.
- Intended deviations, each with its own test: Windows-style paths in `SessionLabel`; `app_ids` and aliases in `WindowMatcher`; `u64` window ids.

---

## 11. Packaging, CI and signing

### Packaging

| Target | Artifact | Notes |
|---|---|---|
| Windows | **Portable zip** with `openpip.exe`, `openpip-post.exe`, `openpip-hook.exe` | First deliverable. Works with Scoop. |
| Windows | **Scoop** manifest in a bucket | Unsigned is fine technically. |
| Windows | **winget** manifest | Zip with a nested portable installer. **[U]** exact schema and whether unsigned binaries pass validation. Check before promising. |
| Windows | MSI via WiX (hand-written) | Later. Avoid `cargo-wix` (last release 2025-03-13). |
| Windows | MSIX | Not in v1. Needs signing to install. Only needed if the unpackaged border call fails. |
| Linux | `.deb` via `cargo-deb` 3.8.0 | Depends on `libpipewire-0.3-0`. |
| Linux | AppImage | Build on an older glibc (ubuntu-22.04 is on the runner list [V]). Do not bundle PipeWire. The host provides it. |
| Linux | Flatpak | Later. Needs `--socket=wayland`, `--socket=fallback-x11`, `--filesystem=~/.claude:ro`, and `--filesystem=xdg-run/openpip` so host agents can reach the socket. **[U]** untested. |
| Linux | Plain tarball + `install.sh` | Always provide. |

Linux runtime caveat: only the Wayland capture path links `libpipewire`. If the binary links it at load time, it will not start on a machine without it. Preferred fix: build the Wayland capture as a **separate small sidecar binary** (`openpip-pwcap`) that the main app starts only when needed. Cost: one more process and a shared-memory frame hand-off. Decide in the spike. The simpler alternative is to declare the dependency in the `.deb` and document it for AppImage.

### CI (GitHub Actions)

Standard runners are free on public repos. Labels checked [V docs.github.com]: `ubuntu-24.04`, `ubuntu-22.04`, `ubuntu-24.04-arm`, `windows-2025`, `windows-2022`, `windows-11-arm`.

| Job | Runner | Does |
|---|---|---|
| `lint` | ubuntu-24.04 | `cargo fmt --check`, `clippy -D warnings`, `cargo deny check` (licenses; **ban network crates** such as `hyper`, `reqwest`, `rustls`, `openssl` to protect "no network code") |
| `test-core` | windows-2025, ubuntu-24.04, macos-latest | `cargo test -p openpip-core -p openpip-app -p openpip-render` |
| `swift-parity` | macos-latest | `swift test` against the shared vectors |
| `build-win` | windows-2025, windows-11-arm | release build, zip, SHA256 |
| `build-linux` | ubuntu-22.04 (glibc floor), ubuntu-24.04-arm | release build, `.deb`, AppImage, tarball. Install `libpipewire-0.3-dev`, `libclang-dev`, `pkg-config` first. |
| `x11-it` | ubuntu-24.04 | `xvfb-run` + a compositor (picom) + a test window; run the X11 capture and overlay integration tests |
| `wayland-it` (later) | ubuntu-24.04 | headless sway for layer-shell and ext capture. The portal path needs a real session, so it stays manual. |
| `win-capture-it` | windows-2025 | Try WGC against a test window. Whether hosted runners have a capturable desktop is **[U]**. If not, run on a local VM and mark this job optional. |
| `release` | tag push | Upload artifacts, SHA256SUMS, GitHub build attestations (optional). |

### Signing and SmartScreen

- **Unsigned:** a downloaded exe or MSI carries the "mark of the web". Windows SmartScreen shows a blue "Windows protected your PC" screen. The user must click More info, then Run anyway. **[K]** A tool that captures other windows and draws an overlay may also be flagged by antivirus heuristics. Expect some false positives. **[U]** how often.
- **Scoop** downloads with its own downloader. It usually leaves no mark-of-the-web, so there is no SmartScreen prompt. **[K]**, test it.
- **Cheapest real fix:** SignPath Foundation offers free OV-level signing for qualifying open-source projects through a managed pipeline [V learn.microsoft.com code-signing-options, signpath.org]. MIT license on `vcspr/openPIP` should qualify, but you must apply and meet their rules.
- **Paid option:** Azure Artifact Signing (formerly Trusted Signing), about $9.99 per month. Individuals only in the USA and Canada; organizations in USA, Canada, EU, UK [V Microsoft Learn]. Even signed, **SmartScreen reputation builds over time and early warnings are expected** [V same page].
- Use the same rule as the macOS build: nothing is signed with a Developer ID (macOS rule). Windows signing: see decision 4 in section 14.
- Linux: no signing needed. Publish `SHA256SUMS`. Optional cosign or GitHub attestations.

---

## 12. Test plan

### Spikes (M0): pass or fail, one page each

| # | Question | Pass means |
|---|---|---|
| S1 | Does `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` work on a layered per-pixel-alpha window on Win10 2004 and Win11? | Panel is absent from a WGC capture of the whole monitor. If it fails, switch to DirectComposition (plan B). |
| S2 | Does an unpackaged exe turn off the WGC border with `IsBorderRequired=false` on Win11? | No yellow frame, no prompt. |
| S3 | Do alpha-0 pixels of a layered window pass clicks through? | Click lands on the app below. |
| S4 | WGC of a covered window, a Chrome window, a UWP app, a video window, a 4K window | Frames update; CPU under target. |
| S5 | X11: Composite+Damage capture of a covered window under GNOME-X11, KDE-X11, Xfce | Pixels correct, damage events arrive. |
| S6 | X11: do `ABOVE` + `STICKY` + `Shape` behave on those three? | Stays on top; empty region passes clicks. |
| S7 | Wayland: layer-shell overlay with input region on KDE and sway | Shows above windows; empty space passes clicks. |
| S8 | Wayland: portal window capture on GNOME and KDE: SHM-only buffers, resize, restore token with a window source | Frames arrive; note whether restore works. |
| S9 | GNOME: XWayland window with `ABOVE` over native Wayland windows | Stays on top. If not, GNOME = manual window only. |
| S10 | `winit`+`softbuffer` prototype vs hand-rolled shells | If the prototype gives alpha, topmost and click-through on Windows and X11, use it for those two and write only the Wayland shell by hand. Otherwise go hand-rolled. |
| S11 | Does `pipewire` crate need to be a sidecar? | Decision recorded. |

### Automated

- **Unit and parity:** ported tests; shared vectors in `testdata/vectors/`, run by Swift and Rust. A vector change must pass in both.
- **Protocol:** round trip through the real pipe or socket with the real `openpip-post`. Malformed lines, 4097-byte lines, `v:2`, wrong types, 32+ clients.
- **Security:** another Windows user cannot open the pipe (two accounts on a VM). Another Linux user cannot connect. A second process cannot take the name.
- **Render snapshots:** session cards and card stacks drawn to PNG and compared with a tolerance.
- **No network:** `cargo deny` bans; run the app under `strace -f -e trace=network` and confirm only `AF_UNIX`. On Windows, check that no outbound connections appear in a firewall-blocked VM.
- **No frames on disk:** `strace -e trace=openat,write` on Linux; Process Monitor on Windows. No file written during mirroring.

### Manual matrix

| Area | Cases |
|---|---|
| Windows | Win10 22H2 (19045) and Win11 24H2; one 100% and one 150% monitor mixed; Notepad covered by another window; minimized target; UWP Calculator; elevated (admin) window **[U]**; Chrome with GPU; borderless fullscreen; second virtual desktop; screenshot tool does not show the panel |
| X11 | Ubuntu GNOME-X11, KDE-X11, Xfce with and without compositor, i3 or similar; workspace switch; HiDPI |
| Wayland | KDE Plasma 6, GNOME on Ubuntu LTS, sway, Hyprland; portal prompt each time vs restored; window closed during mirror |
| Agents | Claude Code hook on Windows with Git Bash and with PowerShell only; Claude Code on WSL posting through `openpip-post.exe`; real session logs on Windows |
| Performance targets (mine) | Hidden: under 1% CPU and under 40 MB. Mirroring 1080p at 15 fps: under 8% of one core. First frame under 500 ms. |
| Reliability | 8 hours mirroring; target window closed; monitor unplugged; sleep and wake; GPU driver reset |

---

## 13. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | **Wayland has no always-on-top for normal apps, and GNOME has no layer-shell.** | GNOME users get no true overlay. | XWayland trick (S9), else manual always-on-top. Ship honest README table. |
| 2 | **Wayland capture needs a user dialog; no enumeration; restore may re-prompt.** | Auto-follow by `app`/`window`/`pid` and the deny list do not work on Wayland. | Named bindings with restore tokens; phase 4 ext protocols on sway-like compositors. |
| 3 | **Panel cannot be hidden from capture on Linux.** | Agents' full-screen screenshots may include the panel and confuse them. | Documented limit; hide-for-30-s control; Windows keeps full protection. |
| 4 | **`WDA_EXCLUDEFROMCAPTURE` on a layered window is unverified; WGC border removal on unpackaged exes is only vendor-comment evidence.** | Windows parity could break at the start. | Spikes S1 and S2 first; plan B DirectComposition; plan C MSIX. |
| 5 | **Unsigned Windows binary: SmartScreen and antivirus flags.** | Bad first impression, lost users. | Scoop first; apply to SignPath Foundation; explain in README. |
| 6 | Three hand-written backends cost more than a toolkit. | Schedule. | Keep backends thin; spike S10 may let `winit` carry Windows and X11. |
| 7 | `libpipewire` dependency and glibc floor. | Binary will not start on some systems. | Sidecar decision (S11); build on ubuntu-22.04. |
| 8 | Log folder encoding on Windows is lossy and partly unverified. | Wrong session labels. | Real-log vectors before M6 exit. |
| 9 | Hook shell differences on Windows (Git Bash vs PowerShell). | Hooks silently fail. | Compiled `.exe` client, full-path install text. |
| 10 | Virtual desktops (Windows) and workspaces (Linux). | Panel or target window vanishes on switch. | Follow-the-user logic on Windows; `STICKY` on X11. Test early. |

---

## 14. Decisions (2026-11-01)

These were open questions. Each now has an answer, so the spec can be built as written. Any of them can be revisited after the spikes in section 12.

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | Order of platforms | **Windows first, then Linux X11, then Wayland.** | Windows gets full parity and has the most users. X11 is close to parity. Wayland needs the most new design (portal picker, no auto-follow). |
| 2 | Minimum Windows | **Windows 11 is the supported target. Windows 10 2004+ runs on a best-effort basis**: not tested in CI, and the yellow capture border stays visible there. | Windows 10 left mainstream support in October 2025 [K]. Supporting 11 only in CI keeps the test matrix small. Not blocking 10 costs nothing, because the APIs exist from 2004. |
| 3 | GNOME on Wayland | **Ship it as a reduced mode.** Windows are picked through the portal dialog. The panel shows a one-time tip to set "Always on Top" from the window menu. The XWayland always-on-top trick is an experimental setting, off by default. | A reduced but honest GNOME mode is better than none. The XWayland trick is untested [U], so it must not be the default. |
| 4 | Windows signing | **Apply to the SignPath Foundation (free code signing for open source).** Until it is approved, ship unsigned builds with clear SmartScreen steps in the README and release notes. No paid certificate for now. | It is free and does not depend on where the maintainer lives. A paid certificate can come later if unsigned installs prove to be a real barrier. |
| 5 | Repo shape | **A `cross/` folder in this repo**, a Rust workspace. The shared test vectors (event lines, session log lines, layout cases) live in one place that both the Swift and the Rust tests read. | One protocol, one set of test vectors, one place to change both. A second repo would let them drift. |
| 6 | Fonts | **System fonts.** Windows: Segoe UI and Cascadia Mono, with Consolas as the fallback. Linux: the fontconfig `sans-serif` and `monospace` defaults. | Keeps the binary small and looks native. Pixel-identical session cards across OSes are not a goal. |
| 7 | open-computer-use and OpenBot on Windows/Linux | **Session cards for Claude Code ship on every OS.** The OpenBot name lookup and the open-computer-use hook paths ship **off by default**, behind a setting with a configurable path. They turn on only once those tools are confirmed on that OS. | Claude Code runs on Windows and Linux, so session cards are useful at once. Whether OpenBot and open-computer-use run there is unverified [U]. |
| 8 | WSL | **Not in v1. Planned for v2:** read `\\wsl.localhost\<distro>\home\<user>\.claude\projects` and ship an `openpip-post.exe` that WSL can call. | It adds path and permission edge cases. Native Windows Claude Code comes first. |
| 9 | Launch at login | **Yes, as a setting, off by default.** Windows: the per-user `Run` registry key. Linux: an XDG autostart `.desktop` file. | Users who want it can turn it on. Writing autostart entries without asking would surprise people. |
| 10 | Protocol changes | **Frozen for v1.** Later additions may only be optional fields, such as `hwnd` or `windowId` for exact window targeting. Old clients keep working, because unknown fields are already ignored. | Existing hooks and clients must work unchanged on every OS. |
| 11 | Flatpak / Flathub | **Not in v1.** Linux ships as an AppImage and a `.deb` first. Flatpak is reconsidered after v1. | The sandbox needs extra holes (the socket, `~/.claude`, X11 or portal access). That is work with little gain for a first release. |

---

## 15. Verification log

| Claim | Status | Source |
|---|---|---|
| `CreateForWindow` needs Windows 10 1903 (18362) | V | learn.microsoft.com IGraphicsCaptureItemInterop::CreateForWindow |
| `WDA_EXCLUDEFROMCAPTURE` needs Win10 2004; DWM on; own process; older builds act as `WDA_MONITOR` | V | learn.microsoft.com SetWindowDisplayAffinity |
| `IsBorderRequired` from build 20348; docs require consent + manifest capability | V | learn.microsoft.com IsBorderRequired |
| Unpackaged Win32 app can set `IsBorderRequired=false` without `RequestAccessAsync` | V (vendor comment, not tested) | issues.webrtc.org/issues/42225786; OBS ideas post |
| Default named-pipe DACL gives Everyone read | V | learn.microsoft.com Named Pipe Security and Access Rights |
| ScreenCast portal v6: types, persist_mode, restore_token (single use), cursor modes, pipewire-serial | V | flatpak.github.io/xdg-desktop-portal |
| Layer-shell support list (KWin yes, Mutter no, Weston no) | V | wayland.app/protocols/wlr-layer-shell-unstable-v1 (fetched 2026-11-01) |
| ext capture support list | V (table may lag releases) | wayland.app/protocols/ext-image-capture-source-v1 |
| `wayland-protocols` 0.32.13 has `ext::{image_capture_source, image_copy_capture, foreign_toplevel_list}`, features `staging`, `unstable` | V | docs.rs, crates.io |
| `winit` 0.30.13: `WindowLevel` unsupported on Wayland; `set_cursor_hittest` supported on desktop OSes | V | docs.rs |
| Claude Code hook shell: `sh -c`, Git Bash on Windows, PowerShell if no Git Bash | V | code.claude.com/docs/en/hooks |
| `CLAUDE_CONFIG_DIR` overrides `~/.claude` | V | code.claude.com/docs/en/env-vars |
| Windows project folder `C:\git\cc-plus` becomes `C--git-cc-plus` | V (one report, Claude Code 2.1.11) | github.com/anthropics/claude-code/issues/18829 |
| Electron `setContentProtection` is macOS and Windows only; Linux click-through works on X11 and Wayland; Electron 43 X11 regression fixed in 43.7.6 | V | electronjs.org, github.com/electron/electron/issues/52456 |
| `global-hotkey`: Linux X11 only | V | project README |
| GitHub runner labels incl. `windows-11-arm`, `ubuntu-24.04-arm` free on public repos | V | docs.github.com, github.blog changelog |
| Azure Artifact Signing ~$9.99/mo, individuals USA/Canada; SignPath Foundation free OSS signing; reputation still builds over time | V | learn.microsoft.com code-signing-options, signpath.org |
| Crate versions and dates in section 8 | V | crates.io API, 2026-11-01 |
| GNOME `GlobalShortcuts`: added in 48, reported broken on 49 | Partly V (forum/issue reports) | discourse.gnome.org, github.com/cjpais/Handy/issues/1236 |
| Qt `QWindowCapture` needs FFmpeg backend; has X11 limits | V (search excerpt); Wayland status U | doc.qt.io |
| Tauri has `setContentProtected` and `setIgnoreCursorEvents` | V (existence); Linux behavior U | v2.tauri.app |
| Covered-window capture by WGC; alpha-0 click pass-through; Windows 10 1803 `AF_UNIX`; std file sharing on Windows; GNOME needs tray extension | K | not re-checked |
| XWayland `ABOVE` on GNOME; SHM-only PipeWire on GNOME/KDE; window restore tokens on GNOME; UWP via ApplicationFrameHost; elevated windows; virtual desktop follow; `MinUpdateInterval` build number; interprocess + security descriptor; MSRV; licenses | U | needs the spikes |
