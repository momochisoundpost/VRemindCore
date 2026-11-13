# Porting Guide (Linux, Windows, CLI & Other Desktop Environments)

`VRemindCore` is deliberately isolated from macOS frameworks so you can run the monitoring engine on any OS supported by Swift, embed it in terminal daemons or bots, or use it as a reference architecture for native toolkits like Qt (KDE Plasma) and GTK/GJS (GNOME).

---

## 1. Portability Guarantees

Every `.swift` file in `Sources/VRemindCore/` obeys these rules:

- **Only `Foundation` imports**, plus:
  ```swift
  #if canImport(FoundationNetworking)
  import FoundationNetworking
  #endif
  ```
  wherever HTTP networking symbols (`URLRequest`, `URLResponse`, `HTTPURLResponse`, `URLSession`) appear.
- **No Darwin async `URLSession` lock-in:** Linux/Windows `FoundationNetworking` historically omitted `URLSession.data(for:)`. `StreamMonitorEngine.defaultFetcher` handles this automatically with `#if canImport(FoundationNetworking)` wrapping `session.dataTask(with:)` in `withCheckedThrowingContinuation`.
- **Objective-C runtime isolation:** Calls to `autoreleasepool` (such as HTML parsing in `YouTubeStreamProvider`) are wrapped in `#if canImport(ObjectiveC)`.
- **Strict Concurrency (`Sendable`):** Models, events, registries, providers, and `StreamMonitorEngine` are `Sendable`, making them safe across structured concurrency contexts on Swift 5.9 and Swift 6.

---

## 2. Building a Swift Frontend on Linux or Windows

To build a CLI daemon, systemd user service, Windows tray app, or webhook notifier using `VRemindCore`:

1. **Choose Persistence:** Use `JSONFileChannelStorage` and `JSONFileSettingsStorage` out of the box (e.g., saving to `$XDG_CONFIG_HOME/vremind/channels.json` on Linux or `%APPDATA%\VRemind\channels.json` on Windows), or conform to `ChannelStorage` / `SettingsStorage` for SQLite/registry storage.
2. **Drive Polling at `StreamMonitorEngine.defaultPollInterval` (180s):**
   Run a periodic `Task` loop every 180 seconds calling `engine.refreshPass(...)`. Pause polling when the screen/session locks if your desktop environment exposes idle/sleep signals.
3. **Handle Every `MonitorEvent` Cleanly:**
   - `.metadataUpdated(channelId, name, avatarURL)`: Update stored `channel.name` / `channel.avatarURL` if changed and save via `ChannelStorage`.
   - `.statusUpdated(channelId, status)`: Keep an in-memory map `[String: StreamStatus]`; if transitioning from `.live` to `.offline`, stamp `channel.lastStreamedAt = Date()` on the stored channel.
   - `.notifyLive(channel, videoId, title)`: Send a desktop notification / Discord webhook / terminal alert, then update `channel.lastNotifiedVideoId = videoId` and persist.
   - `.notifyUpcoming(channel, videoId, title)`: Send an upcoming reminder, then update `channel.lastNotifiedUpcomingId = videoId` and persist.
   - `.notifyDeveloperBirthday(year)`: Optionally display the birthday message once, then save `settings.lastNotifiedDevBirthdayYear = year` in `SettingsStorage`.
   - `.refreshFinished(statuses)`: Re-render tray menus, desktop widgets, or grouped sections via `StreamMonitorEngine.splitSections(channels:statuses:)`.

### Example Linux Desktop Notification Loop (`notify-send`)

```swift
import Foundation
import VRemindCore

@main
struct VRemindLinuxDaemon {
    static func main() async throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vremind", isDirectory: true)
        let channelStorage = JSONFileChannelStorage(fileURL: dir.appendingPathComponent("channels.json"))
        let settingsStorage = JSONFileSettingsStorage(fileURL: dir.appendingPathComponent("settings.json"))
        let engine = StreamMonitorEngine()

        var statuses: [String: StreamStatus] = [:]

        while !Task.isCancelled {
            var channels = try channelStorage.loadChannels()
            var settings = try settingsStorage.loadSettings()

            statuses = await engine.refreshPass(
                channels: channels,
                settings: settings,
                currentStatuses: statuses
            ) { event in
                switch event {
                case .notifyLive(let channel, let videoId, let title):
                    // Dispatch desktop notification via `notify-send` / D-Bus, then deduplicate:
                    if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
                        channels[idx].lastNotifiedVideoId = videoId
                        try? channelStorage.saveChannels(channels)
                    }
                    print("[LIVE] \(channel.name): \(title)")
                case .notifyUpcoming(let channel, let videoId, let title):
                    if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
                        channels[idx].lastNotifiedUpcomingId = videoId
                        try? channelStorage.saveChannels(channels)
                    }
                    print("[UPCOMING] \(channel.name): \(title)")
                case .metadataUpdated(let channelId, let name, let avatarURL):
                    if let idx = channels.firstIndex(where: { $0.id == channelId }) {
                        if let name, !name.isEmpty { channels[idx].name = name }
                        if let avatarURL { channels[idx].avatarURL = avatarURL }
                        try? channelStorage.saveChannels(channels)
                    }
                case .notifyDeveloperBirthday(let year):
                    settings.lastNotifiedDevBirthdayYear = year
                    try? settingsStorage.saveSettings(settings)
                case .statusUpdated, .refreshFinished:
                    break
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(StreamMonitorEngine.defaultPollInterval) * 1_000_000_000)
        }
    }
}
```

---

## 3. Porting to Non-Swift Hosts (KDE Plasma, GNOME Shell, etc.)

There are two practical ways to bring VRemind to non-Swift desktop ecosystems:

1. **Thin Swift Companion CLI + Native Applet:**
   Compile a small headless Swift binary powered by `VRemindCore` that exposes commands such as `--once --json` or `--add twitch:ironmouse` and reads/writes `JSONFileChannelStorage`. A GNOME Shell extension (GJS) or KDE Plasma plasmoid (QML/JS) can invoke the binary on a timer and parse its structured JSON output without reimplementing YouTube/Twitch scraping logic.
2. **Direct Spec Port:**
   If porting to C++/Qt, Rust, or TypeScript/GJS directly, use [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) and [`docs/PROVIDERS.md`](PROVIDERS.md) as the behavioral specification, and port the HTML/JSON fixtures from `Tests/VRemindCoreTests/` directly into your target test suite so parsing behavior stays identical.
