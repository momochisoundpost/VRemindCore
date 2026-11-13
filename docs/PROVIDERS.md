# Stream Providers, Parsers & Extending VRemindCore

All platform-specific fetching, handle formatting, watch URL resolution, and payload parsing live behind the `StreamProvider` protocol inside `Sources/VRemindCore/Providers/`.

---

## 1. The `StreamProvider` Contract

```swift
public protocol StreamProvider: Sendable {
    var platform: StreamPlatform { get }
    func normalizeHandle(_ input: String) -> String?
    func channelURL(for handle: String) -> URL?
    func watchURL(for channel: WatchedChannel, status: StreamStatus) -> URL?
    func fetchChannelState(for channel: WatchedChannel, fetcher: HTTPFetcher) async throws -> ChannelFetchResult
}
```

Providers are registered in `StreamProviderRegistry`:

```swift
public struct StreamProviderRegistry: Sendable {
    public static let `default` = StreamProviderRegistry(providers: [
        YouTubeStreamProvider(),
        TwitchStreamProvider()
    ])
}
```

You can pass a custom `StreamProviderRegistry` into `StreamMonitorEngine(registry:batchSize:)` to add experimental platforms or swap in test doubles.

---

## 2. Built-in Provider: `YouTubeStreamProvider` + `LivePageParser`

### Request
- **URL:** `https://www.youtube.com/<percent-encoded @handle>/live`
- **Headers:**
  - `User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36`
  - `Accept-Language: en-US,en;q=0.9`
- **Memory hygiene:** On Darwin (`#if canImport(ObjectiveC)`), HTML string decoding and JSON/regex parsing execute inside an `autoreleasepool` block so large YouTube HTML pages don't accumulate temporary Objective-C/Foundation objects during background polling.

### Parsing Strategy (`LivePageParser`)
1. **String-Aware `ytInitialPlayerResponse` JSON Extraction:**
   - Searches for `ytInitialPlayerResponse = {`.
   - Walks character-by-character tracking brace nesting depth (`depth`) while ignoring `{` / `}` characters inside JSON string literals (`inString`, backslash escapes `\"`).
   - Why not regex? Stream titles often contain `{` or `}` characters (e.g., `"a } tricky { title"`), which break regex or naive brace scanning.
2. **Status Classification:**
   - Inspects `videoDetails.isLive`, `videoDetails.isUpcoming`, and `microformat.playerMicroformatRenderer.liveBroadcastDetails.isLiveNow`.
   - **Live (`.live`):** `(isLive || isLiveNow) && !isUpcoming` and non-empty `videoId`. Parses `startTimestamp` via `ISO8601DateFormatter` (checking `.withFractionalSeconds` first, then standard `.withInternetDateTime`).
   - **Upcoming (`.upcoming`):** `isUpcoming` and non-empty `videoId`. Parses `startTimestamp` as `scheduledStartTime`.
   - **Offline (`.notLive`):** Valid `ytInitialPlayerResponse` with neither live nor upcoming flags, **or** fallback check when HTML contains `ytInitialData` (e.g., a channel landing page with no active live waiting room).
   - **Unrecognized (`.unrecognized`):** Non-HTML, consent/interstitial walls without `ytInitialPlayerResponse` or `ytInitialData`, or malformed JSON.
3. **Channel Title Extraction:**
   - Primary: `videoDetails.author`
   - Fallbacks: `<meta property="og:title" content="...">`, then `<title>...</title>`
   - Cleans HTML entities (`&amp;`, `&quot;`, `&#39;`, `&apos;`, `&lt;`, `&gt;`) and strips trailing `" - YouTube"` or bare `"YouTube"`.
4. **Avatar URL Extraction:**
   - Anchors near `"videoOwnerRenderer"` or `"\"owner\":"` within the next `1500` characters so channel avatars aren't confused with related/recommended video avatars elsewhere on the page.
   - Matches YouTube CDN hosts (`yt3/yt4.ggpht.com`, `yt3/yt4.googleusercontent.com`) in both unescaped (`https://...`) and JSON-escaped (`https:\/\/...`) forms.
   - Picks `.last` within the owner slice (YouTube lists thumbnails in ascending resolution, so `.last` selects the highest-resolution avatar). Falls back to `.first` across the full HTML if the owner marker wasn't present.

### Watch URLs
- If `.live(videoId, ...)` or `.upcoming(videoId, ...)` has a non-empty `videoId`: `https://www.youtube.com/watch?v=<videoId>`
- Otherwise: `https://www.youtube.com/@<handle>/live`

---

## 3. Built-in Provider: `TwitchStreamProvider` + `TwitchResponseParser`

### Request (Zero API Keys)
- **Endpoint:** `POST https://gql.twitch.tv/gql`
- **Headers:**
  - `Client-ID: kimne78kx3ncx6brgo4mv6wki5h1ko` (Twitch's public first-party web client ID)
  - `Content-Type: application/json`
- **GraphQL Query:**

```graphql
query($login: String!) {
    user(login: $login) {
        id
        login
        displayName
        profileImageURL(width: 300)
        stream {
            id
            title
            createdAt
            type
        }
    }
}
```

### Status Classification (`TwitchResponseParser`)
- **HTTP Guard:** In `TwitchStreamProvider`, any non-`2xx` `HTTPURLResponse` immediately returns `ChannelFetchResult(pageResult: .unrecognized)` so transient Twitch 5xx responses produce `.unknown` rather than clearing cached stream history.
- **Error / Missing User:** Returns `.unrecognized` if JSON decoding fails, the top-level `"errors"` array is non-empty, or `"data"."user"` is missing/null (non-existent handle).
- **Live vs. Offline:**
  - If `user.stream` is missing/null -> `.notLive(channelTitle: user.displayName, avatarURL: user.avatarURL)`
  - If `stream.type.lowercased() != "live"` or `stream.id` is empty -> `.notLive(...)` (filters out reruns/vodcasts or malformed stream entries)
  - Otherwise -> `.live(videoId: stream.id, title: stream.title, startedAt: stream.createdAt)`

### Watch URLs
- Always returns `https://www.twitch.tv/<lowercased-handle>` because Twitch live streams are watched at the canonical channel URL (stream `id` is tracked separately for deduplication in `lastNotifiedVideoId`).

---

## 4. Adding a New Platform Provider (e.g., Kick or RSS)

Follow the strict TDD workflow before writing production code:

1. **Extend `StreamPlatform`** in `Sources/VRemindCore/Models/StreamPlatform.swift`:
   - Add the new enum case (e.g., `case kick`) and its `displayName`.
2. **Add Normalization & URL Auto-Detection** in `WatchedChannel.swift`:
   - Write failing unit tests in `Tests/VRemindCoreTests/PlatformAndChannelTests.swift` covering valid handles, URL variants, invalid characters, and `detectPlatformAndHandle(from:)`.
   - Implement normalization in `WatchedChannel.normalizeHandle(_:for:)`.
3. **Write Parser & Provider Tests First**:
   - Create `Tests/VRemindCoreTests/<Platform>StreamProviderTests.swift` using JSON/HTML/XML fixtures and an injected mock `HTTPFetcher` covering:
     - Live payload (verifying `videoId`, `title`, `startedAt`, `channelTitle`, `avatarURL`)
     - Upcoming/scheduled payload (if supported by the platform)
     - Offline payload (preserving display name and avatar)
     - HTTP non-`2xx` responses -> `.unrecognized`
     - Malformed payload / upstream API errors -> `.unrecognized`
     - `normalizeHandle`, `channelURL(for:)`, and `watchURL(for:status:)`
4. **Implement Parser + `StreamProvider`**:
   - Create pure parser and provider structs under `Sources/VRemindCore/Providers/` importing only `Foundation` (+ `#if canImport(FoundationNetworking)`).
   - Register the provider in `StreamProviderRegistry.default` (`Sources/VRemindCore/Providers/StreamProvider.swift`).
5. **Verify**:
   - Run `bash scripts/test.sh` (or `swift test`) — confirm all tests pass including `testVRemindCorePortabilityZeroForbiddenImports`.
6. **Expose UI in Host Frontends**:
   - Update your host UI bridge (e.g., `VRemindKit` platform badge color/icon and add-bar picker) for the new `StreamPlatform` case.
