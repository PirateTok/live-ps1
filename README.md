<p align="center">
  <img src="https://raw.githubusercontent.com/PirateTok/.github/main/profile/assets/og-banner-v2.png" alt="PirateTok" width="640" />
</p>

# PirateTok.Live (PowerShell)

Connect to any TikTok Live stream and receive real-time events in PowerShell. No signing server, no API keys, no authentication required.

```powershell
Import-Module PirateTok.Live

$client = Connect-TikTokLive "username_here"
Start-TikTokLive $client -OnEvent {
    param($e)
    switch ($e.Type) {
        'Chat'      { Write-Host "[chat] $($e.Data.user.unique_id): $($e.Data.comment)" }
        'Gift'      { Write-Host "[gift] $($e.Data.user.unique_id) sent $($e.Data.gift_details.name) x$($e.Data.repeat_count)" }
        'Follow'    { Write-Host "[follow] $($e.Data.user.unique_id)" }
        'LiveEnded' { Disconnect-TikTokLive $client }
    }
}
```

Or poll it yourself (game loops, GUIs):

```powershell
$client = Connect-TikTokLive "username_here"
while ($client.State -ne 'Disconnected') {
    foreach ($e in Receive-TikTokEvent $client -TimeoutMs 500) { ... }
}
```

## Install

Requires PowerShell >= 5.1 (Windows PowerShell) or PowerShell 7+.

```powershell
Install-Module PirateTok.Live
```

## Other languages

| Language | Install | Repo |
|:---------|:--------|:-----|
| **Rust** | `cargo add piratetok-live-rs` | [live-rs](https://github.com/PirateTok/live-rs) |
| **Go** | `go get github.com/PirateTok/live-go` | [live-go](https://github.com/PirateTok/live-go) |
| **Python** | `pip install piratetok-live-py` | [live-py](https://github.com/PirateTok/live-py) |
| **JavaScript** | `npm install piratetok-live-js` | [live-js](https://github.com/PirateTok/live-js) |
| **C#** | `dotnet add package PirateTok.Live` | [live-cs](https://github.com/PirateTok/live-cs) |
| **Java** | `com.piratetok:live` | [live-java](https://github.com/PirateTok/live-java) |
| **Lua** | `luarocks install piratetok-live-lua` | [live-lua](https://github.com/PirateTok/live-lua) |
| **Elixir** | `{:piratetok_live, "~> 0.2"}` | [live-ex](https://github.com/PirateTok/live-ex) |
| **Dart** | `dart pub add piratetok_live` | [live-dart](https://github.com/PirateTok/live-dart) |
| **C** | `#include "piratetok.h"` | [live-c](https://github.com/PirateTok/live-c) |
| **Shell** | `bpkg install PirateTok/live-sh` | [live-sh](https://github.com/PirateTok/live-sh) |

## Cmdlets

| Cmdlet | Description |
|--------|-------------|
| `Get-TikTokRoomId` | check_online — `RoomId` + `AnchorId` (streamer user id) |
| `Connect-TikTokLive` | Resolve the room and open the event stream; returns a client |
| `Receive-TikTokEvent` | Poll the client (heartbeats, stale detection, acks, reconnects handled inside) |
| `Start-TikTokLive` | Blocking loop running `-OnEvent` until the client disconnects |
| `Disconnect-TikTokLive` | Close the stream and stop reconnecting |
| `Get-TikTokRoomInfo` | Optional room metadata: title, viewers, likes, FLV stream URLs |
| `Get-TikTokRoomAudience` | Optional full viewer roster (login-gated) |
| `Get-TikTokTtwid` | Fetch a ttwid cookie (retried while TikTok omits it) |
| `ConvertTo-TikTokEvents` | Decode one wire message into events |
| `Get-TikTokTopViewers` | Top-viewers box from a `RoomUserSeq` event |
| `Test-TikTokComboGift` / `Test-TikTokStreakOver` / `Get-TikTokDiamondTotal` | Gift helpers |
| `New-TikTokGiftStreakTracker` / `New-TikTokLikeAccumulator` / `New-TikTokProfileCache` / `Get-TikTokProfile` | Stateful helpers |
| `Get-TikTokRandomUserAgent` / `Get-TikTokSystemTimezone` / `Get-TikTokSystemLocale` | UA pool + locale detection |

## Connect-TikTokLive options

```powershell
$client = Connect-TikTokLive "username_here" `
    -Cdn eu `                         # global (default) / eu / us
    -TimeoutSec 15 `                  # HTTP + handshake timeout (default 10)
    -HeartbeatInterval 10 `           # seconds between heartbeats; also sent as heartbeat_duration (default 10)
    -StaleTimeout 90 `                # reconnect after N seconds of silence (default 60)
    -MaxRetries 10 `                  # consecutive failed reconnects before giving up (default 5)
    -Proxy http://user:pass@host:port ` # HTTP + WSS via HTTP CONNECT (Basic auth from userinfo); falls back to HTTPS_PROXY / HTTP_PROXY
    -UserAgent "Mozilla/5.0 ..." `    # fixed UA instead of the random pool
    -Cookies "sessionid=xxx; sid_tt=xxx" `  # appended to the WSS cookie header
    -Language en -Region US `         # override detected system locale
    -NoCompress                       # ask for uncompressed WSS payloads
```

Proxies: HTTP CONNECT proxies only, with optional Basic auth (`http://user:pass@host:port`). **SOCKS4/5 is not supported** — a `socks5://` proxy is rejected with `InvalidUrl` instead of being silently bypassed.

Cookies are **only required for** room metadata on 18+ rooms (`Get-TikTokRoomInfo`) and the audience roster (`Get-TikTokRoomAudience`). They are **not required** for connecting or streaming events.

### Reconnection

Stale/dropped connections reconnect automatically with backoff 2s → 4s → 8s → 16s → 30s cap. The ttwid + user agent are fetched once and reused across reconnects; they rotate only on `DEVICE_BLOCKED` (2 s retry) or when a session died within 30 s. `MaxRetries` counts *consecutive* failures — a session that stayed up 30 s resets the counter. A ttwid fetch failure is a failed attempt (`Reconnecting` fires), never an abort. `Disconnected` fires only when retries run out or you call `Disconnect-TikTokLive`.

## Events

Every event is `[pscustomobject]@{ Type; Method; Data; RawPayload }`. `Data` is the decoded protobuf as a hashtable with snake_case field names (`$e.Data.user.nickname`, `$e.Data.comment`, …).

- **64 typed message types** (Tier A + Tier B) — `Chat`, `Gift`, `Like`, `Member`, `Social`, `RoomUserSeq`, `Control`, `LiveIntro`, `RoomMessage`, `Caption`, `GoalUpdate`, `ImDelete`, `RankUpdate`, `Poll`, `Envelope`, `RoomPin`, `LinkMicBattle`, `EmoteChat`, `SubNotify`, … (the `Type` names match the other PirateTok libs).
- **Sub-routed convenience events** fire alongside the raw event: `Follow` / `Share` (Social action 1 / 2–5), `Join` (Member action 1), `LiveEnded` (Control action 3).
- **Unknown** — any other message type: `Method` + `RawPayload` bytes, nothing lost.
- **Lifecycle** — `Connected` (`room_id`, `anchor_id`), `RoomEntered`, `Reconnecting` (`attempt`, `max_retries`, `delay_secs`, `reason`, `device_blocked`), `Disconnected` (`reason`), `Error` (undecodable frame).

`user` objects carry the enriched fields: `id`, `unique_id`, `display_id`, `nickname`, `verified`, `follow_info` (follower/following counts, follow status), `fans_club.data` (club name + level), `badge_list` (`badge_scene`: 1 moderator, 6 top gifter, 8 gifter level, 10 member level; level in `log_extra.level`), `is_follower`, `is_following`, `is_subscribe`, `pay_score`, `fan_ticket_count`, `top_vip_no`.

### Top viewers (WSS, no cookies)

```powershell
'RoomUserSeq' { Get-TikTokTopViewers $e.Data | ForEach-Object { "$($_.rank) $($_.user.nickname) $($_.score)" } }
```

`RoomUserSeq` carries `viewer_count`, `total_user`, `anonymous`, `pop_str`, `ranks_list`, `seats_list`.

## Errors

All errors throw `[PirateTok.Live.TikTokLiveException]` with `.ErrorKind` (and `.Code` where TikTok sent one):

| ErrorKind | Meaning |
|-----------|---------|
| `UserNotFound` | Username does not exist on TikTok |
| `HostNotOnline` | User exists but is not currently live |
| `ApiError` | Other TikTok API status code (`.Code`) |
| `TikTokBlocked` | HTTP 403/429, or an empty / non-JSON response |
| `AgeRestricted` | 18+ room — pass session cookies to `Get-TikTokRoomInfo` |
| `SessionRequired` | Audience roster needs session cookies |
| `DeviceBlocked` | WSS handshake returned DEVICE_BLOCKED (handled by reconnect) |
| `InvalidResponse` | Malformed or unexpected response |
| `HttpError` / `WebSocketError` | Transport failure |
| `ProfilePrivate` / `ProfileNotFound` / `ProfileError` / `ProfileScrape` | Profile lookup |

```powershell
try { $live = Get-TikTokRoomId "username_here" }
catch [PirateTok.Live.TikTokLiveException] {
    switch ($_.Exception.ErrorKind) {
        'HostNotOnline' { 'offline' }
        'UserNotFound'  { 'no such user' }
        default         { "[$($_.Exception.ErrorKind)] $($_.Exception.Message)" }
    }
}
```

## Room info (optional)

```powershell
$live = Get-TikTokRoomId "username_here"
$info = Get-TikTokRoomInfo $live.RoomId                                     # normal rooms
$info = Get-TikTokRoomInfo $live.RoomId -Cookies "sessionid=xxx; sid_tt=xxx" # 18+ rooms
$info.Title; $info.Viewers; $info.StreamUrl.FlvOrigin                         # FlvOrigin/FlvHd/FlvSd/FlvLd/FlvAo
```

## Audience roster (optional, login-gated)

The full viewer list behind the web viewer panel. Session cookies are required for this call only — without them you get `SessionRequired`.

```powershell
$aud = Get-TikTokRoomAudience $live.RoomId -AnchorId $live.AnchorId -Cookies "sessionid=xxx; sid_tt=xxx"
$aud.Total; $aud.Anonymous; $aud.Viewers | Format-Table Rank, Username, Nickname, Score
```

Omit `-AnchorId` to resolve it via room info (one extra request).

## Helpers

```powershell
$tracker = New-TikTokGiftStreakTracker   # $tracker.Process($e.Data) -> EventGiftCount, TotalDiamondCount, IsFinal
$likes   = New-TikTokLikeAccumulator     # $likes.Process($e.Data)   -> TotalLikeCount (monotonic), AccumulatedCount
$cache   = New-TikTokProfileCache        # $cache.Fetch('username')  -> cached SIGI profile (5 min TTL)
```

## Examples

```powershell
pwsh examples/online_check.ps1 <username>             # check if user is live
pwsh examples/basic_chat.ps1 <username>               # connect + print events
pwsh examples/stream_info.ps1 <username> [cookies]    # metadata + FLV stream URLs
pwsh examples/gift_streak.ps1 <username>              # gift streaks with per-event deltas
pwsh examples/profile_lookup.ps1 <username>           # cached profile lookup
pwsh examples/audience.ps1 <username> <cookies>       # full viewer roster (session cookies required)
```

## Tests

```powershell
pwsh tests/unit.ps1         # offline: ttwid retry (local fake HTTP server), reconnect policy, parsers, framing
pwsh tests/wire.ps1         # offline wire: local CONNECT proxy (Basic auth) + TLS fake — room/ttwid/WSS, UA/cookies/locale on the wire
pwsh tests/replay.ps1       # replay WSS captures vs live-testdata manifests (exact)
pwsh tests/discipline.ps1   # R1 file size, R2 no silent error suppression
```

Replay needs testdata: `git clone https://github.com/PirateTok/live-testdata ../live-testdata`. Missing testdata is a failure, not a skip. Lookup order: `$env:PIRATETOK_TESTDATA`, `testdata/`, `../live-testdata/` (manifests in `manifests/` or `captures/manifests/`). The `_raw` captures are not in live-testdata — supply them via `testdata/` or `PIRATETOK_TESTDATA`.

## How it works

1. `GET /api-live/user/room` resolves the username to a room id (+ streamer id)
2. Anonymous `GET https://www.tiktok.com/` yields a `ttwid` cookie — the only credential WSS needs
3. Raw TLS WebSocket (TcpClient + SslStream, same code on PS 5.1 and 7) to `webcast-ws.tiktok.com`
4. Heartbeat + `im_enter_room`, then protobuf frames decoded by a schema-driven codec (compiled C# via `Add-Type`, no protoc)

## License

0BSD
