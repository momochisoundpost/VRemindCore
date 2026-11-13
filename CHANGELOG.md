# Changelog

All notable changes to `VRemindCore` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-13

### Added
- **Standalone Cross-Platform Swift Package (`VRemindCore`):** Extracted from VRemind 1.3 ("Better Together") into an independent pure-`Foundation` (+ `FoundationNetworking`) library with zero Apple UI/runtime framework dependencies.
- **Multi-Platform Stream Models:** Added `StreamPlatform` (`.youtube`, `.twitch`), `WatchedChannel` (canonical `(platform, handle)` identifiers, input normalization, URL auto-detection, and automatic migration from legacy v1.2 YouTube-only records), `StreamStatus`, `ChannelFetchResult`, `AppSettings`, `ElapsedTime`, and `GitHubRelease`.
- **Zero-API-Key Providers & Parsers:**
  - `StreamProvider` protocol and `StreamProviderRegistry`.
  - `YouTubeStreamProvider` & `LivePageParser` (`@handle/live` HTML + string-aware `ytInitialPlayerResponse` JSON extraction).
  - `TwitchStreamProvider` & `TwitchResponseParser` (key-free public web GraphQL client query).
- **Bounded-Concurrency Monitoring Engine (`StreamMonitorEngine`):** Ephemeral cache-free `URLSession`, 3-channel batch concurrency via `withTaskGroup`, event-driven `MonitorEvent` notifications with deduplication checks, and section sorting (`splitSections`).
- **Celebration Detection (`CelebrationDetector`):** Multilingual EN / ID / JA milestone keyword scanning for birthdays, debuts, and anniversaries, plus Dec 31 developer birthday support.
- **Portable File Persistence (`StorageProtocols`):** `ChannelStorage` and `SettingsStorage` protocols with pure-`Foundation` atomic JSON file backends (`JSONFileChannelStorage`, `JSONFileSettingsStorage`).
- **Utilities & Portability Guardrails:** `SemanticVersion`, `SecretCheck`, and automated forbidden-import verification in `VRemindCoreTests`.
