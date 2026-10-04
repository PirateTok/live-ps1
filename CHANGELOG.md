# Changelog

## 0.2.0

Full parity rewrite (module split into `src/*.ps1`). **Breaking API.**

- Poll-based client: `Connect-TikTokLive` → `Receive-TikTokEvent` / `Start-TikTokLive` → `Disconnect-TikTokLive`. Replaces `Receive-TikTokFrame` / `Send-TikTokHeartbeat` / `Close-TikTokLive`.
- Reconnect loop: stale timeout, backoff 2→30 s, `Reconnecting` / `Disconnected` events. ttwid fetch retried 8× (750 ms) when TikTok omits the cookie; ttwid + UA reused across reconnects and rotated only on DEVICE_BLOCKED or a session that died within 30 s; `MaxRetries` counts consecutive failures (30 s healthy session resets it); a ttwid failure is a failed attempt, not an abort.
- `Get-TikTokRoomId` returns `RoomId` + `AnchorId`; errors `UserNotFound` / `HostNotOnline` / `ApiError` (`.Code`) / `TikTokBlocked`.
- `Get-TikTokRoomInfo` (was `Get-TikTokStreamInfo`): title, viewers, likes, FLV stream URLs, `AgeRestricted`.
- New `Get-TikTokRoomAudience` (login-gated, `SessionRequired`) and `Get-TikTokTopViewers` (`RoomUserSeq.ranks_list`).
- Events: 64 typed message types decoded by a schema-driven codec; every other type → `Unknown { Method, RawPayload }`; Follow/Share/Join/LiveEnded sub-routing. Fixes wrong Gift/Like field tags of 0.1.x.
- `-Proxy` (HTTP + WSS CONNECT tunnel, env fallback), `-Language` / `-Region`, `-NoCompress`, `-HeartbeatInterval` (also the `heartbeat_duration` URL param); user `-Cookies` now actually reach the WSS.
- Helpers: `New-TikTokGiftStreakTracker`, `New-TikTokLikeAccumulator`, `New-TikTokProfileCache`, `Get-TikTokProfile`; gift helpers `Test-TikTokComboGift`, `Test-TikTokStreakOver`, `Get-TikTokDiamondTotal`.
- Tests: offline unit suite, replay vs live-testdata manifests, discipline scanner.
- Project URL: https://piratetok.rosint.org/
