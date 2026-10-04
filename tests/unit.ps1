#!/usr/bin/env pwsh
# Offline unit tests — no TikTok traffic. ttwid runs against a real local HTTP responder;
# the client loop runs on a fake clock + scripted fake WSS transport.
# Usage: pwsh tests/unit.ps1   (from the live-ps1 root)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../PirateTok.Live.psd1') -Force
$module = Get-Module PirateTok.Live
$script:passed = 0; $script:failed = 0

function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $module $Body; $script:passed++; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name`: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
}

# Runs inside the module scope (via & $module) — assertion helper defined there too.
& $module {
    function script:Check($Cond, [string]$Label) { if (-not $Cond) { throw "assertion failed: $Label" } }
    function script:ErrKind([scriptblock]$Block) {
        try { & $Block; return '<no error>' } catch [PirateTok.Live.TikTokLiveException] { return $_.Exception.ErrorKind }
    }
}

# ---- local fake HTTP responder (separate runspace) ----

function Start-FakeHttp([string[]]$Responses) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $state = [hashtable]::Synchronized(@{ Requests = 0 })
    $ps = [powershell]::Create().AddScript({
        param($listener, $responses, $state)
        $i = 0
        while ($true) {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $buf = [byte[]]::new(8192); $null = $stream.Read($buf, 0, $buf.Length)
            $state.Requests++
            $kind = $responses[[Math]::Min($i, $responses.Count - 1)]; $i++
            $cookie = if ($kind -eq 'cookie') { "Set-Cookie: ttwid=1%7Cfake%7C123; Path=/; Secure`r`n" } else { '' }
            $resp = "HTTP/1.1 200 OK`r`nSet-Cookie: msToken=x; Path=/`r`n${cookie}Content-Length: 2`r`nConnection: close`r`n`r`nok"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($resp)
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush(); $client.Close()
        }
    }).AddArgument($listener).AddArgument($Responses).AddArgument($state)
    $null = $ps.BeginInvoke()
    return @{ Url = "http://127.0.0.1:$($listener.LocalEndpoint.Port)/"; State = $state; Listener = $listener; Ps = $ps }
}

function Stop-FakeHttp($Fake) { $Fake.Listener.Stop(); $Fake.Ps.Stop(); $Fake.Ps.Dispose() }

# ---- W1: ttwid retry ----

# test bodies run in the module's session state, so the fake server handle is global
$global:FakeHttp = Start-FakeHttp @('none', 'none', 'none', 'cookie')
Test-Case 'ttwid: missing cookie x3 then cookie -> ok on 4th request' {
    $sleeps = [ref]0
    $script:SleepMs = { param($ms) $sleeps.Value++ }.GetNewClosure()
    $ttwid = Get-TikTokTtwid -Url $global:FakeHttp.Url -TimeoutSec 5
    Check ($ttwid -eq '1%7Cfake%7C123') "ttwid value: $ttwid"
    Check ($global:FakeHttp.State.Requests -eq 4) "4 requests, got $($global:FakeHttp.State.Requests)"
    Check ($sleeps.Value -eq 3) "3 retry sleeps, got $($sleeps.Value)"
}
Stop-FakeHttp $global:FakeHttp

$global:FakeHttp = Start-FakeHttp @('none')
Test-Case 'ttwid: never a cookie -> InvalidResponse after 8 requests' {
    $script:SleepMs = { param($ms) }
    $kind = ErrKind { Get-TikTokTtwid -Url $global:FakeHttp.Url -TimeoutSec 5 }
    Check ($kind -eq 'InvalidResponse') "kind $kind"
    Check ($global:FakeHttp.State.Requests -eq 8) "8 requests, got $($global:FakeHttp.State.Requests)"
}
Stop-FakeHttp $global:FakeHttp

Test-Case 'ttwid: transport error propagates without retry' {
    $sleeps = [ref]0
    $script:SleepMs = { param($ms) $sleeps.Value++ }.GetNewClosure()
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $l.Start()
    $port = $l.LocalEndpoint.Port; $l.Stop()
    $kind = ErrKind { Get-TikTokTtwid -Url "http://127.0.0.1:$port/" -TimeoutSec 5 }
    Check ($kind -eq 'HttpError') "kind $kind"
    Check ($sleeps.Value -eq 0) 'no retry sleep'
}

# ---- W1: reconnect loop on fake clock + fake WSS ----

& $module {
    # $Dials: 'ok' | 'fail' | 'blocked' per WSS dial (last one repeats). $Ttwid: 'ok' | 'none'.
    function script:New-ScriptedClient([string[]]$Dials, [int]$MaxRetries = 5, [string]$Ttwid = 'ok') {
        $log = @{ Fetches = 0; Dials = 0; Uas = [System.Collections.Generic.List[string]]::new(); Cookies = [System.Collections.Generic.List[string]]::new(); Now = [datetime]'2026-10-04T12:00:00Z' }
        $script:FakeLog = $log
        $script:Clock = { $script:FakeLog.Now }
        $script:SleepMs = { param($ms) $script:FakeLog.Now = $script:FakeLog.Now.AddMilliseconds($ms) }
        $script:HttpGet = {
            param($Url, $Headers, $Proxy, $TimeoutSec)
            if ($Url -like '*api-live/user/room*') {
                return @{ Status = 200; SetCookies = @(); Body = '{"statusCode":0,"data":{"user":{"id":"690001","roomId":"730002","status":2},"liveRoom":{"status":2}}}' }
            }
            $script:FakeLog.Fetches++
            if ($script:FakeTtwid -eq 'none') { return @{ Status = 200; SetCookies = @('msToken=x'); Body = '' } }
            return @{ Status = 200; SetCookies = @("ttwid=tt$($script:FakeLog.Fetches); Path=/"); Body = '' }
        }
        $script:FakeTtwid = $Ttwid
        $script:FakeDials = $Dials
        $script:WsOpen = { param($Url, $Cookie, $UserAgent)
            $log = $script:FakeLog; $log.Dials++; $log.Uas.Add($UserAgent); $log.Cookies.Add($Cookie)
            $r = $script:FakeDials[[Math]::Min($log.Dials, $script:FakeDials.Count) - 1]
            if ($r -eq 'blocked') { throw (New-TikTokError 'DeviceBlocked' 'DEVICE_BLOCKED') }
            if ($r -eq 'fail') { throw (New-TikTokError 'WebSocketError' 'handshake failed: HTTP/1.1 500') }
            return @{ Closed = $false }
        }
        $script:WsSend = { param($Ws, $Data) }
        $script:WsReceive = { param($Ws, $TimeoutMs) $script:FakeLog.Now = $script:FakeLog.Now.AddMilliseconds($TimeoutMs); return , @() }
        $script:WsClose = { param($Ws, $Graceful) $Ws.Closed = $true }
        $client = Connect-TikTokLive someone -MaxRetries $MaxRetries -Language en -Region US
        return @($client, $log)
    }
    function script:Get-Reconnects($Events) { return , @($Events | Where-Object Type -eq 'Reconnecting' | ForEach-Object Data) }
    function script:Advance($Log, [double]$Secs) { $Log.Now = $Log.Now.AddSeconds($Secs) }
}

Test-Case 'loop: consecutive failures accumulate with backoff' {
    $client, $log = New-ScriptedClient @('fail')
    $evts = @(Receive-TikTokEvent $client -TimeoutMs 0)
    foreach ($i in 1..2) { $evts += Receive-TikTokEvent $client -TimeoutMs 60000 }
    $rc = Get-Reconnects $evts
    Check ($rc.Count -eq 3) "3 reconnecting, got $($rc.Count)"
    Check (($rc | ForEach-Object { "$($_.attempt)/$($_.delay_secs)" }) -join ',' -eq '1/2,2/4,3/8') ($rc | ForEach-Object { "$($_.attempt)/$($_.delay_secs)" }) -join ','
}

Test-Case 'loop: max_retries exceeded -> Disconnected' {
    $client, $log = New-ScriptedClient @('fail') -MaxRetries 2
    $evts = @(Receive-TikTokEvent $client -TimeoutMs 0)
    foreach ($i in 1..3) { $evts += Receive-TikTokEvent $client -TimeoutMs 60000 }
    Check ((Get-Reconnects $evts).Count -eq 2) '2 reconnecting'
    Check (@($evts | Where-Object Type -eq 'Disconnected').Count -eq 1) 'one Disconnected'
    Check ($client.State -eq 'Disconnected') 'state'
}

Test-Case 'loop: healthy session resets counter, keeps ttwid + UA' {
    $client, $log = New-ScriptedClient @('fail', 'fail', 'ok', 'ok')
    $null = Receive-TikTokEvent $client -TimeoutMs 60000   # dial 2 fails (attempt 2)
    $null = Receive-TikTokEvent $client -TimeoutMs 60000   # dial 3 ok
    Check ($client.State -eq 'Connected') "connected, got $($client.State)"
    $fetches = $log.Fetches
    Advance $log 45
    Start-TikTokReconnect $client 'stale'
    $rc = Get-Reconnects (Receive-TikTokEvent $client -TimeoutMs 0)
    Check ($rc[0].attempt -eq 1 -and $rc[0].delay_secs -eq 2) "reset to attempt 1/2s, got $($rc[0].attempt)/$($rc[0].delay_secs)"
    $null = Receive-TikTokEvent $client -TimeoutMs 60000
    Check ($log.Fetches -eq $fetches) 'ttwid reused (no new fetch)'
    Check ($log.Uas[-1] -eq $log.Uas[-2] -and $log.Cookies[-1] -eq $log.Cookies[-2]) 'same UA + ttwid on the wire'
}

Test-Case 'loop: short-lived session counts as failure and rotates ttwid' {
    $client, $log = New-ScriptedClient @('ok')
    Advance $log 5
    Start-TikTokReconnect $client 'read error'
    Check ($client.Attempt -eq 1 -and $null -eq $client.Session) 'attempt 1, session dropped'
    $null = Receive-TikTokEvent $client -TimeoutMs 60000
    Check ($log.Fetches -eq 2) "fresh ttwid fetched, fetches=$($log.Fetches)"
}

Test-Case 'loop: DEVICE_BLOCKED rotates ttwid + UA with 2s delay' {
    $client, $log = New-ScriptedClient @('blocked', 'ok')
    $rc = Get-Reconnects (Receive-TikTokEvent $client -TimeoutMs 0)
    Check ($rc[0].device_blocked -and $rc[0].delay_secs -eq 2) 'blocked, 2s'
    $null = Receive-TikTokEvent $client -TimeoutMs 3000
    Check ($log.Fetches -eq 2 -and $log.Cookies[-1] -eq 'ttwid=tt2') "fresh ttwid on the wire: $($log.Cookies[-1])"
}

Test-Case 'loop: ttwid failure on connect is a failed attempt, not an abort' {
    $client, $log = New-ScriptedClient @('ok') -Ttwid 'none'
    $evts = Receive-TikTokEvent $client -TimeoutMs 0
    Check ($client.State -eq 'Reconnecting') "state $($client.State)"
    Check ((Get-Reconnects $evts).Count -eq 1) 'Reconnecting emitted'
    Check ($log.Fetches -eq 8 -and $log.Dials -eq 0) "8 ttwid requests, no dial ($($log.Fetches)/$($log.Dials))"
}

Test-Case 'loop: stale timeout triggers reconnect; Disconnect stops it' {
    $client, $log = New-ScriptedClient @('ok')
    Advance $log 61
    $rc = Get-Reconnects (Receive-TikTokEvent $client -TimeoutMs 0)
    Check ($rc.Count -eq 1 -and $rc[0].reason -like 'stale*') 'stale reconnect'
    Disconnect-TikTokLive $client
    $evts = Receive-TikTokEvent $client
    Check ($client.State -eq 'Disconnected' -and $evts[-1].Type -eq 'Disconnected') 'disconnected'
}

Test-Case 'url: heartbeat_duration follows HeartbeatInterval; compress toggle' {
    $u = New-TikTokWsUrl -CdnHost h -RoomId 1 -HeartbeatInterval 7 -Compress $false
    Check ($u -match 'heartbeat_duration=7000&' -and $u -match 'compress=&') $u
}

# ---- push frames: ack is byte-exact ----

Test-Case 'push frame: needs_ack sends ack with exact internal_ext bytes' {
    $ext = [byte[]]@(0xFF, 0x00, 0xC3, 0x28)
    $resp = ConvertTo-TikTokProto 'PsWebcastResponse' @{ internal_ext = $ext; needs_ack = $true }
    $raw = ConvertTo-TikTokProto 'WebcastPushFrame' @{ log_id = 42; payload_type = 'msg'; payload = $resp }
    $sent = [System.Collections.Generic.List[byte[]]]::new()
    $script:WsSend = { param($Ws, $Data) $sent.Add($Data) }.GetNewClosure()
    $client = [pscustomobject]@{ Ws = @{}; Queue = [System.Collections.Generic.List[object]]::new() }
    Invoke-TikTokPushFrame $client $raw
    $ack = ConvertFrom-TikTokProto 'WebcastPushFrame' $sent[0]
    Check ($ack.payload_type -eq 'ack' -and $ack.log_id -eq 42) 'ack frame'
    Check ([Convert]::ToBase64String($ack.payload) -eq [Convert]::ToBase64String($ext)) 'payload byte-exact'
}

# ---- WebSocket framing ----

Test-Case 'ws: parses 16-bit length + fragmented frames, answers ping' {
    $big = [byte[]]::new(300); for ($i = 0; $i -lt 300; $i++) { $big[$i] = $i % 251 }
    $ms = [System.IO.MemoryStream]::new()
    $ms.Write([byte[]]@(0x02, 0x7E, 0x01, 0x2C), 0, 4); $ms.Write($big, 0, 300)              # binary, FIN=0, len 300
    $ms.Write([byte[]]@(0x89, 0x01, 0x07), 0, 3)                                               # ping
    $ms.Write([byte[]]@(0x80, 0x02, 0xAA, 0xBB), 0, 4)                                         # continuation, FIN
    $ws = @{ Buf = [System.IO.MemoryStream]::new(); Fragments = $null; Closed = $false }
    $ws.Buf.Write($ms.ToArray(), 0, [int]$ms.Length)
    $f1 = Pop-TikTokWsFrame $ws; $f2 = Pop-TikTokWsFrame $ws; $f3 = Pop-TikTokWsFrame $ws
    Check ($f1.Opcode -eq 2 -and -not $f1.Fin -and $f1.Payload.Length -eq 300 -and $f1.Payload[299] -eq (299 % 251)) 'frame 1'
    Check ($f2.Opcode -eq 9 -and $f2.Payload[0] -eq 7) 'ping'
    Check ($f3.Opcode -eq 0 -and $f3.Fin -and $f3.Payload.Length -eq 2) 'continuation'
    Check ($null -eq (Pop-TikTokWsFrame $ws)) 'buffer drained'
}

# ---- W4: ranks_list + top viewers ----

Test-Case 'ranks_list decodes; top viewers skip userless and sort by rank' {
    $c = { param($rank, $score, $nick) @{ rank = $rank; score = $score; delta = 0; user = $(if ($nick) { @{ id = $rank * 11; nickname = $nick } } else { $null }) } }
    $payload = ConvertTo-TikTokProto 'WebcastRoomUserSeqMessage' @{
        ranks_list = @((& $c 3 300 'c'), (& $c 1 900 'a'), (& $c 4 50 $null), (& $c 2 600 'b'))
        viewer_count = 1234; pop_str = '1.2K'; total_user = 5678; anonymous = 9
    }
    $evt = (ConvertTo-TikTokEvents -Method 'WebcastRoomUserSeqMessage' -Payload $payload)[0]
    Check ($evt.Type -eq 'RoomUserSeq' -and $evt.Data.ranks_list.Count -eq 4) 'decoded'
    Check ($evt.Data.viewer_count -eq 1234 -and $evt.Data.total_user -eq 5678 -and $evt.Data.pop_str -eq '1.2K' -and $evt.Data.anonymous -eq 9) 'counts'
    $top = Get-TikTokTopViewers $evt.Data
    Check ((($top | ForEach-Object { $_.user.nickname }) -join '') -eq 'abc') 'sorted, userless skipped'
    Check ($top[0].score -eq 900) 'score'
}

# ---- W5: audience parsing ----

Test-Case 'audience: status 0 parses viewers, skips rank without user' {
    $body = '{"status_code":0,"data":{"total":42,"anonymous":7,"ranks":[{"rank":1,"score":500,"user":{"id_str":"7200000000000000001","display_id":"viewer_one","nickname":"One","sec_uid":"MS4w","avatar_thumb":{"url_list":["https://p16/a.jpg"]},"follow_info":{"follower_count":99},"verified":true,"is_follower":true,"is_following":false,"is_subscribe":true}},{"rank":2,"score":100}]}}'
    $a = ConvertFrom-TikTokAudienceResponse -Status 200 -Body $body
    Check ($a.Total -eq 42 -and $a.Anonymous -eq 7 -and $a.Viewers.Count -eq 1) 'totals'
    $v = $a.Viewers[0]
    Check ($v.UserId -eq '7200000000000000001' -and $v.Username -eq 'viewer_one' -and $v.Nickname -eq 'One' -and $v.SecUid -eq 'MS4w') 'ids'
    Check ($v.AvatarUrl -eq 'https://p16/a.jpg' -and $v.FollowerCount -eq 99) 'avatar/followers'
    Check ($v.Verified -and $v.IsFollower -and -not $v.IsFollowing -and $v.IsSubscriber) 'flags'
    Check ($a.RawJson -eq $body) 'raw json'
}

Test-Case 'audience: 20003 -> SessionRequired; other -> InvalidResponse; empty -> InvalidResponse' {
    Check ((ErrKind { ConvertFrom-TikTokAudienceResponse -Status 200 -Body '{"status_code":20003,"data":{}}' }) -eq 'SessionRequired') '20003'
    try { ConvertFrom-TikTokAudienceResponse -Status 200 -Body '{"status_code":10011,"data":{"message":"param error"}}' }
    catch [PirateTok.Live.TikTokLiveException] { $e = $_.Exception }
    Check ($e.ErrorKind -eq 'InvalidResponse' -and $e.Message -eq 'online_audience status_code=10011 param error' -and $e.Code -eq 10011) $e.Message
    Check ((ErrKind { ConvertFrom-TikTokAudienceResponse -Status 502 -Body '' }) -eq 'InvalidResponse') 'empty'
}

# ---- W3 / F1: check_online ----

Test-Case 'check_online: room + anchor id' {
    $r = ConvertFrom-TikTokRoomIdResponse -Status 200 -Username x -Body '{"statusCode":0,"data":{"user":{"id":"6900000000000000001","roomId":"7300000000000000002","status":2},"liveRoom":{"status":2}}}'
    Check ($r.RoomId -eq '7300000000000000002' -and $r.AnchorId -eq '6900000000000000001') "$($r.RoomId)/$($r.AnchorId)"
}

Test-Case 'check_online: error mapping' {
    Check ((ErrKind { ConvertFrom-TikTokRoomIdResponse -Status 200 -Username x -Body '{"statusCode":19881007}' }) -eq 'UserNotFound') 'UserNotFound'
    Check ((ErrKind { ConvertFrom-TikTokRoomIdResponse -Status 200 -Username x -Body '{"statusCode":0,"data":{"user":{"id":"1","roomId":"0"}}}' }) -eq 'HostNotOnline') 'HostNotOnline'
    Check ((ErrKind { ConvertFrom-TikTokRoomIdResponse -Status 200 -Username x -Body '{"statusCode":0,"data":{"user":{"id":"1","roomId":"5","status":4}}}' }) -eq 'HostNotOnline') 'HostNotOnline status'
    try { ConvertFrom-TikTokRoomIdResponse -Status 200 -Username x -Body '{"statusCode":10101}' } catch [PirateTok.Live.TikTokLiveException] { $e = $_.Exception }
    Check ($e.ErrorKind -eq 'ApiError' -and $e.Code -eq 10101) 'ApiError(code)'
    Check ((ErrKind { ConvertFrom-TikTokRoomIdResponse -Status 429 -Username x -Body '' }) -eq 'TikTokBlocked') '429'
    Check ((ErrKind { ConvertFrom-TikTokRoomIdResponse -Status 200 -Username x -Body '' }) -eq 'TikTokBlocked') 'empty'
    Check ((ErrKind { ConvertFrom-TikTokRoomIdResponse -Status 200 -Username x -Body '<html>captcha' }) -eq 'TikTokBlocked') 'non-JSON'
    Check ((ErrKind { ConvertFrom-TikTokRoomIdResponse -Status 200 -Username x -Body '{"statusCode":' }) -eq 'TikTokBlocked') 'mangled JSON'
}

# ---- F9: room info ----

Test-Case 'room info: FLV urls, AgeRestricted' {
    $sd = '{"data":{"origin":{"main":{"flv":"o.flv"}},"uhd":{"main":{"flv":"u.flv"}},"sd":{"main":{"flv":"s.flv"}}}}'
    $body = @{ status_code = 0; data = @{ title = 'T'; user_count = 5; stats = @{ like_count = 6; total_user = 7 }
        stream_url = @{ live_core_sdk_data = @{ pull_data = @{ stream_data = $sd } } } } } | ConvertTo-Json -Depth 10
    $i = ConvertFrom-TikTokRoomInfoResponse -Status 200 -Body $body
    Check ($i.Title -eq 'T' -and $i.Viewers -eq 5 -and $i.Likes -eq 6 -and $i.TotalViewers -eq 7) 'fields'
    Check ($i.StreamUrl.FlvOrigin -eq 'o.flv' -and $i.StreamUrl.FlvHd -eq 'u.flv' -and $i.StreamUrl.FlvSd -eq 's.flv' -and $null -eq $i.StreamUrl.FlvLd) 'flv'
    Check ((ErrKind { ConvertFrom-TikTokRoomInfoResponse -Status 200 -Body '{"status_code":4003110}' }) -eq 'AgeRestricted') 'AgeRestricted'
}

# ---- F13 / F15: sub-routing + gift helpers ----

Test-Case 'sub-routing: raw + convenience both fire' {
    $types = { param($m, $v) (ConvertTo-TikTokEvents -Method $m -Payload (ConvertTo-TikTokProto $m $v) | ForEach-Object Type) -join ',' }
    Check ((& $types 'WebcastSocialMessage' @{ action = 1 }) -eq 'Social,Follow') 'follow'
    Check ((& $types 'WebcastSocialMessage' @{ action = 3 }) -eq 'Social,Share') 'share'
    Check ((& $types 'WebcastMemberMessage' @{ action = 1 }) -eq 'Member,Join') 'join'
    Check ((& $types 'WebcastControlMessage' @{ action = 3 }) -eq 'Control,LiveEnded') 'live ended'
    $u = ConvertTo-TikTokEvents -Method 'WebcastNotARealMessage' -Payload ([byte[]]@(1, 2))
    Check ($u[0].Type -eq 'Unknown' -and $u[0].Method -eq 'WebcastNotARealMessage' -and $u[0].RawPayload.Length -eq 2) 'unknown passthrough'
}

Test-Case 'gift helpers: combo, streak over, diamond total' {
    $combo = @{ gift_details = @{ gift_type = 1; diamond_count = 5 }; repeat_count = 3; repeat_end = 0 }
    $plain = @{ gift_details = @{ gift_type = 2; diamond_count = 100 }; repeat_count = 0; repeat_end = 0 }
    Check ((Test-TikTokComboGift $combo) -and -not (Test-TikTokComboGift $plain)) 'combo'
    Check (-not (Test-TikTokStreakOver $combo) -and (Test-TikTokStreakOver $plain)) 'streak'
    $combo.repeat_end = 1
    Check (Test-TikTokStreakOver $combo) 'streak ended'
    Check ((Get-TikTokDiamondTotal $combo) -eq 15 -and (Get-TikTokDiamondTotal $plain) -eq 100) 'diamonds'
}

# ---- F16: profile scrape parsing ----

Test-Case 'profile: SIGI parse + private mapping' {
    $json = '{"__DEFAULT_SCOPE__":{"webapp.user-detail":{"statusCode":0,"userInfo":{"user":{"id":"1","uniqueId":"someone","nickname":"S","verified":true,"bioLink":{"link":"x.io"}},"stats":{"followerCount":10}}}}}'
    $p = ConvertFrom-TikTokProfileHtml "<script id=`"__UNIVERSAL_DATA_FOR_REHYDRATION__`" type=`"application/json`">$json</script>" 'someone'
    Check ($p.UniqueId -eq 'someone' -and $p.Verified -and $p.FollowerCount -eq 10 -and $p.BioLink -eq 'x.io') 'profile'
    $priv = '<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__">{"__DEFAULT_SCOPE__":{"webapp.user-detail":{"statusCode":10222}}}</script>'
    Check ((ErrKind { ConvertFrom-TikTokProfileHtml $priv 'x' }) -eq 'ProfilePrivate') 'private'
}

# ---- F17: examples parse and only call exported cmdlets ----

$global:Exported = @((Get-Module PirateTok.Live).ExportedFunctions.Keys)
foreach ($ex in Get-ChildItem (Join-Path $PSScriptRoot '../examples') -Filter *.ps1) {
    $global:ExamplePath = $ex.FullName
    Test-Case "example $($ex.Name) parses and its TikTok cmdlets exist" {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($global:ExamplePath, [ref]$tokens, [ref]$errs)
        Check ($errs.Count -eq 0) "parse errors: $($errs | ForEach-Object Message)"
        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -like '*-TikTok*' } | Sort-Object -Unique
        Check (@($calls).Count -gt 0) 'no TikTok cmdlet calls'
        foreach ($c in $calls) { Check ($global:Exported -contains $c) "$c is not exported" }
    }
}

Write-Host "`n--- $script:passed passed, $script:failed failed ---"
if ($script:failed -gt 0 -or $script:passed -eq 0) { exit 1 }
