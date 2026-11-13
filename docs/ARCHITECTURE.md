# Architecture & Internals

This document explains how `VRemindCore` is structured, how data moves through a refresh cycle, and how each subsystem behaves internally.

---

## 1. High-Level Design Principles

1. **Pure `Foundation` Core:** Every file under `Sources/VRemindCore/` imports only `Foundation` (plus `#if canImport(FoundationNetworking) import FoundationNetworking #endif` for HTTP types on Linux/Windows). No UI (`SwiftUI`, `AppKit`), reactive (`Combine`), OS notification (`UserNotifications`), widget (`WidgetKit`), or login-item (`ServiceManagement`) dependencies exist here.
2. **Stateless Engine, Stateful Host Bridge:** `StreamMonitorEngine` does not own mutable app state or mutate disk storage directly. Instead, a host bridge (such as `VRemindKit` on macOS) feeds a `[WatchedChannel]` snapshot and `AppSettings` into `refreshPass(...)`, listens to typed `MonitorEvent` callbacks, and applies state mutations + OS side effects (notifications, UI state updates, desktop widgets).
3. **Deterministic I/O Injection:** Every network call accepts an `HTTPFetcher` closure (`@Sendable (URLRequest) async throws -> (Data, URLResponse)`), allowing 100% offline, deterministic unit testing with mocked responses.

---

## 2. Module Layout

```text
Sources/VRemindCore/
├── Models/
│   ├── StreamPlatform.swift       # .youtube, .twitch (+ displayName)
│   ├── WatchedChannel.swift       # Canonical (platform, handle) model, normalization, URL detection, v1.2 migration
│   ├── StreamStatus.swift         # .live, .upcoming, .offline, .unknown
│   ├── ChannelFetchResult.swift   # HTTPFetcher, LivePageResult, ChannelFetchResult
│   ├── AppSettings.swift          # Codable user preferences & developer birthday tracking
│   ├── ElapsedTime.swift          # Compact durations ("42m", "2h 05m", "3d 4h") & relative strings
│   └── GitHubRelease.swift        # Flexible GitHub Releases API Codable models
├── Providers/
│   ├── StreamProvider.swift       # StreamProvider protocol & StreamProviderRegistry
│   ├── YouTubeStreamProvider.swift# YouTube /live page fetcher & watch URL builder
│   ├── TwitchStreamProvider.swift # Key-free Twitch GraphQL fetcher
│   └── TwitchResponseParser.swift # Pure JSON parser for Twitch GraphQL payloads
├── Services/
│   ├── StreamMonitorEngine.swift  # Bounded-concurrency polling, deduplication events, section splitting
│   ├── LivePageParser.swift       # YouTube HTML & ytInitialPlayerResponse JSON extractor
│   └── CelebrationDetector.swift  # Multilingual EN/ID/JA milestone detection & confetti helper
├── Persistence/
│   └── StorageProtocols.swift     # ChannelStorage & SettingsStorage + JSONFile implementations
└── Utilities/
    ├── SecretCheck.swift          # Handle matching & easter egg demotion strings
    └── SemanticVersion.swift      # Semver parser & Comparable implementation
```

---

## 3. Data Flow of a Refresh Pass

```text
Host Bridge (e.g. VRemindKit / Linux Daemon / CLI)
   │  passes: [WatchedChannel], AppSettings, currentStatuses, HTTPFetcher
   ▼
StreamMonitorEngine.refreshPass(...)
   ├──► Check Dec 31 developer birthday condition -> emits .notifyDeveloperBirthday(year:)
   │
   ├──► Chunk channels into batches of `batchSize` (default = 3)
   │      └──► withTaskGroup: run batch concurrently
   │             └──► StreamProviderRegistry.provider(for: channel.platform)
   │                    └──► provider.fetchChannelState(for: channel, fetcher: fetcher)
   │                           ├── .live(videoId, title, startedAt)
   │                           ├── .upcoming(videoId, title, scheduledStartTime)
   │                           ├── .notLive(channelTitle, avatarURL)
   │                           └── .unrecognized / network error
   │
   └──► Emit MonitorEvent stream sequentially per outcome:
          ├── .metadataUpdated(channelId, name, avatarURL)
          ├── .statusUpdated(channelId, status)
          ├── .notifyLive(channel, videoId, title)        [if videoId != lastNotifiedVideoId && notifyOnLive]
          ├── .notifyUpcoming(channel, videoId, title)    [if videoId != lastNotifiedUpcomingId && notifyOnUpcoming]
          └── .refreshFinished(statuses)
```

---

## 4. Channel Identity, Normalization, and v1.2 Migration

### Canonical ID (`WatchedChannel.makeID`)
Because a creator can stream on both YouTube and Twitch under the same handle (e.g., `@ironmouse` on YouTube and `ironmouse` on Twitch), channels are identified by both platform and lowercased handle:

```swift
"\(platform.rawValue):\(handle.lowercased())"
// e.g. "youtube:@ironmouse" vs "twitch:ironmouse"
```

This keeps watchlist entries, `statuses` dictionary keys, notification deduplication markers (`lastNotifiedVideoId`, `lastNotifiedUpcomingId`), and downstream avatar caches cleanly isolated.

### Input Normalization & URL Detection
- `WatchedChannel.detectPlatformAndHandle(from:)`: Inspects raw input for `twitch.tv` first, then `youtube.com` / `youtu.be`.
- `WatchedChannel.normalizeHandle(_:for:)`:
  - **YouTube:** Trims whitespace, rejects internal whitespace, parses bare handles (`name` or `@name`) or `/@handle` URLs (`youtube.com/@...`, `youtu.be/@...`), restricts characters to `[A-Za-z0-9_.-]`, and canonicalizes with a leading `@`.
  - **Twitch:** Trims whitespace, rejects internal whitespace, accepts bare usernames or `twitch.tv` / `www.twitch.tv` / `m.twitch.tv` URLs (first path segment), strips any optional leading `@`, blocks Twitch site routes (`directory`, `videos`, `settings`, `subscriptions`, `wallet`, `inventory`, `drops`, `downloads`, `jobs`, `p`, `u`), validates length `1...25` with `[A-Za-z0-9_]`, and lowercases the handle.

### Legacy v1.2 Decoding (`init(from decoder:)`)
VRemind 1.2 stored YouTube-only channels without a `platform` key (`id` was simply `"@handle"`). `WatchedChannel.init(from:)` preserves zero-loss migration:
- If `platform` is missing in JSON, it defaults to `.youtube`.
- If `platform` was missing and `id` does not already begin with `"youtube:"`, it upgrades `id` to `"youtube:<lowercased-handle>"`, while preserving all historical fields (`name`, `avatarURL`, `lastNotifiedVideoId`, `lastNotifiedUpcomingId`, `lastStreamedAt`).

---

## 5. Polling Engine (`StreamMonitorEngine`)

### Network Configuration (`defaultFetcher`)
- Uses a dedicated static `URLSessionConfiguration.ephemeral` session with:
  - `urlCache = nil`
  - `requestCachePolicy = .reloadIgnoringLocalCacheData`
  - `timeoutIntervalForRequest = 15`
- On Apple platforms, uses native `session.data(for:)`.
- When `FoundationNetworking` is used (Linux/Windows), bridges `session.dataTask(with:)` via `withCheckedThrowingContinuation` so Swift concurrency works cleanly across toolchains.

### Bounded Concurrency
Channels are sliced into chunks of `max(1, batchSize)` (`defaultBatchSize = 3`). Each chunk executes concurrently inside `withTaskGroup`, while chunks run sequentially with cancellation checks (`guard !Task.isCancelled else { break }`) between batches. This prevents rate-limit spikes on large watchlists.

### Event & Status Transitions
For each channel outcome in a batch:
- **Fetch Error or `.unrecognized`:** Status becomes `.unknown` (`updatedStatuses[channel.id] = .unknown`) without clearing previously cached `channel.name`, `channel.avatarURL`, or `channel.lastStreamedAt`.
- **`.live(videoId, title, startedAt)`:**
  1. Emits `.metadataUpdated` if `channelTitle` or `avatarURL` is non-nil.
  2. Sets `.live(...)` and emits `.statusUpdated`.
  3. Emits `.notifyLive` only when `channel.lastNotifiedVideoId != videoId && settings.notifyOnLive`.
- **`.upcoming(videoId, title, scheduledStartTime)`:**
  1. Emits `.metadataUpdated` if metadata is present.
  2. Sets `.upcoming(...)` and emits `.statusUpdated`.
  3. Emits `.notifyUpcoming` only when `channel.lastNotifiedUpcomingId != videoId && settings.notifyOnUpcoming`.
- **`.notLive(channelTitle, avatarURL)`:**
  1. Emits `.metadataUpdated` if metadata is present.
  2. Sets `.offline(lastStreamedAt: channel.lastStreamedAt)` and emits `.statusUpdated`. Note: the **host bridge** is responsible for recording `lastStreamedAt = Date()` when transitioning from `.live` to `.offline` or persisting new `lastNotifiedVideoId` values in `ChannelStorage`.

### Section Sorting (`splitSections`)
`StreamMonitorEngine.splitSections(channels:statuses:)` groups channels into `ChannelSections(live:, upcoming:, offline:)` preserving watchlist order inside each section, except channels matching `SecretCheck.isTarget` are demoted to the bottom of their respective section.

---

## 6. Celebration Detection (`CelebrationDetector`)

`CelebrationDetector` scans stream titles (and dates for developer birthdays) with strict priority order:

1. **Birthday (`.birthday`)**: Word-boundary English (`birthday stream`, `birthday`, `bday`), word-boundary Indonesian (`ultah`, `ulang tahun`), and case-insensitive Japanese CJK substring (`生誕祭`, `誕生日`, `バースデー`).
2. **Debut (`.debut`)**: Word-boundary English (`re-debut`, `redebut`, `debut`), Japanese CJK substring (`初配信`, `お披露目`).
3. **Anniversary (`.anniversary`)**: Word-boundary English (`anniversary`, `anni`), Indonesian (`hari jadi`, `anniv`), Japanese CJK substring (`周年`, `記念配信`, `記念枠`).
4. **Developer Birthday (`.developerBirthday`)**: Triggers on December 31 (`year > 1999`) for `@bukancaitlyn` / `"Caitlyn Momochi"` (checked in `detect(status:channel:date:calendar:)`, `refreshPass(...)`, and `shouldShowConfetti(...)`).

`shouldShowConfetti(channels:statuses:date:calendar:)` returns `true` if:
- Today is Dec 31 (`year > 1999`) and a developer channel is watched, **or**
- Any watched channel is currently `.live` with a celebration title, **or**
- Any watched channel is `.upcoming` with a celebration title whose `scheduledStartTime` falls on the same calendar day as `date`.

---

## 7. Persistence Contracts (`StorageProtocols.swift`)

`VRemindCore` defines two `Sendable` storage protocols:

- **`ChannelStorage`**:
  - `func loadChannels() throws -> [WatchedChannel]`
  - `func saveChannels(_ channels: [WatchedChannel]) throws`
- **`SettingsStorage`**:
  - `func loadSettings() throws -> AppSettings`
  - `func saveSettings(_ settings: AppSettings) throws`

For standalone CLI / Linux / Windows / server environments, `JSONFileChannelStorage` and `JSONFileSettingsStorage` serialize data using `JSONEncoder` (`.prettyPrinted`, `.sortedKeys`, `.iso8601`), create missing intermediate directories, and write via `Data.write(to:options: .atomic)`. If the target file does not yet exist, `loadChannels()` returns `[]` and `loadSettings()` returns `AppSettings()`.

---

## 8. Versioning & Update Models

- **`SemanticVersion`**: Parses tags with optional `"v"` prefix and optional prerelease suffixes (`"1.1-beta"` -> `1.1.0`), conforms to `Comparable`, and powers `isNewerThan(_:)`.
- **`GitHubRelease` / `GitHubReleaseAsset`**: Supports decoding both GitHub REST `snake_case` keys (`tag_name`, `html_url`, `published_at`, `browser_download_url`) and `camelCase` keys (`tagName`, `htmlURL`, `publishedAt`, `browserDownloadURL`), including ISO 8601 string or `Date` decoding.
- **`AppSettings`**: Gracefully falls back missing keys during decoding (`updateConsent = .undecided`, `reduceMotion = false`, etc.) so older persisted configs load cleanly as new fields are added.
