# D · Platform feasibility of the audit's proposals

Date: 2026-10-30. Checks `docs/ui-audit/README.md` sections 4, 5 and 6, and `06-visual-polish-and-native.md` section 8, against Apple's documentation, the macOS 27.0 SDK in the installed Xcode, the repo and the existing renders. Nothing was built, launched or changed apart from this file.

**Evidence labels**

| Label | Means |
|---|---|
| **Docs** | Verified from Apple documentation, HIG or Apple Support. URL given |
| **Code** | Verified from code: this repo, the macOS 27 SDK headers and `.swiftinterface`, Xcode's bundled data, or a render in `.build/.../ui-verify/latest/png` |
| **Unverified** | Not established. Includes Apple engineers' forum replies, which are useful but are not documentation. URL given where there is one |

## 1. Summary

| # | Proposal | Verdict |
|---|---|---|
| 1a | Sidebar Settings window | **KEEP**, with the fixes in section 3 |
| 1b | Keep the `Settings` scene | **KEEP**. `Window` is the named fallback if the first build fails the three checks |
| 1c | "Add `.resizable` to the style mask on appear" | **DROP** |
| 1d | "Toolbar tabs are the older convention" | **REVISE**: the HIG still describes toolbar panes |
| 1e | "Minimize, zoom: as the scene gives them" | **REVISE** |
| 1f | Deep link receiver at the root | **REVISE**: a root receiver still misses a window that isn't open yet |
| 2a | System notifications at time-sensitive level | **REVISE**: needs an entitlement, and it does not cover sharing |
| 2b | `requestUserAttention` | **DROP** |
| 2c | Floating alert panel | **REVISE**: reaches a full-screen meeting only with Ultracam in its accessory state |
| 3a | Background shortcuts with `RegisterEventHotKey` | **KEEP** |
| 3b | `NSEvent.addGlobalMonitorForEvents`, event taps | **DROP** |
| 3c | Global Record as a toggle | **REVISE**: start only |
| 4a | Auto as a split button | **REVISE**: Toggle plus chevron Menu, since a `Menu` has no on state |
| 4b | Record as a split button | **REVISE**: Button plus chevron Menu, to keep the red dot |
| 4c | Red dots, not red fills | **KEEP** |
| 4d | Hold appears when Auto is on | **REVISE**: fixed slot |
| 4e | Toolbar groups, overflow and 980 pt | **REVISE** |
| 5a | Selection ring fixed blue | **KEEP** |
| 5b | Segmented divider claim | **KEEP** |
| 6 | `.focusable(!compact, interactions: .activate)` | **KEEP**, with wording and key handling corrected |
| 7 | Keep on Top for detached monitors | **REVISE** |
| 8 | Others | Section 10 |

Facts that correct the brief or the audit:

- **The menu bar item is an `NSStatusItem` with an `NSMenu`, not a `MenuBarExtra`** (`UIMenuBar.swift:62-65`). Code.
- **Distribution is outside the store.** `App.entitlements` has `temporary-exception.*` and `cs.disable-library-validation`, and the docs and scripts never name the Mac App Store. The installed app is signed Apple Development with an Xcode-managed team profile on a paid team, and `scripts/build.sh --signed` passes `-allowProvisioningUpdates` (`build.sh:85`). Notarization is called a separate distribution step (`docs/SDK_RELEASE_EVIDENCE.md:50`), and no script runs it. Code.
- **Ultracam changes activation policy at runtime.** It is `.regular` while any titled window is open, even with "Menu bar when closed" on. It is `.accessory` only with that setting on and every window closed (`UIAppEnvironment.swift:21-32`). Code. Sections 5 and 8 depend on this.

## 2. Evidence on the Settings window

**HIG.** Settings on macOS "typically" uses a toolbar of panes. It should be noncustomizable and show the active pane, the title should follow the pane, minimize and maximize should be dimmed, and the last pane should be restored. The page does not mention sidebars. Docs: https://developer.apple.com/design/human-interface-guidelines/settings

So the sidebar is a deliberate deviation. Its precedent is System Settings, not the HIG.

**Scene sizing.** "With that strategy, `Settings` windows use the `contentSize` strategy", and Apple's example makes a window resizable by giving its content a min and max frame. Docs: https://developer.apple.com/documentation/swiftui/windowresizability

So `.windowResizability(.contentSize)` is already the default for `Settings`, and a range on the root frame is the documented way to allow height resizing. Whether `Settings` honours it with a split view on macOS 27 has no direct source. Unverified.

**`NavigationSplitView` in `Settings`.** Apple documents `TabView` or a single view there, and says nothing for or against a split view. Docs: https://developer.apple.com/documentation/swiftui/settings

The two forum threads found do not block this:
- https://developer.apple.com/forums/thread/719906 is a split view nested in a Settings `TabView` tab. No replies.
- https://developer.apple.com/forums/thread/836901 needs `.inspector`, which Settings won't have. See section 10 for why it matters to the main window.

**Toolbar style.** `NSWindowToolbarStylePreference` is "For Settings windows only", with items of equal width (`NSWindow.h:239`). Code. What the scene picks when a split view supplies the toolbar is unknown. Unverified.

## 3. Settings: decision

**KEEP the sidebar and the `Settings` scene.** `openSettings`, the app menu item and ⌘, already work, and the activation path below is already the known workaround. Replacing the scene now would remove working code to solve a problem nobody has observed.

**Replace 06 section 8 "Sizing" with:**

```swift
Settings {
  UISettingsRoot(model: model, interface: interface)
    .frame(width: 820)
    .frame(minHeight: 460, idealHeight: 620, maxHeight: .infinity)
    .windowMinimizeBehavior(.disabled)
    .windowFullScreenBehavior(.disabled)
}
```

- Delete the sentence "if it doesn't, add `.resizable` to the style mask on appear". The documented route is the frame range. Reaching into the scene's window is a hack, and a failure here goes to the fallback instead.
- `.windowResizability(.contentSize)` is redundant. Leave it out.
- `windowMinimizeBehavior` and `windowFullScreenBehavior` are `View` modifiers from macOS 15 (`SwiftUI.swiftinterface:5631,5635`). Code. Whether the `Settings` scene honours them is Unverified, and is part of live check 8.
- **Zoom stays enabled.** The HIG's reason for dimming it is that the window "accommodates the size of the current pane". This window doesn't, so green-button zoom to full height is useful. Minimize and full screen go.

**Replace the "Why not toolbar tabs" opening with:** "Toolbar panes are what the HIG describes, and Safari carries about ten. We deviate, as System Settings does, because …" The reasons that follow stand.

**Sidebar table.**
- `.toolbar(removing: .sidebarToggle)` exists from macOS 14 (`swiftinterface:22851`). Code. It removes the button only. The app doesn't use `SidebarCommands`, and its ⌃⌘S drives the main window. To stop any collapse, use `NavigationSplitView(columnVisibility: .constant(.all))`. Whether a user can still drag the column shut is Unverified.
- `.navigationTitle` per section satisfies the HIG's title rule, and `@AppStorage("settings.section")` satisfies its last-pane rule. KEEP both.

**Deep links: replace the 06 paragraph with this.** Moving the receiver to the root is not enough. `UICommands.swift:146-147` calls `openSettings` and posts `UIShowRecovery` straight after, so with Settings closed there may be no view yet to receive it. Apple's documented pattern writes the stored selection first, then calls `openSettings`. Docs: https://developer.apple.com/documentation/swiftui/opensettingsaction

```swift
Button("Recover Interrupted Takes…") {
  settingsSection = "recording"       // @AppStorage shared with the sidebar
  interface.pendingSettingsSheet = .recovery  // read by the root in .onAppear and .onChange
  send(.openSettings)
}
```

README section 6 also moves Crash Recovery out of Settings to Attention. If that lands first, this deep link goes away and Attention presents the recovery sheet itself.

**Menu bar and activation.** `showSettings()` (`UIMenuBar.swift:92-97`) sets `.regular`, opens, then activates.
- That is the community workaround. An Apple DTS reply says the stricter activation is intended and suggests `openWindow` and `activate()`. Reports there and elsewhere say `activate()` can fail for accessory apps while the deprecated call works. Unverified: https://developer.apple.com/forums/thread/836619
- **KEEP** `activate(ignoringOtherApps:)`. It is `API_TO_BE_DEPRECATED` (`NSApplication.h:222`), so it raises no warning under warnings-as-errors. Code.
- **Delete** the `showSettingsWindow:` branch at `UIMenuBar.swift:95`. `UISelfTest.swift:212-213` already records it as a no-op on current macOS. Code.
- **Does Settings come forward from the accessory state?** The order is right, so it should, but no source can promise it. One developer reports failures 20% of the time with `activate()`, which is the call Ultracam avoids: https://developer.apple.com/forums/thread/832795. Unverified. It is in section 11.

**Fallback.** Use it if the first build fails any of these:
1. The sidebar runs the full window height.
2. The window resizes in height, and only in height.
3. The title follows the section.

```swift
Window("Settings", id: "settings") { UISettingsRoot(model: model, interface: interface) }
  .windowResizability(.contentSize)
  .windowToolbarStyle(.unified)
  .defaultSize(width: 820, height: 620)
  .restorationBehavior(.disabled)
  .commandsRemoved()

CommandGroup(replacing: .appSettings) {
  Button("Settings…") { send(.openSettings) }.keyboardShortcut(",")
}
```

| With the fallback | Effect |
|---|---|
| `openSettings` | Becomes `openWindow("settings")`, which brings an open window forward. Docs: https://developer.apple.com/documentation/swiftui/window |
| Menu bar | `UIMenuBarController.open(windowID:)` already handles it. `showSettings()` and `UIAppEnvironment.openSettings` go |
| Window menu | `.commandsRemoved()` keeps it off the automatic list |
| Dock logic | `hasOpenWindow` counts it. Code |
| Self-test | `UISelfTest.swift:212-216` finds the ⌘, item, so it still passes |
| `.restorationBehavior(.disabled)` | Stops it reopening at launch (`swiftinterface:279`) |

## 4. Notifications

**Does `UNUserNotificationCenter` work here?** Yes, macOS 10.14 and later, with no sandbox caveat stated. Docs: https://developer.apple.com/documentation/usernotifications/unusernotificationcenter

**Time-sensitive level.**

| Question | Answer |
|---|---|
| Exists on macOS? | macOS 12 and later. Docs: https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel |
| What does it promise? | "Breaks through system notification controls". The SDK header is softer: "**May** be presented during Do Not Disturb" (`UNNotificationContent.h:27`). Code |
| Needs the entitlement? | Yes. `com.apple.developer.usernotifications.time-sensitive`, `isRequiredInPlist: true`. Xcode's `DVTPortalCachedPortalCapabilities.json` lists `MAC_OS`, product type application, and Development and Developer ID distribution. `canRequestFromPortal: false`, so there is no approval form. Code. See also https://developer.apple.com/videos/play/wwdc2021/10091/ |
| Available with this signing? | Yes for the signed build. Tick it in Signing & Capabilities, and `build.sh --signed` refreshes the profile. The current profile doesn't have it. Code |
| What without it? | No macOS documentation. Unverified. Assume it behaves as `.active` |
| Does it pass a Focus? | Only if **both** switches are on: Focus › Allowed Apps › Time Sensitive Notifications, and the app's option in Notifications settings. Docs: https://support.apple.com/guide/mac-help/set-up-a-focus-to-stay-on-task-mchl613dc43f/mac |
| Does it really pass on macOS? | **Unverified.** A developer reports it doesn't, and Apple's only reply there asks questions: https://developer.apple.com/forums/thread/763277 |

**The trap in the ad-hoc build.** `prepare_local_build.py:108` re-signs with `App.entitlements` and pops only `keychain-access-groups`. A new `com.apple.developer.*` key would go into a build with no profile. Add the same `pop` there.

**Full screen.** Nothing documented says banners are held back over a full-screen app. Unverified. README section 12 item 4 stays.

**Mirroring or sharing.** This is the real gap.
- macOS has a setting for "mirroring or sharing": "Notifications Off" or "Allow Notifications". Apple describes it as pausing notifications so others can't see them. Docs: https://support.apple.com/guide/mac-help/change-notifications-settings-on-mac-mchl205da693/mac and https://support.apple.com/guide/mac-help/notifications-settings-mh40583/15.0/mac/15.0
- That page gives no default. Whether a Zoom share counts as "sharing" and whether time-sensitive passes it are both Unverified.
- Zoom has its own "Silence system notifications when sharing desktop", per third-party guides. Unverified: https://www.howtogeek.com/714118/how-to-hide-notifications-while-sharing-your-screen-in-a-video-call/
- **So assume notifications may not reach the operator while sharing a display.** That is a large share of the moments that matter. Do not design as if they will.
- **If one is delivered on a shared display, viewers see it.** Treat the text as public. "Camera 1 stopped" is fine. Drive names, paths and take names are not.

**`NSApp.requestUserAttention`: DROP.** It does nothing when the app is active. Docs: https://developer.apple.com/documentation/appkit/nsapplication/requestuserattention(_:). It only bounces a Dock icon, which doesn't exist in the accessory state and isn't on screen during a full-screen meeting. It adds no reach.

## 5. The floating alert panel

**What was proposed:** an `NSPanel` over full-screen spaces with `.canJoinAllSpaces` and `.fullScreenAuxiliary`.

**That combination is not enough.** An accepted Apple DTS reply, tested on macOS 26, says three things. Unverified, as a forum reply: https://developer.apple.com/forums/thread/826308
- "macOS doesn't layer regular foreground apps above other apps' full-screen Spaces." It needs the accessory policy.
- An `NSWindow` "activates its app when ordered front, which can cause a full-screen app to exit its Space". It needs an `NSPanel` with `.nonactivatingPanel`.
- "`.floating` (3) and `.statusBar` (25) both sit below full-screen content." It needs `.screenSaver`.

The header backs part of this: `canJoinAllApplications` lets a window "join other apps' sets and full screen spaces when eligible" (`NSWindow.h:98`). Code. "When eligible" is undocumented. A regular app with a non-activating panel is not stated either way, so that one case stays open.

**What this means for Ultracam.** The panel reaches a full-screen meeting when Ultracam is `.accessory`: "Menu bar when closed" on, every window closed. That is README's "app hidden" case, where nothing else in the app can be seen. With a window open the app is `.regular`, and the panel should be assumed not to appear over a full-screen meeting. It still appears on ordinary desktops and on other displays.

`hasOpenWindow` excludes `NSPanel` (`UIAppEnvironment.swift:31`), so showing the panel won't flip the policy back. Code.

**Do not** make Ultracam accessory while its windows are open. That breaks the rule at `UIAppEnvironment.swift:17`, and a reported side effect of switching back is the window dropping behind (thread 836619). **Do not** add a separate helper app: the cost isn't justified before the live test.

```swift
let panel = NSPanel(contentRect: frame,
  styleMask: [.nonactivatingPanel, .titled, .closable],
  backing: .buffered, defer: false)
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false      // an NSPanel hides on deactivate by default
panel.becomesKeyOnlyIfNeeded = true
panel.level = .screenSaver
panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
panel.sharingType = .none            // best effort only, see below
panel.orderFrontRegardless()         // never NSApp.activate
```

The behaviours respect the header's "at most one" groups (`NSWindow.h:94,104,115`). Code.

**Exposure on a shared display.** `sharingType = .none` means contents "may not be read by another process" (`NSWindow.h:83`). Code. Developers report ScreenCaptureKit ignoring it from macOS 15.4. Unverified: https://developer.apple.com/forums/thread/808016 and https://origin-devforums.apple.com/forums/profile/cxp198108. So the panel may be visible to viewers, and unlike notifications no OS setting silences it. The same header warns that such a window "will also not be able to participate in a number of system services, so this setting should be used with caution" (`NSWindow.h:520`). Code. A small alert panel needs none of those services, so keep the line, but treat the text as public and don't promise the operator it is hidden.

## 6. Alerts: the mix

| Channel | Events | Reaches | Misses |
|---|---|---|---|
| Attention list, status bar | All | Ultracam visible | Ultracam hidden |
| Menu bar icon and rows | All | Menu bar visible | Full-screen meetings, where it hides (02 F02) |
| `UNNotification`, `.timeSensitive` while live, otherwise `.active` | README's five events | Most cases | Sharing, Focus without both switches. Banners time out unless the user picks Alerts style |
| Non-activating panel | Three worst: on-air camera lost, take ended early, camera stopped while on air | Accessory state over full screen; any ordinary desktop | Full-screen meeting with an Ultracam window open (assumed) |

**Replace the README section 4 "System notifications" bullet with:**

> **System notifications** for: camera stopped unexpectedly, take ended early, recording with no signal, on-air camera lost, drive low or full. Time-sensitive when a camera is on air or rolling, active otherwise, using the Time Sensitive Notifications capability. Sound off by default. Text is meeting-safe: camera name and state only, because it may appear on a shared display. Set the delegate in `applicationDidFinishLaunching`. From `willPresent`, return `[.list]` when the main window is key, because Attention already shows it, and `[.banner, .list]` otherwise. One request identifier per problem, so a repeat replaces it, and remove the delivered notification when the problem clears. Clicking opens the main window through the menu bar bridge, which restores the Dock state.
>
> **Alert panel** for on-air camera lost, take ended early and camera stopped while on air: a small non-activating panel, on by default, with Settings › Alerts to turn it off. It never activates Ultracam, so it can't pull a meeting out of full screen. It reaches a full-screen meeting when Ultracam's windows are closed in "Menu bar when closed". Help says so.

Supporting details:

- **Delegate timing.** "You must assign your delegate object … before your app finishes launching." Docs: https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate. Apple's example assigns it in `didFinishLaunching`, so `AppDelegate`'s existing method is enough.
- **Foreground.** With a delegate lacking `willPresent`, foreground notifications are silenced. Docs: https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate/usernotificationcenter(_:willpresent:withcompletionhandler:)
- **Permission.** Request it in context, not at launch. Docs: https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications. Use a "Turn On Alerts" button in Settings › Alerts, plus one Attention row before a session while no camera is on air. Never prompt while on air or rolling. No `.provisional`: those deliver quietly to Notification Center only.
- **Alerts pane.** Show real state: `authorizationStatus`, `timeSensitiveSetting`, `alertStyle`. The HIG requires in-app control. Docs: https://developer.apple.com/design/human-interface-guidelines/managing-notifications. Add `.providesAppNotificationSettings` so System Settings links back (`UNUserNotificationCenter.h:28`). Code.
- **Banner or Alerts style** is the user's choice in System Settings: https://developer.apple.com/documentation/usernotifications/unnotificationsettings/alertstyle. `NSUserNotificationAlertStyle` belongs to the old API and its effect is Unverified, so don't rely on it. Recommend the Alerts style in Help.
- **Drive low** counts as time-sensitive only during a take. The HIG reserves the level for what is relevant now. Docs: same HIG page.
- **Test harnesses.** Keep `UNUserNotificationCenter.current()` out of `AppModel.init`, since harnesses compile every app source (`UIAppEnvironment.swift:4-5`). Whether it throws without a bundle is Unverified.

## 7. Background shortcuts

**KEEP `RegisterEventHotKey` (Carbon).**

- Declared in `CarbonEvents.h:15484`, available since 10.0, no deprecation macro, in the 27.0 SDK. Code. Apple documents no modern replacement. The SwiftUI interface has no global shortcut API. Code.
- It delivers to an inactive app, so a meeting stays frontmost. No Accessibility prompt and works in a sandbox: Unverified from Apple, but `KeyboardShortcuts` is built on it and states "fully sandboxed and Mac App Store compatible", with no permission dialogs: https://github.com/sindresorhus/KeyboardShortcuts
- Use a small wrapper of our own, about 80 lines. The feature needs fixed combinations and on or off, not a recorder, so it doesn't justify a dependency.

**DROP** `NSEvent.addGlobalMonitorForEvents`. Key events need Accessibility trust, and a monitor "cannot modify or otherwise prevent" delivery, so Zoom would get the keystroke too (`NSEvent.h:544`). Code. **DROP** event taps for the same permission.

**Key combinations.**
- Every registration needs a modifier other than Shift or Option. An Apple engineer called this intentional in Sequoia: https://developer.apple.com/forums/thread/763878?page=2. A later report says 15.2 reversed it for sandboxed apps: https://blog.eternalstorms.at/2024/09/23/keyboard-shortcuts-using-option-and-or-shift-modifiers-only-no-longer-allowed-on-macos-sequoia/. Both Unverified on 27, and it doesn't matter if we always include ⌃ or ⌘.
- **Defaults:** ⌃⌥⌘1 to ⌃⌥⌘7 for cuts, ⌃⌥⌘A Auto, ⌃⌥⌘H Hold, ⌃⌥⌘R Record. Skip 8, which macOS has used for invert colors. Unverified on 27.
- This confirms the audit's "not ⌃1 to ⌃4". It also extends the app's own ⌃digit cut, so it is easy to remember.
- Register with `kEventHotKeyExclusive`. It stops other apps' non-exclusive registrations of the same chord from firing (`CarbonEvents.h:15405-15410`), which is deliberate: a cut must not also trigger something else mid-meeting. `eventHotKeyExistsErr` reveals another exclusive holder (`CarbonEvents.h:15473`). Code. Show "In use" on that row. Clashes with system shortcuts are not reported. Unverified.

**Off by default, per group, in Settings › Alerts.** KEEP as proposed.

**Global Record starts only (REVISE).** `.toggleRecordingSelected` and `.stopAllRecordings` have no confirmation (`UIAction.swift:107-127`), so a stray chord would end a take. Bind `.recordAll`, and make it a no-op while anything rolls. Never bind anything that reaches `send`'s `NSAlert` path, which calls `activate(ignoringOtherApps:)` (`UISessionBridge.swift:274`) and would pull the operator out of the meeting. Code.

**Hardware.** A Stream Deck hotkey button sends these same combinations, so it needs no Ultracam work (Unverified, but standard behaviour). MIDI isn't in the brief: skip it.

## 8. Toolbar

**Split buttons exist.** `Menu(content:label:primaryAction:)` is available from macOS 12 (`swiftinterface:9014-9017`). Code. A body click runs the primary action and the menu opens "on long press or on click of the menu indicator". Docs: https://developer.apple.com/documentation/swiftui/menu. AppKit's `NSMenuToolbarItem` shows an arrow when it has an action (`NSMenuToolbarItem.h:18-20`). Code.

**But `Menu` doesn't fit either control as specified.**

- **Auto has an on state.** `Menu` has no selected appearance, while today's `Toggle(.button)` does, as the wand in the render shows. Losing it would hide whether Auto is on. Code.
- **Record needs a red dot that survives a non-key window.** The repo already has a live case of a macOS `Menu` label losing its styling (06 V14, `UIFeedSettingsMenu.swift:36-44`). A `Circle()` inside a `Menu` label is therefore not safe. Whether a toolbar `Menu` keeps it is Unverified. A `Button` label does (`UICutButtonLabel`). Code.

**REVISE both to the same recipe.** It keeps the existing labels and sits on one glass capsule:

```swift
ToolbarItemGroup(placement: .principal) {
  // cut buttons …
  Toggle(isOn: autoBinding) { Label("Auto", systemImage: "wand.and.sparkles") }
    .toggleStyle(.button)
  Menu { strategyAnchorEmphasis } label: { Image(systemName: "chevron.down") }
    .menuIndicator(.hidden)
    .accessibilityLabel("Auto options")
  Button("Hold") { … }.disabled(!autoOn)
}
```

Use `Button` plus the same chevron `Menu` for Record, keeping `UICutButtonLabel`-style content. Keep the Manual branch at `UIToolbar.swift:119-129`, as a plain `Menu`.

**`.borderedProminent` goes gray: confirmed.** In `main-program-meeting-1320-dark`, gray traffic lights mark a non-key window. Stop All and the on-air cut, both `.borderedProminent.tint(.red)` in code, are gray capsules, and only the `Circle()` is red. Code (one render, offscreen, macOS 27). The HIG confirms that appearances change by window state, but not this detail. Docs: https://developer.apple.com/design/human-interface-guidelines/windows. **KEEP** "Red dots, not red fills". Use `Circle()` views, not SF Symbols.

**Glass grouping.** `ToolbarItemGroup` shares one capsule and `ToolbarSpacer(.fixed)` splits them, as the render shows. Code. The HIG says to aim for three groups at most, and to keep text actions apart from symbol actions. Docs: https://developer.apple.com/design/human-interface-guidelines/toolbars

**REVISE README's toolbar line to three groups:** `[1 Camera 1] [2 Camera 2] [Auto ⌄] [Hold]` · `[Start Cameras, only when needed]` `[● Stop 2 Recordings ⌄]` · `[layouts] [inspector]`.

**Hold in a fixed slot (REVISE).** "Appears beside Auto when Auto is on" re-centres the principal group and moves the cut buttons under the pointer. That contradicts the "nothing moves under the pointer" rule in the same section. Keep Hold always present and disabled while Auto is off.

**Overflow at 980 pt.**

- `main-program-meeting-980-dark` shows layouts, collapse and inspector all in `>>`, with cuts and Record kept. The later `.primaryAction` groups went first, as `UIToolbar.swift:18-22` says. Code. This differs from the HIG's "items on the trailing edge remain visible at all window sizes".
- **`.visibilityPriority` exists but needs a guard.** It is macOS 26.1 and the target is 26.0 (`swiftinterface:13394-13396`, `MACOSX_DEPLOYMENT_TARGET = 26.0`). Unguarded, it won't compile. Code. `ToolbarContentBuilder` accepts `if #available` (`buildLimitedAvailability`, macOS 14.5). Code. Apple: "items with a lower priority move first". Docs: https://developer.apple.com/documentation/swiftui/toolbaritemvisibilitypriority

```swift
if #available(macOS 26.1, *) {
  recordGroup.visibilityPriority(.high)
  layoutGroup.visibilityPriority(.low)
} else {
  recordGroup
  layoutGroup
}
```

- **Do not use `ViewThatFits` for "number only under 1100 pt" (06 V17).** There's no documented width proposal for toolbar items. Unverified. Read the window width with `onGeometryChange` in `UIMainWindowView`, and pass a compact flag to the toolbar. It is deterministic and can be tested in renders.
- Every toolbar item needs a menu command, since the toolbar may overflow. Docs: same HIG page. Check the Auto menu's Strategy, Anchor and Emphasis exist in the Program menu.

## 9. Selection ring, divider, focus, detached monitors

**Fixed blue: KEEP.** An app accent applies only while the user's setting is multicolor. Any other choice replaces it, with one exception for fixed-color sidebar icons, because they carry meaning. Docs: https://developer.apple.com/design/human-interface-guidelines/color. Defining `AccentColor` would not protect the ring, so `Color.blue` is the right fix. The audit's accent check on Graphite and Red still applies.

**Segmented divider: KEEP the claim.** In the crop of `main-program-meeting-1320-dark`, Side by Side is selected, no line sits on either side of it, and the only line falls between Program View and Four Up. That matches 06. Code (render, one state). Apple doesn't document it, so read it as observed drawing, not a guarantee.

**`.focusable(!compact, interactions: .activate)`: KEEP.**

- The signature exists from macOS 14 (`swiftinterface:29371`). Code.
- Apple: "on macOS and iOS it is conventional for button-like views to only accept focus when the user has enabled keyboard navigation system-wide … Clients can reproduce this behavior with custom views by only supporting `.activate` interactions." Since macOS 14, custom views "will always be focusable" otherwise. Docs: https://developer.apple.com/documentation/swiftui/view/focusable(_:interactions:)
- That is exactly V7's cause and fix.
- **Wording.** Replace "only Full Keyboard Access does" with "only when Keyboard navigation is on in System Settings". Those are different settings.
- **Key handling.** Space and Return don't select by themselves: `.onTapGesture` isn't a keyboard action. Add `.onKeyPress(keys: [.space, .return])` and `.accessibilityAddTraits(.isButton)`. Whether `onKeyPress` needs the `.edit` interaction is Unverified, so check it with Keyboard navigation on. Nothing in `Sources/App` uses `onKeyPress` or `onMoveCommand` today, so no key handling is lost by restricting focus. Code.

**Keep on Top: REVISE (02 F33).** Replace with:

> **Keep on Top** floats a detached monitor over other apps' windows, for second-display use and windowed meetings. It does not float over a full-screen meeting on the same display: macOS doesn't layer a regular app above another app's full-screen Space. Use the meeting app windowed, or put the monitor on another display.

```swift
func setKeepOnTop(_ on: Bool) {
  window.level = on ? .floating : .normal
  window.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
}
```

- Set it on the existing `NSWindow` in `MonitorDetachedWindows.open` (`MonitorWorkspaceView.swift:369`). Code.
- It must stay a titled `NSWindow` in a `.regular` app. The accessory-and-panel recipe in section 5 doesn't apply: the main window is open, and a monitor in a borderless panel loses its window controls.
- Clear the behaviour when off. `.fullScreenAuxiliary` excludes `.fullScreenPrimary` (`NSWindow.h:115`), so leaving it set would change the green button. Code.
- SwiftUI's `windowLevel(.floating)` is a scene modifier (macOS 15). It can't reach these AppKit windows. Code.
- With "Displays have separate Spaces" on, a full-screen meeting on display 1 leaves display 2 alone, so second-display use needs no special case. Unverified.

## 10. Other things that won't work as written

| Item | Problem | Change |
|---|---|---|
| **Main window on macOS 27** (not in the audit) | `NavigationSplitView` plus `.inspector`, which `UIMainWindow.swift:24,44` uses, is reported on macOS 27.0 release builds to make the sidebar jump on resize, and to crash when the splitter is dragged fully right. No fix. Unverified: https://developer.apple.com/forums/thread/836901 | Try both on the rig before phase 3. Limiting `navigationSplitViewColumnWidth` (already `max: 300`) may be why it hasn't bitten. Don't widen that range |
| **Cut in a non-key window** (not in the audit) | With a meeting frontmost, whether the first click on a Cut button acts or only activates the window isn't known. `allowsWindowActivationEvents` exists from macOS 15 for this. Docs: https://developer.apple.com/documentation/swiftui/view/allowswindowactivationevents(_:) | Add `.allowsWindowActivationEvents()` to Cut buttons only, so one click cuts. Not to Stop controls. Measure in the live test |
| **Status item as way back** | Users can hide menu bar items, so "Menu bar when closed" could strand the app. Unverified on 27 | `applicationShouldHandleReopen` already handles a relaunch. Add one line in Help |
| README section 12 item 4 | Tests full screen only | Section 11 |

**Holds up as written:** the placement rule, session board, strip rows, inspector order, status bar order, menu bar's 14 rows, `Label` sidebar rows, `Form` and `.formStyle(.grouped)`, `.scrollBounceBehavior(.basedOnSize)`, and the row kinds and help-text rules in 06 section 8. None depends on behaviour that macOS blocks.

## 11. Live checks

Replaces README section 12 item 4. All need a signed build with the capability, when Ultracam isn't serving a meeting.

| # | Check | Decides |
|---|---|---|
| 1 | Full-screen Zoom, Ultracam window open and hidden: time-sensitive notification | Whether notifications reach the commonest case |
| 2 | Share entire screen in Zoom, both values of the macOS mirroring setting and of Zoom's silence setting: does it appear, and do viewers see it? | Section 4 unknowns |
| 3 | Do Not Disturb with Time Sensitive on and off | Whether macOS honours the level at all |
| 4 | Panel over full-screen Zoom, accessory state | Section 5 recipe on macOS 27 |
| 5 | Panel over full-screen Zoom, `.regular`, window open | The one open case. If it works, drop the limit from Help |
| 6 | Panel in a shared display, `sharingType = .none`: do viewers see it? | Exposure |
| 7 | Settings from the menu bar item, accessory state, 20 times | Section 3 reliability |
| 8 | Sidebar, height range, title, minimize and full-screen disabled, in `Settings` | Scene or fallback |
| 9 | ⌃⌥⌘ hotkeys with Zoom frontmost, no Accessibility grant | Section 7 |
| 10 | Click Cut with Zoom key | Section 10 |
