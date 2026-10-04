#!/usr/bin/env pwsh
# Offline wire tests (F2/F6/F7/F8): a local HTTP CONNECT proxy (Basic auth required)
# relays into a local TLS fake of tiktok.com + webcast-ws (self-signed cert, pinned by
# thumbprint for this test only). Connect-TikTokLive runs its real HTTP + WSS code through it.
# Usage: pwsh tests/wire.ps1   (from the live-ps1 root)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../PirateTok.Live.psd1') -Force
$module = Get-Module PirateTok.Live
$passed = 0; $failed = 0
function Check($Cond, [string]$Label) { if (-not $Cond) { throw "assertion failed: $Label" } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name`: $($_.Exception.Message)" }
}

# ---- self-signed cert ----
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=pirate-test', $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$tmp = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($tmp.Export('Pfx'))

$log = [hashtable]::Synchronized(@{ Proxy = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        Server = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        Frames = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) })

$readHead = {
    param($s)
    $b = [System.Collections.Generic.List[byte]]::new(); $one = [byte[]]::new(1)
    while ($s.Read($one, 0, 1) -gt 0) {
        $b.Add($one[0]); $n = $b.Count
        if ($n -ge 4 -and $b[$n - 4] -eq 13 -and $b[$n - 3] -eq 10 -and $b[$n - 2] -eq 13 -and $b[$n - 1] -eq 10) { break }
    }
    [System.Text.Encoding]::ASCII.GetString($b.ToArray())
}

# ---- fake TLS server: HTTP (room + ttwid) and WebSocket (records client frames) ----
$server = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $server.Start()
$serverPs = [powershell]::Create().AddScript({
    param($listener, $cert, $log, $readHead)
    while ($true) {
        $c = $listener.AcceptTcpClient()
        $ssl = [System.Net.Security.SslStream]::new($c.GetStream(), $false)
        $ssl.AuthenticateAsServer($cert)
        $head = & $readHead $ssl
        $null = $log.Server.Add($head)
        if ($head -match '(?im)^Upgrade:\s*websocket') {
            $resp = "HTTP/1.1 101 Switching Protocols`r`nUpgrade: websocket`r`nConnection: Upgrade`r`n`r`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($resp); $ssl.Write($bytes, 0, $bytes.Length); $ssl.Flush()
            while ($true) {
                $h = [byte[]]::new(2); if ($ssl.Read($h, 0, 2) -lt 2) { break }
                $op = $h[0] -band 0x0F; $len = $h[1] -band 0x7F
                if ($len -eq 126) { $e = [byte[]]::new(2); $null = $ssl.Read($e, 0, 2); $len = ([int]$e[0] -shl 8) -bor $e[1] }
                $mask = [byte[]]::new(4); $null = $ssl.Read($mask, 0, 4)
                $p = [byte[]]::new($len); $r = 0; while ($r -lt $len) { $r += $ssl.Read($p, $r, $len - $r) }
                for ($i = 0; $i -lt $len; $i++) { $p[$i] = $p[$i] -bxor $mask[$i % 4] }
                if ($op -eq 8) { break }
                $null = $log.Frames.Add($p)
            }
        } else {
            $body = if ($head -match '^GET /api-live/user/room') {
                '{"statusCode":0,"data":{"user":{"id":"690001","roomId":"730002","status":2},"liveRoom":{"status":2}}}'
            } else { 'ok' }
            $cookie = if ($head -match '^GET / ') { "Set-Cookie: ttwid=1%7Cwire%7C9; Path=/; Secure`r`n" } else { '' }
            $resp = "HTTP/1.1 200 OK`r`n${cookie}Content-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($resp); $ssl.Write($bytes, 0, $bytes.Length); $ssl.Flush()
        }
        $ssl.Dispose(); $c.Close()
    }
}).AddArgument($server).AddArgument($cert).AddArgument($log).AddArgument($readHead)
$null = $serverPs.BeginInvoke()

# ---- CONNECT proxy: requires Basic user:p@ss, relays every tunnel into the fake server ----
$proxy = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $proxy.Start()
$proxyPs = [powershell]::Create().AddScript({
    param($listener, $serverPort, $log, $readHead)
    $expected = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('user:p@ss'))
    while ($true) {
        $c = $listener.AcceptTcpClient(); $s = $c.GetStream()
        $head = & $readHead $s
        $null = $log.Proxy.Add($head)
        $auth = if ($head -match '(?im)^Proxy-Authorization:\s*(.+?)\s*$') { $Matches[1] } else { '' }
        if ($head -notmatch '^CONNECT ' -or $auth -ne $expected) {
            $deny = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 407 Proxy Authentication Required`r`nProxy-Authenticate: Basic realm=`"t`"`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
            $s.Write($deny, 0, $deny.Length); $c.Close(); continue
        }
        $up = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $serverPort); $u = $up.GetStream()
        $ok = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection Established`r`n`r`n"); $s.Write($ok, 0, $ok.Length)
        $t1 = $s.CopyToAsync($u); $t2 = $u.CopyToAsync($s)
        $null = [System.Threading.Tasks.Task]::WaitAny(@($t1, $t2))
        $up.Close(); $c.Close()
    }
}).AddArgument($proxy).AddArgument($server.LocalEndpoint.Port).AddArgument($log).AddArgument($readHead)
$null = $proxyPs.BeginInvoke()

$proxyUrl = "http://user:p%40ss@127.0.0.1:$($proxy.LocalEndpoint.Port)"
$expectedAuth = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('user:p@ss'))
[PirateTok.Live.TlsTrust]::PinnedThumbprint = $cert.Thumbprint

function Wait-For([scriptblock]$Cond) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (& $Cond) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
}

Test-Case 'proxy: ttwid GET tunnels via CONNECT www.tiktok.com:443 with Basic auth' {
    $ttwid = & $module { param($p) Get-TikTokTtwid -Proxy $p -UserAgent 'UA-Test/1' -NoRetry } $proxyUrl
    Check ($ttwid -eq '1%7Cwire%7C9') "ttwid $ttwid"
    $connects = @($log.Proxy | Where-Object { $_ -match '^CONNECT www\.tiktok\.com:443 ' -and $_ -match [regex]::Escape($expectedAuth) })
    Check ($connects.Count -ge 1) 'authenticated CONNECT www.tiktok.com:443'
    $get = @($log.Server | Where-Object { $_ -match '^GET / HTTP' })[-1]
    Check ($get -match '(?im)^Host: www\.tiktok\.com' -and $get -match '(?im)^User-Agent: UA-Test/1') 'GET / with fixed UA'
}

Test-Case 'connect: room id + ttwid + WSS all through the proxy; UA/cookies/locale/compress on the wire' {
    $log.Proxy.Clear(); $log.Server.Clear(); $log.Frames.Clear()
    $c = Connect-TikTokLive someone -Proxy $proxyUrl -UserAgent 'UA-Test/1' -Cookies 'sessionid=abc; sid_tt=def' `
        -Language ro -Region RO -NoCompress -HeartbeatInterval 7 -Cdn eu
    Check ($c.State -eq 'Connected') "state $($c.State)"
    Wait-For { $log.Frames.Count -ge 2 }
    Disconnect-TikTokLive $c

    $targets = @($log.Proxy | Where-Object { $_ -match [regex]::Escape($expectedAuth) } | ForEach-Object { ($_ -split "`r`n")[0] })
    Check ($targets -contains 'CONNECT www.tiktok.com:443 HTTP/1.1') "room/ttwid tunnel: $($targets -join ' | ')"
    Check ($targets -contains 'CONNECT webcast-ws.eu.tiktok.com:443 HTTP/1.1') "wss tunnel: $($targets -join ' | ')"

    $room = @($log.Server | Where-Object { $_ -match '^GET /api-live/user/room' })[0]
    Check ($room -match 'app_language=ro&browser_language=ro-RO&region=RO' -and $room -match '(?im)^User-Agent: UA-Test/1') 'room request locale + UA'

    $up = @($log.Server | Where-Object { $_ -match '(?im)^Upgrade: websocket' })[0]
    $line = ($up -split "`r`n")[0]
    foreach ($q in 'room_id=730002', 'browser_language=ro-RO', 'app_language=ro', 'webcast_language=ro', 'compress=&', 'heartbeat_duration=7000') {
        Check ($line.Contains($q)) "upgrade URL has $q"
    }
    Check ($up -match '(?im)^Host: webcast-ws\.eu\.tiktok\.com') 'eu cdn host'
    Check ($up -match '(?im)^Cookie: ttwid=1%7Cwire%7C9; sessionid=abc; sid_tt=def\r?$') 'cookie: ttwid + user cookies'
    Check ($up -match '(?im)^User-Agent: UA-Test/1') 'fixed UA on WSS'
    Check ($up -match '(?im)^Accept-Language: ro-RO,ro;q=0\.9') 'accept-language'

    Check ($log.Frames.Count -ge 2) "frames received: $($log.Frames.Count)"
    & $module {
        param($frames)
        $hb = ConvertFrom-TikTokProto 'WebcastPushFrame' $frames[0]
        $enter = ConvertFrom-TikTokProto 'WebcastPushFrame' $frames[1]
        if ($hb.payload_type -ne 'hb' -or (ConvertFrom-TikTokProto 'HeartbeatMessage' $hb.payload).room_id -ne 730002) { throw 'heartbeat frame' }
        $er = ConvertFrom-TikTokProto 'WebcastImEnterRoomMessage' $enter.payload
        if ($enter.payload_type -ne 'im_enter_room' -or $er.room_id -ne 730002 -or $er.identity -ne 'audience') { throw 'enter_room frame' }
    } @($log.Frames)
}

Test-Case 'proxy: wrong credentials -> WSS dial fails at CONNECT with WebSocketError (407)' {
    $bad = "http://user:nope@127.0.0.1:$($proxy.LocalEndpoint.Port)"
    $kind = & $module {
        param($bad)
        try { Open-TikTokWebSocket -Url 'wss://webcast-ws.tiktok.com/x' -Cookie 'ttwid=x' -UserAgent 'UA' -Proxy $bad; 'none' }
        catch [PirateTok.Live.TikTokLiveException] { "$($_.Exception.ErrorKind): $($_.Exception.Message)" }
    } $bad
    Check ($kind -like 'WebSocketError: proxy CONNECT failed: HTTP/1.1 407*') $kind
}

Test-Case 'proxy: socks5 is rejected explicitly (HTTP CONNECT only)' {
    $kind = try { Get-TikTokTtwid -Proxy 'socks5://127.0.0.1:1080' -NoRetry; 'none' } catch [PirateTok.Live.TikTokLiveException] { $_.Exception.ErrorKind }
    Check ($kind -eq 'InvalidUrl') $kind
}

[PirateTok.Live.TlsTrust]::PinnedThumbprint = $null
$proxy.Stop(); $server.Stop(); $proxyPs.Stop(); $serverPs.Stop()
Write-Host "`n--- $passed passed, $failed failed ---"
if ($failed -gt 0 -or $passed -eq 0) { exit 1 }
