# Poll-based live client: Connect-TikTokLive → loop Receive-TikTokEvent → Disconnect-TikTokLive.
# Reconnect policy (W1): ttwid + UA are fetched once and reused across reconnects; they
# rotate only on DEVICE_BLOCKED or when a session died within 30 s. MaxRetries bounds
# *consecutive* failures — a session that stayed up 30 s resets the counter. A ttwid
# failure is a failed attempt (Reconnecting fires), never an abort.

$script:HealthySessionSecs = 30
$script:DeviceBlockedDelaySecs = 2
$script:MaxBackoffSecs = 30

# Hooks (tests swap these): clock, sleep-while-waiting, and the WSS transport.
$script:Clock = { [DateTime]::UtcNow }
$script:WsOpen = { param($Url, $Cookie, $UserAgent, $Proxy, $AcceptLanguage, $TimeoutSec)
    Open-TikTokWebSocket -Url $Url -Cookie $Cookie -UserAgent $UserAgent -Proxy $Proxy -AcceptLanguage $AcceptLanguage -TimeoutSec $TimeoutSec }
$script:WsSend = { param($Ws, [byte[]]$Data) Send-TikTokWsFrame $Ws $Data }
$script:WsReceive = { param($Ws, [int]$TimeoutMs) Receive-TikTokWsMessages $Ws $TimeoutMs }
$script:WsClose = { param($Ws, [bool]$Graceful) Close-TikTokWebSocket $Ws -Graceful:$Graceful }

function Add-TikTokClientEvent($Client, [string]$Type, $Data) {
    $Client.Queue.Add((New-TikTokEvent $Type '' $Data $null))
}

function Connect-TikTokLive {
    <#
    .SYNOPSIS
    Resolve the user's live room and open the event stream (ttwid-only WSS, no cookies
    needed). Returns a client; poll it with Receive-TikTokEvent. Throws UserNotFound /
    HostNotOnline / ApiError / TikTokBlocked when the room cannot be resolved.
    -Cookies are appended to the WSS cookie header; they are only required for
    Get-TikTokRoomInfo on 18+ rooms and Get-TikTokRoomAudience.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Username,
        [ValidateSet('global', 'eu', 'us')][string]$Cdn = 'global',
        [int]$TimeoutSec = 10,
        [double]$HeartbeatInterval = 10,
        [double]$StaleTimeout = 60,
        [int]$MaxRetries = 5,
        [string]$Proxy,
        [string]$UserAgent,
        [string]$Cookies,
        [string]$Language,
        [string]$Region,
        [switch]$NoCompress
    )
    $lang, $reg = Resolve-TikTokLocale $Language $Region
    $client = [pscustomobject]@{
        Username = $Username.Trim().TrimStart('@'); CdnHost = $script:CdnHosts[$Cdn]; TimeoutSec = $TimeoutSec
        HeartbeatInterval = $HeartbeatInterval; StaleTimeout = $StaleTimeout; MaxRetries = $MaxRetries
        Proxy = $Proxy; UserAgent = $UserAgent; Cookies = $Cookies; Language = $lang; Region = $reg
        Compress = -not $NoCompress
        RoomId = $null; AnchorId = $null; State = 'Connecting'; Attempt = 0; Session = $null
        Ws = $null; ConnectedAt = $null; ReconnectAt = $null; LastData = $null; LastHeartbeat = $null
        Queue = [System.Collections.Generic.List[object]]::new()
    }
    $room = Get-TikTokRoomId $client.Username -UserAgent $UserAgent -Proxy $Proxy -TimeoutSec $TimeoutSec -Language $lang -Region $reg
    $client.RoomId = $room.RoomId
    $client.AnchorId = $room.AnchorId
    Add-TikTokClientEvent $client 'Connected' @{ room_id = $room.RoomId; anchor_id = $room.AnchorId }
    Invoke-TikTokConnectAttempt $client
    return $client
}

# One connection attempt with the held (or a fresh) ttwid + UA.
function Invoke-TikTokConnectAttempt($Client) {
    $now = & $script:Clock
    if (-not $Client.Session) {
        $ua = if ($Client.UserAgent) { $Client.UserAgent } else { Get-TikTokRandomUserAgent }
        try {
            $ttwid = Get-TikTokTtwid -UserAgent $ua -Proxy $Client.Proxy -TimeoutSec $Client.TimeoutSec
        } catch [PirateTok.Live.TikTokLiveException] {
            Start-TikTokReconnect $Client "ttwid acquisition failed: $($_.Exception.Message)"
            return
        }
        $Client.Session = @{ Ttwid = $ttwid; UserAgent = $ua }
    }

    $cookie = "ttwid=$($Client.Session.Ttwid)"
    if ($Client.Cookies) { $cookie = "$cookie; $($Client.Cookies)" }
    $url = New-TikTokWsUrl -CdnHost $Client.CdnHost -RoomId $Client.RoomId -Language $Client.Language `
        -Region $Client.Region -Compress $Client.Compress -HeartbeatInterval $Client.HeartbeatInterval
    $acceptLanguage = "$($Client.Language)-$($Client.Region),$($Client.Language);q=0.9"
    try {
        $Client.Ws = & $script:WsOpen $url $cookie $Client.Session.UserAgent $Client.Proxy $acceptLanguage $Client.TimeoutSec
        $Client.State = 'Connected'
        $Client.ConnectedAt = $now
        $Client.LastData = $now
        & $script:WsSend $Client.Ws (New-TikTokHeartbeatFrame $Client.RoomId)
        & $script:WsSend $Client.Ws (New-TikTokEnterRoomFrame $Client.RoomId)
        $Client.LastHeartbeat = $now
    } catch {
        $blocked = $_.Exception -is [PirateTok.Live.TikTokLiveException] -and $_.Exception.ErrorKind -eq 'DeviceBlocked'
        Start-TikTokReconnect $Client $_.Exception.GetBaseException().Message -DeviceBlocked:$blocked
    }
}

function Start-TikTokReconnect($Client, [string]$Reason, [switch]$DeviceBlocked) {
    if ($Client.Ws) { & $script:WsClose $Client.Ws $false; $Client.Ws = $null }
    $now = & $script:Clock
    $healthy = $null -ne $Client.ConnectedAt -and ($now - $Client.ConnectedAt).TotalSeconds -ge $script:HealthySessionSecs
    $Client.ConnectedAt = $null

    if ($DeviceBlocked -or -not $healthy) { $Client.Session = $null }
    $Client.Attempt = if ($healthy -and -not $DeviceBlocked) { 1 } else { $Client.Attempt + 1 }
    if ($Client.Attempt -gt $Client.MaxRetries) {
        $Client.State = 'Disconnected'
        Add-TikTokClientEvent $Client 'Disconnected' @{ reason = $Reason }
        return
    }
    $delay = if ($DeviceBlocked) { $script:DeviceBlockedDelaySecs } else { [Math]::Min([Math]::Pow(2, $Client.Attempt), $script:MaxBackoffSecs) }
    $Client.State = 'Reconnecting'
    $Client.ReconnectAt = $now.AddSeconds($delay)
    Add-TikTokClientEvent $Client 'Reconnecting' @{
        attempt = $Client.Attempt; max_retries = $Client.MaxRetries; delay_secs = $delay
        reason = $Reason; device_blocked = [bool]$DeviceBlocked
    }
}

# Decode one WSS binary message into events (acks when TikTok asks).
function Invoke-TikTokPushFrame($Client, [byte[]]$Raw) {
    $frame = ConvertFrom-TikTokProto 'WebcastPushFrame' $Raw
    switch ($frame.payload_type) {
        'im_enter_room_resp' { Add-TikTokClientEvent $Client 'RoomEntered' @{} }
        'msg' {
            $resp = ConvertFrom-TikTokProto 'PsWebcastResponse' (Expand-TikTokGzip $frame.payload)
            if ($resp.needs_ack -and $resp.internal_ext.Length -gt 0) {
                & $script:WsSend $Client.Ws (New-TikTokAckFrame $frame.log_id $resp.internal_ext)
            }
            foreach ($msg in $resp.messages) {
                foreach ($evt in (ConvertTo-TikTokEvents -Method $msg.type -Payload $msg.payload)) { $Client.Queue.Add($evt) }
            }
        }
    }
}

function Receive-TikTokEvent {
    <#
    .SYNOPSIS
    Poll the client: waits up to -TimeoutMs for data and returns the events that arrived
    (possibly none). Handles heartbeats, stale detection, acks and reconnects. Lifecycle
    events: Connected, RoomEntered, Reconnecting, Disconnected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)]$Client, [int]$TimeoutMs = 1000)

    $now = & $script:Clock
    if ($Client.State -eq 'Reconnecting') {
        $waitMs = [int][Math]::Min(($Client.ReconnectAt - $now).TotalMilliseconds, $TimeoutMs)
        if ($waitMs -gt 0) { & $script:SleepMs $waitMs; $now = & $script:Clock }
        if ($now -ge $Client.ReconnectAt) { Invoke-TikTokConnectAttempt $Client }
    } elseif ($Client.State -eq 'Connected') {
        Receive-TikTokConnected $Client $now $TimeoutMs
    }
    $out = $Client.Queue.ToArray()
    $Client.Queue.Clear()
    return $out
}

function Receive-TikTokConnected($Client, [datetime]$Now, [int]$TimeoutMs) {
    try {
        if (($Now - $Client.LastHeartbeat).TotalSeconds -ge $Client.HeartbeatInterval) {
            & $script:WsSend $Client.Ws (New-TikTokHeartbeatFrame $Client.RoomId)
            $Client.LastHeartbeat = $Now
        }
        if (($Now - $Client.LastData).TotalSeconds -gt $Client.StaleTimeout) {
            Start-TikTokReconnect $Client "stale — no data for $($Client.StaleTimeout)s"
            return
        }
        $messages = & $script:WsReceive $Client.Ws $TimeoutMs
        if ($messages.Count -gt 0) { $Client.LastData = & $script:Clock }
        foreach ($raw in $messages) {
            # a corrupt frame is reported, not fatal to the connection
            try { Invoke-TikTokPushFrame $Client $raw }
            catch [System.Management.Automation.MethodInvocationException] {
                Add-TikTokClientEvent $Client 'Error' @{ reason = "frame decode failed: $($_.Exception.GetBaseException().Message)"; payload = $raw }
            }
        }
        if ($Client.Ws.Closed) { Start-TikTokReconnect $Client 'connection closed by server' }
    } catch {
        Start-TikTokReconnect $Client "connection error: $($_.Exception.GetBaseException().Message)"
    }
}

function Disconnect-TikTokLive {
    <# .SYNOPSIS Stop the client: closes the WSS and ends the reconnect loop. #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)]$Client)
    if ($Client.State -eq 'Disconnected') { return }
    if ($Client.Ws) { & $script:WsClose $Client.Ws $true; $Client.Ws = $null }
    $Client.State = 'Disconnected'
    Add-TikTokClientEvent $Client 'Disconnected' @{ reason = 'disconnect requested' }
}

function Start-TikTokLive {
    <#
    .SYNOPSIS
    Blocking event loop: runs -OnEvent for every event until the client disconnects
    (max retries exhausted, or Disconnect-TikTokLive from inside the handler).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)]$Client, [Parameter(Mandatory)][scriptblock]$OnEvent)
    while ($true) {
        foreach ($evt in (Receive-TikTokEvent $Client)) { & $OnEvent $evt }
        if ($Client.State -eq 'Disconnected' -and $Client.Queue.Count -eq 0) { break }
    }
}
