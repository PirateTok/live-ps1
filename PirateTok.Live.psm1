#!/usr/bin/env pwsh
# PirateTok.Live -- TikTok Live WebSocket connector module
# Install: Install-Module PirateTok.Live
# Usage:   Import-Module PirateTok.Live
#          $conn = Connect-TikTokLive -Username "someone"
#          while ($frame = Receive-TikTokFrame $conn) { ... }

$ErrorActionPreference = 'Stop'

# TLS 1.2 for PS 5.1
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.IO.Compression 2>$null

# --- config ---
$script:CDN = "webcast-ws.tiktok.com"
$script:HeartbeatSec = 10

# --- error types (Add-Type so the type is globally visible, not module-scoped) ---
if (-not ([System.Management.Automation.PSTypeName]'TikTokLiveException').Type) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
public class TikTokLiveException : Exception {
    public string ErrorKind { get; }
    public TikTokLiveException(string kind, string message) : base(message) { ErrorKind = kind; }
}
'@
}

function New-TikTokError([string]$Kind, [string]$Message) {
    return [TikTokLiveException]::new($Kind, $Message)
}

# --- UA pool (3 Firefox, 3 Chrome, mixed OS) ---
$script:UserAgents = @(
    "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:139.0) Gecko/20100101 Firefox/139.0"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

function Get-RandomUA {
    return $script:UserAgents[(Get-Random -Minimum 0 -Maximum $script:UserAgents.Count)]
}

function Get-SystemTimezone {
    # 1. TZ env var
    $tz = $env:TZ
    if ($tz -and $tz.Contains('/')) { return $tz.Trim() }

    # 2. .NET TimeZoneInfo → IANA (PS 7+ on all platforms, PS 5.1 on Windows via mapping)
    try {
        $tzi = [System.TimeZoneInfo]::Local
        # PS 7.x exposes .Id as IANA on non-Windows, or has HasIanaId
        if ($tzi.Id -and $tzi.Id.Contains('/')) { return $tzi.Id }
        # Windows: Id is Windows tz name, try to map via .NET 6+ API
        try {
            $iana = $null
            if ([System.TimeZoneInfo]::TryConvertWindowsIdToIanaId($tzi.Id, [ref]$iana)) {
                if ($iana -and $iana.Contains('/')) { return $iana }
            }
        } catch {}
    } catch {}

    # 3. /etc/timezone (Debian/Ubuntu)
    try {
        if (Test-Path "/etc/timezone") {
            $tz = (Get-Content "/etc/timezone" -Raw).Trim()
            if ($tz -and $tz.Contains('/')) { return $tz }
        }
    } catch {}

    # 4. /etc/localtime symlink (Arch, Fedora, macOS)
    try {
        $target = [System.IO.File]::ReadAllText("/etc/localtime")
    } catch {}
    try {
        $link = (Get-Item "/etc/localtime" -ErrorAction SilentlyContinue).Target
        if ($link) {
            $parts = $link -split '/zoneinfo/'
            if ($parts.Count -ge 2 -and $parts[1]) { return $parts[1] }
        }
    } catch {}

    return "UTC"
}

# --- byte helper ---
function Join-Bytes {
    $ms = [System.IO.MemoryStream]::new()
    foreach ($a in $args) { if ($a -and $a.Length -gt 0) { $ms.Write($a, 0, $a.Length) } }
    $r = $ms.ToArray(); $ms.Dispose(); return ,$r
}

# --- protobuf encode ---
function Encode-Varint([uint64]$v) {
    $b = [System.Collections.Generic.List[byte]]::new()
    while ($v -gt 127) {
        $b.Add([byte](($v -band 0x7F) -bor 0x80))
        $v = $v -shr 7
    }
    $b.Add([byte]$v)
    return ,[byte[]]$b.ToArray()
}

function Encode-Tag([int]$f, [int]$w) { return ,(Encode-Varint ([uint64]($f -shl 3 -bor $w))) }

function Encode-LD([int]$field, [byte[]]$payload) {
    return ,(Join-Bytes (Encode-Tag $field 2) (Encode-Varint ([uint64]$payload.Length)) $payload)
}

function Encode-Str([int]$field, [string]$s) {
    return ,(Encode-LD $field ([System.Text.Encoding]::UTF8.GetBytes($s)))
}

function Encode-UInt([int]$field, [uint64]$v) {
    return ,(Join-Bytes (Encode-Tag $field 0) (Encode-Varint $v))
}

# --- protobuf decode ---
function Decode-Varint([byte[]]$data, [int]$off) {
    [uint64]$r = 0; $s = 0; $p = $off
    do {
        $byte = $data[$p]
        $r = $r -bor (([uint64]($byte -band 0x7F)) -shl $s)
        $s += 7; $p++
    } while ($byte -band 0x80)
    return @{ V = $r; O = $p }
}

function Decode-Proto([byte[]]$data) {
    $fields = [System.Collections.Generic.List[hashtable]]::new()
    $off = 0
    while ($off -lt $data.Length) {
        $tv = Decode-Varint $data $off
        $tag = $tv.V; $off = $tv.O
        $fn = [int]($tag -shr 3); $wt = [int]($tag -band 7)
        if ($fn -eq 0) { break }
        switch ($wt) {
            0 { $vv = Decode-Varint $data $off; $off = $vv.O
                $fields.Add(@{ F=$fn; W=0; V=$vv.V }) }
            2 { $lv = Decode-Varint $data $off; $len=[int]$lv.V; $off=$lv.O
                $d = [byte[]]::new([Math]::Max($len,0))
                if ($len -gt 0) { [Array]::Copy($data, $off, $d, 0, $len) }
                $off += $len
                $fields.Add(@{ F=$fn; W=2; V=$d }) }
            1 { $off += 8 }
            5 { $off += 4 }
            default { break }
        }
    }
    return ,$fields.ToArray()
}

function Get-PField($fields, [int]$n) {
    foreach ($f in $fields) { if ($f.F -eq $n) { return ,$f.V } }
    return $null
}

function Get-PAllFields($fields, [int]$n) {
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $fields) { if ($f.F -eq $n) { $results.Add($f.V) } }
    return ,$results.ToArray()
}

function Get-PStr($fields, [int]$n) {
    $v = Get-PField $fields $n
    if ($v -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($v) }
    return $null
}

# --- gzip ---
function Expand-Gz([byte[]]$data) {
    $mi = [System.IO.MemoryStream]::new($data)
    $gs = [System.IO.Compression.GZipStream]::new($mi, [System.IO.Compression.CompressionMode]::Decompress)
    $mo = [System.IO.MemoryStream]::new()
    $gs.CopyTo($mo); $gs.Dispose(); $mi.Dispose()
    $r = $mo.ToArray(); $mo.Dispose(); return ,$r
}

# --- frame builders ---
function New-Heartbeat([uint64]$rid) {
    return ,(Join-Bytes (Encode-Str 6 "pb") (Encode-Str 7 "hb") (Encode-LD 8 (Encode-UInt 1 $rid)))
}

function New-EnterRoom([uint64]$rid) {
    $inner = Join-Bytes (Encode-UInt 1 $rid) (Encode-UInt 4 12) (Encode-Str 5 "audience") (Encode-Str 9 "0")
    return ,(Join-Bytes (Encode-Str 6 "pb") (Encode-Str 7 "im_enter_room") (Encode-LD 8 $inner))
}

function New-Ack([uint64]$logId, [byte[]]$ext) {
    return ,(Join-Bytes (Encode-Str 6 "pb") (Encode-Str 7 "ack") (Encode-UInt 2 $logId) (Encode-LD 8 $ext))
}

# --- badge decoder ---
function Read-TikTokBadge([byte[]]$data) {
    $f = Decode-Proto $data
    $badge = @{
        DisplayType = Get-PField $f 1
        BadgeScene  = Get-PField $f 3
        Display     = Get-PField $f 11
        Level       = $null
    }
    $logExtra = Get-PField $f 12
    if ($logExtra -is [byte[]]) {
        $lf = Decode-Proto $logExtra
        $badge.Level = Get-PStr $lf 5
    }
    return $badge
}

# --- user decoder (enriched) ---
function Read-TikTokUser([byte[]]$data) {
    $f = Decode-Proto $data
    $user = @{
        UserId       = Get-PField $f 1
        Nickname     = Get-PStr $f 3
        Bio          = Get-PStr $f 5
        Verified     = $false
        UniqueId     = Get-PStr $f 38
        DisplayId    = Get-PStr $f 46
        TopVipNo     = Get-PField $f 31
        PayScore     = Get-PField $f 34
        FanTicket    = Get-PField $f 35
        FollowStatus = Get-PField $f 1024
        IsFollower   = $false
        IsFollowing  = $false
        IsSubscribe  = $false
        GifterLevel  = $null
        MemberLevel  = $null
        IsModerator  = $false
        IsTopGifter  = $false
        FansClubName = $null
        FansClubLevel = $null
        FollowingCount = $null
        FollowerCount  = $null
    }

    $verified = Get-PField $f 12
    if ($verified -ne $null -and $verified -ne 0) { $user.Verified = $true }

    $isFollower = Get-PField $f 1029
    if ($isFollower -ne $null -and $isFollower -ne 0) { $user.IsFollower = $true }

    $isFollowing = Get-PField $f 1030
    if ($isFollowing -ne $null -and $isFollowing -ne 0) { $user.IsFollowing = $true }

    $isSub = Get-PField $f 1090
    if ($isSub -ne $null -and $isSub -ne 0) { $user.IsSubscribe = $true }

    # FollowInfo (tag 22)
    $followInfo = Get-PField $f 22
    if ($followInfo -is [byte[]]) {
        $fi = Decode-Proto $followInfo
        $user.FollowingCount = Get-PField $fi 1
        $user.FollowerCount = Get-PField $fi 2
        $fiStatus = Get-PField $fi 3
        if ($fiStatus -ne $null) { $user.FollowStatus = $fiStatus }
    }

    # FansClub (tag 24 -> tag 1)
    $fansClub = Get-PField $f 24
    if ($fansClub -is [byte[]]) {
        $fc = Decode-Proto $fansClub
        $clubData = Get-PField $fc 1
        if ($clubData -is [byte[]]) {
            $cd = Decode-Proto $clubData
            $user.FansClubName = Get-PStr $cd 1
            $user.FansClubLevel = Get-PField $cd 2
        }
    }

    # Badges (tag 64, repeated)
    $badgeBytes = Get-PAllFields $f 64
    foreach ($bb in $badgeBytes) {
        if ($bb -is [byte[]]) {
            $badge = Read-TikTokBadge $bb
            switch ($badge.BadgeScene) {
                1  { $user.IsModerator = $true }
                6  { $user.IsTopGifter = $true }
                8  { if ($badge.Level) { $user.GifterLevel = $badge.Level } }
                10 { if ($badge.Level) { $user.MemberLevel = $badge.Level } }
            }
        }
    }

    return $user
}

# --- WSS URL builder ---
function Build-WssUrl([string]$cdn, [uint64]$roomId) {
    $tz = Get-SystemTimezone
    $rtt = "{0:F3}" -f (100 + (Get-Random -Minimum 0 -Maximum 100))
    $params = @(
        "version_code=180800"
        "device_platform=web"
        "cookie_enabled=true"
        "screen_width=1920"
        "screen_height=1080"
        "browser_language=en-US"
        "browser_platform=Linux+x86_64"
        "browser_name=Mozilla"
        "browser_version=5.0+(X11)"
        "browser_online=true"
        "tz_name=$([Uri]::EscapeDataString($tz))"
        "app_name=tiktok_web"
        "sup_ws_ds_opt=1"
        "update_version_code=2.0.0"
        "compress=gzip"
        "webcast_language=en"
        "ws_direct=1"
        "aid=1988"
        "live_id=12"
        "app_language=en"
        "client_enter=1"
        "room_id=$roomId"
        "identity=audience"
        "history_comment_count=6"
        "last_rtt=$rtt"
        "heartbeat_duration=10000"
        "resp_content_type=protobuf"
        "did_rule=3"
    ) -join '&'
    return "wss://$cdn/webcast/im/ws_proxy/ws_reuse_supplement/?$params"
}

# --- public functions ---

function Get-TikTokTtwid {
    [CmdletBinding()]
    param(
        [string]$UserAgent
    )
    $ua = if ($UserAgent) { $UserAgent } else { Get-RandomUA }
    $null = Invoke-WebRequest -Uri "https://www.tiktok.com/" -UserAgent $ua -SessionVariable s -UseBasicParsing
    $c = $s.Cookies.GetCookies("https://www.tiktok.com/") | Where-Object Name -eq "ttwid"
    if (-not $c) { throw (New-TikTokError "ConnectFailed" "no ttwid cookie returned from tiktok.com") }
    return $c.Value
}

function Get-TikTokRoomId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Username,
        [string]$UserAgent
    )
    $Username = $Username.TrimStart('@')
    $ua = if ($UserAgent) { $UserAgent } else { Get-RandomUA }
    $url = "https://www.tiktok.com/api-live/user/room?aid=1988&app_name=tiktok_web&device_platform=web_pc&app_language=en&browser_language=en-US&user_is_login=false&sourceType=54&uniqueId=$Username"

    try {
        $resp = Invoke-WebRequest -Uri $url -UserAgent $ua -UseBasicParsing
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 403 -or $status -eq 429) {
            throw (New-TikTokError "TikTokBlocked" "HTTP $status — rate-limited or geo-blocked")
        }
        throw (New-TikTokError "ConnectFailed" "HTTP request failed: $($_.Exception.Message)")
    }

    if (-not $resp.Content -or $resp.Content.Length -eq 0) {
        throw (New-TikTokError "TikTokBlocked" "empty response — IP or fingerprint blocked")
    }

    try {
        $json = $resp.Content | ConvertFrom-Json
    } catch {
        throw (New-TikTokError "TikTokBlocked" "non-JSON response — IP or fingerprint blocked")
    }

    switch ($json.statusCode) {
        0 {}
        19881007 { throw (New-TikTokError "UserNotFound" "'$Username' does not exist") }
        default  { throw (New-TikTokError "ApiError" "statusCode=$($json.statusCode)") }
    }

    $rid = $json.data.user.roomId
    if (-not $rid -or $rid -eq "0") {
        throw (New-TikTokError "HostNotOnline" "'$Username' is not currently live")
    }

    $liveStatus = $json.data.liveRoom.status
    if ($null -eq $liveStatus) { $liveStatus = $json.data.user.status }
    if ($null -ne $liveStatus -and $liveStatus -ne 2) {
        throw (New-TikTokError "HostNotOnline" "'$Username' is not currently live (status=$liveStatus)")
    }

    return [uint64]$rid
}

function Get-TikTokStreamInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [uint64]$RoomId,
        [string]$Cookies = "",
        [string]$UserAgent
    )
    $ua = if ($UserAgent) { $UserAgent } else { Get-RandomUA }
    $tz = [Uri]::EscapeDataString((Get-SystemTimezone))
    $url = "https://webcast.tiktok.com/webcast/room/info/?aid=1988&app_name=tiktok_web&device_platform=web_pc&app_language=en&browser_language=en-US&tz_name=$tz&room_id=$RoomId"
    $headers = @{ "User-Agent" = $ua }
    if ($Cookies) { $headers["Cookie"] = $Cookies }

    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 403 -or $status -eq 429) {
            throw (New-TikTokError "TikTokBlocked" "HTTP $status — rate-limited or geo-blocked")
        }
        throw (New-TikTokError "ConnectFailed" "room info fetch failed: $($_.Exception.Message)")
    }

    $json = $resp.Content | ConvertFrom-Json
    if ($json.status_code -eq 4003110) {
        throw (New-TikTokError "AgeRestricted" "18+ room — pass session cookies via -Cookies 'sessionid=xxx; sid_tt=xxx'")
    }
    if ($json.status_code -and $json.status_code -ne 0) {
        throw (New-TikTokError "ApiError" "room/info status_code=$($json.status_code)")
    }
    return $json.data
}

function Get-TikTokBestStreamUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [object]$RoomInfo,
        [ValidateSet("origin","hd","sd","ld","ao")]
        [string]$Quality = "origin"
    )
    $sdStr = $RoomInfo.stream_url.live_core_sdk_data.pull_data.stream_data
    if (-not $sdStr) { return $null }
    try { $nested = $sdStr | ConvertFrom-Json } catch { return $null }

    $tiers = @("origin","hd","uhd","sd","ld","ao")
    $startIdx = [Array]::IndexOf($tiers, $Quality)
    if ($startIdx -lt 0) { $startIdx = 0 }

    for ($i = $startIdx; $i -lt $tiers.Count; $i++) {
        $tier = $tiers[$i]
        $flv = $nested.data.$tier.main.flv
        if ($flv) { return @{ Quality = $tier; Url = $flv } }
    }
    return $null
}

function Connect-TikTokLive {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string]$Username,
        [uint64]$RoomId = 0,
        [string]$Ttwid = "",
        [string]$UserAgent,
        [string]$Cookies = "",
        [int]$HeartbeatInterval = 10
    )

    $ua = if ($UserAgent) { $UserAgent } else { Get-RandomUA }

    if (-not $Ttwid) {
        $Ttwid = Get-TikTokTtwid -UserAgent $ua
    }

    if ($RoomId -eq 0) {
        if (-not $Username) {
            throw (New-TikTokError "ConnectFailed" "provide -Username or -RoomId")
        }
        $Username = $Username.TrimStart('@')
        $RoomId = Get-TikTokRoomId $Username -UserAgent $ua
    }

    $wsUrl = Build-WssUrl $script:CDN $RoomId

    $conn = @{
        Username  = $Username
        RoomId    = $RoomId
        Ttwid     = $Ttwid
        UserAgent = $ua
        RawMode   = $false
        LastHb    = [DateTime]::UtcNow
        HbSec     = $HeartbeatInterval
        Ws        = $null
        Tcp       = $null
        Ssl       = $null
    }

    $cookieHeader = "ttwid=$Ttwid"
    if ($Cookies) { $cookieHeader = "$cookieHeader; $Cookies" }

    try {
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        try { $ws.Options.SetRequestHeader("User-Agent", $ua) } catch {}
        try { $ws.Options.SetRequestHeader("Origin", "https://www.tiktok.com") } catch {}
        $ck = [System.Net.CookieContainer]::new()
        $ck.Add([System.Net.Cookie]::new("ttwid", $Ttwid, "/", ".tiktok.com"))
        $ws.Options.Cookies = $ck
        $wsUri = [Uri]$wsUrl
        $ws.ConnectAsync($wsUri, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        $conn.Ws = $ws
    } catch {
        # PS 5.1 / Win7 fallback: TcpClient + SslStream + hand-rolled WS framing
        $conn.RawMode = $true
        $wsPath = $wsUrl -replace '^wss://[^/]+', ''
        $tcp = [System.Net.Sockets.TcpClient]::new($script:CDN, 443)
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false)
        $ssl.AuthenticateAsClient($script:CDN, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        $rkey = [byte[]]::new(16); ([System.Random]::new()).NextBytes($rkey)
        $b64 = [Convert]::ToBase64String($rkey)
        $hdr = "GET $wsPath HTTP/1.1`r`nHost: $($script:CDN)`r`nUpgrade: websocket`r`nConnection: Upgrade`r`nSec-WebSocket-Key: ${b64}`r`nSec-WebSocket-Version: 13`r`nUser-Agent: $ua`r`nOrigin: https://www.tiktok.com`r`nCookie: $cookieHeader`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($hdr)
        $ssl.Write($hb, 0, $hb.Length); $ssl.Flush()
        $rb = [byte[]]::new(4096); $n = $ssl.Read($rb, 0, $rb.Length)
        $rs = [System.Text.Encoding]::ASCII.GetString($rb, 0, $n)
        if ($rs -match "DEVICE_BLOCKED") {
            try { $ssl.Dispose() } catch {}
            try { $tcp.Dispose() } catch {}
            throw (New-TikTokError "DeviceBlocked" "DEVICE_BLOCKED — fetch fresh ttwid and retry")
        }
        if ($rs -notmatch "101") {
            try { $ssl.Dispose() } catch {}
            try { $tcp.Dispose() } catch {}
            throw (New-TikTokError "ConnectFailed" "WS handshake failed: $($rs.Split("`n")[0])")
        }
        $conn.Tcp = $tcp
        $conn.Ssl = $ssl
    }

    # send heartbeat + enter room
    Send-TikTokWsRaw $conn (New-Heartbeat $RoomId)
    Start-Sleep -Milliseconds 200
    Send-TikTokWsRaw $conn (New-EnterRoom $RoomId)

    return $conn
}

# --- internal ws send/receive (not exported) ---
function Send-TikTokWsRaw($conn, [byte[]]$data) {
    if ($conn.RawMode) {
        $len = $data.Length; $h = [System.Collections.Generic.List[byte]]::new()
        $h.Add(0x82)
        if ($len -lt 126) { $h.Add([byte](0x80 -bor $len)) }
        elseif ($len -lt 65536) { $h.Add(0xFE); $h.Add([byte]($len -shr 8)); $h.Add([byte]($len -band 0xFF)) }
        $mask = [byte[]]::new(4); ([System.Random]::new()).NextBytes($mask); $h.AddRange($mask)
        $masked = [byte[]]::new($len)
        for ($i = 0; $i -lt $len; $i++) { $masked[$i] = $data[$i] -bxor $mask[$i % 4] }
        $all = Join-Bytes $h.ToArray() $masked
        $conn.Ssl.Write($all, 0, $all.Length); $conn.Ssl.Flush()
    } else {
        $seg = [ArraySegment[byte]]::new($data)
        $conn.Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Binary, $true,
            [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    }
}

function Receive-TikTokWsRaw($conn, [int]$timeoutMs = 2000) {
    if ($conn.RawMode) {
        $conn.Tcp.ReceiveTimeout = $timeoutMs
        try {
            $hdr = [byte[]]::new(2)
            $n = $conn.Ssl.Read($hdr, 0, 2); if ($n -lt 2) { return $null }
            if (($hdr[0] -band 0x0F) -eq 8) { return $null }
            [int]$plen = $hdr[1] -band 0x7F
            if ($plen -eq 126) {
                $ext = [byte[]]::new(2); $conn.Ssl.Read($ext, 0, 2) | Out-Null
                $plen = ([int]$ext[0] -shl 8) -bor $ext[1]
            } elseif ($plen -eq 127) {
                $ext = [byte[]]::new(8); $conn.Ssl.Read($ext, 0, 8) | Out-Null
                [int64]$plen = 0; for ($i = 0; $i -lt 8; $i++) { $plen = ($plen -shl 8) -bor $ext[$i] }
            }
            $payload = [byte[]]::new($plen); $rd = 0
            while ($rd -lt $plen) {
                $n = $conn.Ssl.Read($payload, $rd, $plen - $rd)
                if ($n -le 0) { return $null }; $rd += $n
            }
            return ,$payload
        } catch [System.IO.IOException] { return ,[byte[]]@() }
        catch { return $null }
    } else {
        $buf = [byte[]]::new(65536)
        $ms = [System.IO.MemoryStream]::new()
        $cts = [System.Threading.CancellationTokenSource]::new($timeoutMs)
        try {
            do {
                $seg = [ArraySegment[byte]]::new($buf)
                $res = $conn.Ws.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
                if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
                $ms.Write($buf, 0, $res.Count)
            } while (-not $res.EndOfMessage)
            return ,[byte[]]$ms.ToArray()
        } catch [System.OperationCanceledException] { return ,[byte[]]@() }
        catch { return $null }
        finally { $cts.Dispose(); $ms.Dispose() }
    }
}

function Send-TikTokHeartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [hashtable]$Connection
    )
    Send-TikTokWsRaw $Connection (New-Heartbeat $Connection.RoomId)
    $Connection.LastHb = [DateTime]::UtcNow
}

function Receive-TikTokFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [hashtable]$Connection,
        [int]$TimeoutMs = 2000
    )

    # auto-heartbeat
    if (([DateTime]::UtcNow - $Connection.LastHb).TotalSeconds -ge $Connection.HbSec) {
        Send-TikTokHeartbeat $Connection
    }

    $raw = Receive-TikTokWsRaw $Connection $TimeoutMs
    if ($null -eq $raw) { return $null }
    if ($raw.Length -eq 0) { return ,@([hashtable[]]@()) }

    $outer = Decode-Proto $raw
    $ptype = Get-PStr $outer 7
    if ($ptype -ne "msg") { return ,@([hashtable[]]@()) }

    $payload = Get-PField $outer 8
    if (-not ($payload -is [byte[]])) { return ,@([hashtable[]]@()) }

    # gzip decompress
    if ($payload.Length -ge 2 -and $payload[0] -eq 0x1f -and $payload[1] -eq 0x8b) {
        $payload = Expand-Gz $payload
    }

    $resp = Decode-Proto $payload

    # ack if needed
    $needAck = Get-PField $resp 9
    $intExt = Get-PField $resp 5
    if ($needAck -eq 1 -and $intExt -is [byte[]]) {
        $logId = Get-PField $outer 2
        if ($logId) {
            try { Send-TikTokWsRaw $Connection (New-Ack ([uint64]$logId) $intExt) } catch {}
        }
    }

    # parse messages
    $events = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($f in $resp) {
        if ($f.F -eq 1 -and $f.W -eq 2) {
            $mf = Decode-Proto $f.V
            $method = Get-PStr $mf 1
            $mp = Get-PField $mf 2
            if (-not $method -or -not ($mp -is [byte[]])) { continue }

            $evt = @{ Method = $method; RawPayload = $mp }

            switch ($method) {
                "WebcastChatMessage" {
                    $pf = Decode-Proto $mp
                    $evt.User = if ((Get-PField $pf 2) -is [byte[]]) { Read-TikTokUser (Get-PField $pf 2) } else { $null }
                    $evt.Content = Get-PStr $pf 3
                }
                "WebcastGiftMessage" {
                    $pf = Decode-Proto $mp
                    $evt.User = if ((Get-PField $pf 7) -is [byte[]]) { Read-TikTokUser (Get-PField $pf 7) } else { $null }
                    $evt.RepeatCount = Get-PField $pf 5
                    $evt.ComboCount = Get-PField $pf 8
                    $evt.IsCombo = ((Get-PField $pf 9) -eq 1)
                    $evt.GiftId = Get-PField $pf 1
                    $gb = Get-PField $pf 15
                    if ($gb -is [byte[]]) {
                        $gf = Decode-Proto $gb
                        $evt.GiftName = Get-PStr $gf 16
                        $evt.DiamondCount = Get-PField $gf 12
                    }
                }
                "WebcastLikeMessage" {
                    $pf = Decode-Proto $mp
                    $evt.User = if ((Get-PField $pf 5) -is [byte[]]) { Read-TikTokUser (Get-PField $pf 5) } else { $null }
                    $evt.TotalLikes = Get-PField $pf 3
                    $evt.Count = Get-PField $pf 1
                }
                "WebcastMemberMessage" {
                    $pf = Decode-Proto $mp
                    $evt.User = if ((Get-PField $pf 2) -is [byte[]]) { Read-TikTokUser (Get-PField $pf 2) } else { $null }
                    $evt.Action = Get-PField $pf 10
                }
                "WebcastSocialMessage" {
                    $pf = Decode-Proto $mp
                    $evt.User = if ((Get-PField $pf 2) -is [byte[]]) { Read-TikTokUser (Get-PField $pf 2) } else { $null }
                    $evt.Action = Get-PField $pf 4
                }
                "WebcastRoomUserSeqMessage" {
                    $pf = Decode-Proto $mp
                    $evt.ViewerCount = Get-PField $pf 3
                }
                "WebcastControlMessage" {
                    $pf = Decode-Proto $mp
                    $evt.Action = Get-PField $pf 2
                }
            }

            $events.Add($evt)

            # sub-routed convenience events (both raw + convenience fire)
            switch ($method) {
                "WebcastSocialMessage" {
                    $act = $evt.Action
                    if ($act -eq 1) {
                        $events.Add(@{ Method = "Follow"; User = $evt.User; RawPayload = $mp })
                    } elseif ($act -eq 3 -or $act -eq 4) {
                        $events.Add(@{ Method = "Share"; User = $evt.User; RawPayload = $mp })
                    }
                }
                "WebcastMemberMessage" {
                    if ($evt.Action -eq 1) {
                        $events.Add(@{ Method = "Join"; User = $evt.User; RawPayload = $mp })
                    }
                }
                "WebcastControlMessage" {
                    if ($evt.Action -eq 3) {
                        $events.Add(@{ Method = "LiveEnded"; RawPayload = $mp })
                    }
                }
            }
        }
    }
    return ,$events.ToArray()
}

function Close-TikTokLive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [hashtable]$Connection
    )
    if ($Connection.RawMode) {
        try { $Connection.Ssl.Dispose() } catch {}
        try { $Connection.Tcp.Dispose() } catch {}
    } else {
        if ($Connection.Ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try { $Connection.Ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "",
                [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null } catch {}
        }
        $Connection.Ws.Dispose()
    }
}
