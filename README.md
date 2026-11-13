# VRemindCore

The portable, zero-API-key, zero-dependency Swift business engine behind **[VRemind](https://github.com/momochisoundpost/VRemind)**.

`VRemindCore` contains all domain models, live/upcoming stream providers and parsers, bounded-concurrency polling, notification deduplication rules, celebration detection, and persistence contracts — using **only** `Foundation` (plus `FoundationNetworking` on non-Apple platforms).

Originally decoupled for **VRemind 1.3 ("The Better Together Update")**, `VRemindCore` powers the native macOS menu bar app and WidgetKit widgets via `VRemindKit`, while compiling cleanly anywhere Swift runs: **macOS 12+**, **Linux**, **Windows**, Googlebooks (Android), CLI tools, or as a blueprint for native desktop ports (KDE Plasma, GNOME Shell, etc.).

---

## Key Capabilities

- **Zero API Keys Required:**
  - **YouTube** (`YouTubeStreamProvider` + `LivePageParser`): Scrapes `youtube.com/@handle/live` directly, extracting `ytInitialPlayerResponse` JSON, live vs. scheduled upcoming broadcasts, stream start timestamps, channel display names, and owner avatars.
  - **Twitch** (`TwitchStreamProvider` + `TwitchResponseParser`): Queries Twitch's public web GraphQL endpoint (`gql.twitch.tv/gql`) for live stream status, title, start time, display name, and avatar — no Twitch developer account or OAuth token needed.
- **Independent Multi-Platform Identity:** Tracks creators canonically by `(platform, handle)` (`youtube:@ironmouse` vs. `twitch:ironmouse`) so creators active on both platforms stay separate, with automatic migration of legacy v1.2 YouTube-only records.
- **Bounded-Concurrency Polling Engine (`StreamMonitorEngine`):** Polls channels in chunks of `3` via `withTaskGroup`, uses an ephemeral zero-cache `URLSession` (`15s` request timeout), respects task cancellation, deduplicates live/upcoming alerts via stored notification IDs, and emits typed `MonitorEvent` updates.
- **Multilingual Celebration Detection (`CelebrationDetector`):** Detects Birthday, Debut, and Anniversary milestones in English, Indonesian, and Japanese titles.
- **Portable Persistence Contracts (`StorageProtocols`):** Defines `ChannelStorage` and `SettingsStorage` with pure-`Foundation` atomic JSON file implementations (`JSONFileChannelStorage`, `JSONFileSettingsStorage`).
- **Zero External Dependencies:** Pure Swift Standard Library + `Foundation` (+ `FoundationNetworking` on non-Darwin targets).

---

## Requirements

- **Swift:** 5.9+ (Swift Testing suite uses Swift 6 / Xcode 16+ / Swift 6 toolchain or macOS Xcode Command Line Tools)
- **Platforms:** macOS 12.0+, Linux, Windows (anywhere Swift runs)

---

## Installation (Swift Package Manager)

Add `VRemindCore` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/momochisoundpost/VRemindCore.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "VRemindCore", package: "VRemindCore")
        ]
    )
]
```

---

## Quick Start

```swift
import Foundation
import VRemindCore

let channelsURL = URL(fileURLWithPath: "./data/channels.json")
let storage = JSONFileChannelStorage(fileURL: channelsURL)

if let parsed = WatchedChannel.detectPlatformAndHandle(from: "https://www.twitch.tv/ironmouse") {
    let channel = WatchedChannel(
        id: WatchedChannel.makeID(platform: parsed.platform, handle: parsed.handle),
        platform: parsed.platform,
        name: parsed.handle,
        handle: parsed.handle
    )
    try storage.saveChannels([channel])
}

let engine = StreamMonitorEngine()
let channels = try storage.loadChannels()
var settings = AppSettings()

let latestStatuses = await engine.refreshPass(
    channels: channels,
    settings: settings,
    currentStatuses: [:]
) { event in
    switch event {
    case .statusUpdated(let channelId, let status):
        print("\(channelId) -> \(status)")
    case .notifyLive(let channel, let videoId, let title):
        print("LIVE NOW: \(channel.name) — \(title) (\(videoId))")
    case .notifyUpcoming(let channel, let videoId, let title):
        print("UPCOMING: \(channel.name) — \(title) (\(videoId))")
    case .metadataUpdated(let channelId, let name, let avatarURL):
        print("Metadata updated for \(channelId): \(name ?? "-") / \(avatarURL?.absoluteString ?? "-")")
    case .notifyDeveloperBirthday(let year):
        print("Developer birthday celebration (\(year))!")
    case .refreshFinished(let statuses):
        print("Pass complete for \(statuses.count) channel(s)")
    }
}
```

---

## Documentation

Deep-dive technical documentation lives under [`docs/`](docs/):

| Document | What It Covers |
|---|---|
| **[Architecture & Internals](docs/ARCHITECTURE.md)** | Module layout, data flow, canonical channel identity & v1.2 migration, bounded-concurrency polling pipeline, deduplication rules, celebration detection, persistence contracts, and section sorting |
| **[Stream Providers & Parsers](docs/PROVIDERS.md)** | How YouTube (`/live` HTML + `ytInitialPlayerResponse`) and Twitch (key-free GraphQL) scraping work in detail, failure modes, and a step-by-step TDD guide to adding new platforms (e.g., Kick or RSS) |
| **[Porting Guide](docs/PORTING.md)** | Building Linux/Windows/daemon frontends in Swift (`FoundationNetworking`, event bridging) and blueprint notes for KDE Plasma, GNOME Shell, or non-Swift hosts |
| **[Working with AI Agents](docs/AGENTS.md)** | Workflow guide for human-agent collaboration: model stack (Claude Opus for planning, Gemini 4 / 3.8 for implementation), Superpowers workflow, prompting templates, and strict portability guardrails |
| **[Changelog](CHANGELOG.md)** | Version history and release notes |

---

## Development Workflow (Strict TDD & Portability)

All changes to `VRemindCore` follow **Test-Driven Development** (Red -> Green -> Refactor) and strict framework boundaries:

1. **Never hit live external networks in unit tests.** Inject a mock `HTTPFetcher` closure and test against deterministic HTML/JSON fixtures in `Tests/VRemindCoreTests/`.
2. **Never import Apple UI/system frameworks** (`AppKit`, `SwiftUI`, `Combine`, `UserNotifications`, `WidgetKit`, `ServiceManagement`). Only use `Foundation`, `#if canImport(FoundationNetworking)`, and `#if canImport(ObjectiveC)` where needed (e.g., `autoreleasepool`).
3. **Run the automated test suite** (which includes `testVRemindCorePortabilityZeroForbiddenImports` to enforce the import boundary automatically):

```bash
# On Linux / Windows / full Xcode
swift test

# On macOS with only Xcode Command Line Tools installed
bash scripts/test.sh

# Filter to a specific suite
bash scripts/test.sh --filter TwitchStreamProviderTests
```

---

## Disclaimer & License

- VRemindCore is an independent open-source library and is not affiliated with, endorsed by, or associated with YouTube, Google LLC, or Twitch Interactive, Inc.
- Licensed under the **MIT License** — see [LICENSE](LICENSE).
