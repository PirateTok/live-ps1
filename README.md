# PirateTok.Live (PowerShell)

Connect to any TikTok Live stream and receive real-time events in PowerShell. No signing server, no API keys, no authentication required.

```powershell
Import-Module PirateTok.Live

$conn = Connect-TikTokLive "someone"

while ($true) {
    $events = Receive-TikTokFrame $conn
    foreach ($e in $events) {
        switch ($e.Method) {
            "WebcastChatMessage" { Write-Host "[chat] $($e.User.UniqueId): $($e.Content)" }
            "WebcastGiftMessage" { Write-Host "[gift] $($e.User.UniqueId) sent $($e.GiftName) x$($e.RepeatCount) ($($e.DiamondCount) diamonds)" }
            "Follow"            { Write-Host "[follow] $($e.User.UniqueId)" }
            "Join"              { Write-Host "[join] $($e.User.UniqueId)" }
            "Share"             { Write-Host "[share] $($e.User.UniqueId)" }
            "LiveEnded"         { Write-Host "[ended]"; break }
        }
    }
}

Close-TikTokLive $conn
```

## Install

Requires PowerShell >= 5.1.

```powershell
Install-Module PirateTok.Live
```

## Cmdlets

| Cmdlet | Description |
|--------|-------------|
| `Connect-TikTokLive` | Connect to a live room — by username, or by `-RoomId`/`-Ttwid` |
| `Get-TikTokTtwid` | Fetch an auth cookie |
| `Get-TikTokRoomId` | Resolve username to room ID |
| `Get-TikTokStreamInfo` | Fetch room metadata (title, viewers, stream URLs) |
| `Get-TikTokBestStreamUrl` | Pick the best FLV stream URL from room info by quality tier |
| `Send-TikTokHeartbeat` | Send a heartbeat frame (called automatically by `Receive-TikTokFrame`) |
| `Receive-TikTokFrame` | Read and decode the next WSS frame |
| `Close-TikTokLive` | Close the connection |

## Connect-TikTokLive

```powershell
# Standard: username -> auth + room ID + WSS, all automatic
$conn = Connect-TikTokLive "someone"

# Pre-fetched auth + room ID (useful for GUIs that cache these)
$conn = Connect-TikTokLive -RoomId 7624600804717316886 -Ttwid $cookie

# Override user agent
$conn = Connect-TikTokLive "someone" -UserAgent "Mozilla/5.0 ..."

# Pass session cookies (for 18+ room info only)
$conn = Connect-TikTokLive "someone" -Cookies "sessionid=xxx; sid_tt=xxx"
```

## Error handling

All errors throw `TikTokLiveException` with an `ErrorKind` property:

| ErrorKind | Meaning |
|-----------|---------|
| `UserNotFound` | Username does not exist on TikTok |
| `HostNotOnline` | User exists but is not currently live |
| `AgeRestricted` | 18+ room — pass session cookies to `Get-TikTokStreamInfo` |
| `TikTokBlocked` | IP/fingerprint blocked, rate-limited, or geo-blocked |
| `DeviceBlocked` | WSS handshake returned DEVICE_BLOCKED |
| `ApiError` | Other TikTok API error (includes status code) |
| `ConnectFailed` | WSS handshake or HTTP request failed |

```powershell
try {
    $rid = Get-TikTokRoomId "someone"
} catch {
    $ex = $_.Exception
    if ($ex -is [TikTokLiveException]) {
        switch ($ex.ErrorKind) {
            "UserNotFound"  { Write-Host "user does not exist" }
            "HostNotOnline" { Write-Host "user is offline" }
            "TikTokBlocked" { Write-Host "blocked: $($ex.Message)" }
        }
    }
}
```

## Events

### Convenience events (sub-routed)

These fire alongside the raw proto events — use whichever granularity you need:

| Event | Source | Condition |
|-------|--------|-----------|
| `Follow` | `WebcastSocialMessage` | action == 1 |
| `Share` | `WebcastSocialMessage` | action == 3 or 4 |
| `Join` | `WebcastMemberMessage` | action == 1 |
| `LiveEnded` | `WebcastControlMessage` | action == 3 |

### Raw proto events

| Method | Key fields |
|--------|------------|
| `WebcastChatMessage` | `.User`, `.Content` |
| `WebcastGiftMessage` | `.User`, `.GiftName`, `.GiftId`, `.DiamondCount`, `.RepeatCount`, `.ComboCount`, `.IsCombo` |
| `WebcastLikeMessage` | `.User`, `.Count`, `.TotalLikes` |
| `WebcastMemberMessage` | `.User`, `.Action` |
| `WebcastSocialMessage` | `.User`, `.Action` |
| `WebcastRoomUserSeqMessage` | `.ViewerCount` |
| `WebcastControlMessage` | `.Action` |

All events carry `.Method` and `.RawPayload` (raw protobuf bytes).

### User fields

Every `.User` object includes:

| Field | Type | Notes |
|-------|------|-------|
| `UserId` | int64 | TikTok user ID |
| `UniqueId` | string | Username |
| `Nickname` | string | Display name |
| `DisplayId` | string | Display username |
| `Bio` | string | Bio text |
| `Verified` | bool | Verified badge |
| `FollowStatus` | int64 | 0=none, 1=following, 2=mutual |
| `IsFollower` | bool | Follows the streamer |
| `IsFollowing` | bool | Streamer follows them |
| `IsSubscribe` | bool | Subscriber/superfan |
| `IsModerator` | bool | Has admin badge |
| `IsTopGifter` | bool | Has rank list badge |
| `GifterLevel` | string | USER_GRADE badge level |
| `MemberLevel` | string | FANS badge level |
| `FansClubName` | string | Fan club name |
| `FansClubLevel` | int32 | Fan club level |
| `FollowingCount` | int64 | Following count |
| `FollowerCount` | int64 | Follower count |
| `PayScore` | int64 | Payment score |
| `FanTicket` | int64 | Gifting score |
| `TopVipNo` | int32 | VIP ranking |

## Stream info

Room info is **optional** and separate from WSS. Only needed for title, viewer counts, and stream URLs.

```powershell
$rid = Get-TikTokRoomId "someone"
$info = Get-TikTokStreamInfo $rid

# For 18+ rooms, pass session cookies:
$info = Get-TikTokStreamInfo $rid -Cookies "sessionid=xxx; sid_tt=xxx"

# Pick best stream URL (falls through quality tiers)
$best = Get-TikTokBestStreamUrl $info               # origin -> hd -> sd -> ld -> ao
$sd   = Get-TikTokBestStreamUrl $info -Quality "sd"  # sd -> ld -> ao
# Returns @{ Quality = "origin"; Url = "https://..." } or $null
```

## Features

- **Zero signing dependency** — no API keys, no signing server, no external auth
- **UA rotation** — 6 user agents (3 Firefox, 3 Chrome, mixed OS), rotated per request
- **System timezone** — auto-detected via .NET/env/filesystem, falls back to UTC
- **Typed errors** — `TikTokLiveException` with `.ErrorKind` for clean error handling
- **Convenience events** — `Follow`, `Share`, `Join`, `LiveEnded` sub-routed from raw protos
- **Enriched users** — badges, gifter/member level, fan club, follow status, moderator detection
- **Protobuf codec** — hand-written binary encoder/decoder in pure PowerShell
- **PS 5.1 + Win7 fallback** — raw TcpClient/SslStream WebSocket framing when `ClientWebSocket` is unavailable
- **Auto-heartbeat** — `Receive-TikTokFrame` sends heartbeats every 10s automatically

## Examples

```powershell
pwsh examples/basic_chat.ps1 <username>       # connect + print events (30s)
pwsh examples/online_check.ps1 <username>     # check if user is live
pwsh examples/stream_info.ps1 <username>      # fetch metadata + stream URLs
pwsh examples/gift_tracker.ps1 <username>     # track gifts with diamond totals (60s)
```

## Other languages

| Language | Package | Repo |
|----------|---------|------|
| Rust | `piratetok-live-rs` | [PirateTok/live-rs](https://github.com/PirateTok/live-rs) |
| C# | `PirateTok.Live` | [PirateTok/live-cs](https://github.com/PirateTok/live-cs) |
| Go | `github.com/PirateTok/live-go` | [PirateTok/live-go](https://github.com/PirateTok/live-go) |
| JavaScript | `piratetok-live-js` | [PirateTok/live-js](https://github.com/PirateTok/live-js) |
| Python | `piratetok-live-py` | [PirateTok/live-py](https://github.com/PirateTok/live-py) |
| Java | `com.piratetok:live` | [PirateTok/live-java](https://github.com/PirateTok/live-java) |
| Lua | `piratetok-live-lua` | [PirateTok/live-lua](https://github.com/PirateTok/live-lua) |
| Elixir | `piratetok_live` | [PirateTok/live-ex](https://github.com/PirateTok/live-ex) |
| C | `libpiratetok` | [PirateTok/live-c](https://github.com/PirateTok/live-c) |
| Dart | `piratetok_live` | [PirateTok/live-dart](https://github.com/PirateTok/live-dart) |
| Shell | `piratetok-live-sh` | [PirateTok/live-sh](https://github.com/PirateTok/live-sh) |

## License

0BSD
