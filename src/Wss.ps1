# Minimal WebSocket client over TcpClient + SslStream (works on PowerShell 5.1 and 7).
# HTTP CONNECT proxy, DEVICE_BLOCKED detection on the handshake, masked binary frames,
# ping/pong, fragmented messages. Reads never time out the stream: one ReadAsync stays
# pending across polls and the poll only waits on it.

function Read-TikTokHttpHead([System.IO.Stream]$Stream) {
    $buf = [System.Collections.Generic.List[byte]]::new()
    $one = [byte[]]::new(1)
    while ($buf.Count -lt 65536) {
        if ($Stream.Read($one, 0, 1) -le 0) { break }
        $buf.Add($one[0])
        $n = $buf.Count
        if ($n -ge 4 -and $buf[$n - 4] -eq 13 -and $buf[$n - 3] -eq 10 -and $buf[$n - 2] -eq 13 -and $buf[$n - 1] -eq 10) { break }
    }
    return [System.Text.Encoding]::ASCII.GetString($buf.ToArray())
}

# Explicit -Proxy, else HTTPS_PROXY / HTTP_PROXY. Only HTTP CONNECT proxies (http://[user:pass@]host:port).
function Resolve-TikTokProxy([string]$Proxy) {
    $resolved = $Proxy
    if (-not $resolved) {
        foreach ($var in 'HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy') {
            $val = [Environment]::GetEnvironmentVariable($var)
            if ($val) { $resolved = $val; break }
        }
    }
    if ($resolved) { Assert-TikTokProxy $resolved }
    return $resolved
}

function Open-TikTokWebSocket {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Cookie,
        [Parameter(Mandatory)][string]$UserAgent,
        [string]$Proxy,
        [string]$AcceptLanguage = 'en-US,en;q=0.9',
        [int]$TimeoutSec = 10
    )
    $uri = [Uri]$Url
    $wsHost = $uri.Host
    $proxyUrl = Resolve-TikTokProxy $Proxy
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $tcp.ReceiveTimeout = $TimeoutSec * 1000
    $tcp.SendTimeout = $TimeoutSec * 1000
    try {
        if ($proxyUrl) {
            $p = [Uri]$proxyUrl
            $tcp.Connect($p.Host, $(if ($p.Port -gt 0) { $p.Port } else { 8080 }))
            $net = $tcp.GetStream()
            $auth = ''
            if ($p.UserInfo) {
                $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([Uri]::UnescapeDataString($p.UserInfo)))
                $auth = "Proxy-Authorization: Basic $basic`r`n"
            }
            $req = [System.Text.Encoding]::ASCII.GetBytes("CONNECT ${wsHost}:443 HTTP/1.1`r`nHost: ${wsHost}:443`r`n$auth`r`n")
            $net.Write($req, 0, $req.Length)
            $head = Read-TikTokHttpHead $net
            if ($head -notmatch '^HTTP/1\.\d 200') {
                throw (New-TikTokError 'WebSocketError' "proxy CONNECT failed: $(($head -split "`r`n")[0])")
            }
        } else {
            $tcp.Connect($wsHost, 443)
        }
        $validate = [System.Net.Security.RemoteCertificateValidationCallback][PirateTok.Live.TlsTrust].GetMethod('Validate').CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback])
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $validate)
        try {
            if ($PSVersionTable.PSEdition -eq 'Desktop') {
                # .NET Framework may default to TLS 1.0 — TikTok needs 1.2
                $ssl.AuthenticateAsClient($wsHost, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
            } else {
                $ssl.AuthenticateAsClient($wsHost)
            }
        } catch [System.Management.Automation.MethodInvocationException] {
            throw (New-TikTokError 'WebSocketError' "tls: handshake with $wsHost failed: $($_.Exception.GetBaseException().Message)")
        }

        $key = [byte[]]::new(16); [System.Random]::new().NextBytes($key)
        $upgrade = "GET $($uri.PathAndQuery) HTTP/1.1`r`nHost: $wsHost`r`nUpgrade: websocket`r`nConnection: Upgrade`r`n" +
            "Sec-WebSocket-Key: $([Convert]::ToBase64String($key))`r`nSec-WebSocket-Version: 13`r`n" +
            "User-Agent: $UserAgent`r`nOrigin: https://www.tiktok.com`r`nAccept-Language: $AcceptLanguage`r`n" +
            "Cookie: $Cookie`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($upgrade)
        $ssl.Write($bytes, 0, $bytes.Length); $ssl.Flush()

        $head = Read-TikTokHttpHead $ssl
        if ($head -match '(?im)^Handshake-Msg:\s*DEVICE_BLOCKED' -or $head -match '^HTTP/1\.\d 415') {
            throw (New-TikTokError 'DeviceBlocked' 'DEVICE_BLOCKED — ttwid flagged, fetch a fresh one')
        }
        if ($head -notmatch '^HTTP/1\.\d 101') {
            throw (New-TikTokError 'WebSocketError' "handshake failed: $(($head -split "`r`n")[0])")
        }
    } catch {
        $tcp.Dispose()
        throw
    }
    $tcp.ReceiveTimeout = 0
    return @{ Tcp = $tcp; Ssl = $ssl; Buf = [System.IO.MemoryStream]::new(); Chunk = [byte[]]::new(65536)
        Pending = $null; Fragments = $null; Closed = $false }
}

function Send-TikTokWsFrame([hashtable]$Ws, [byte[]]$Data, [int]$Opcode = 2) {
    $ms = [System.IO.MemoryStream]::new()
    $ms.WriteByte([byte](0x80 -bor $Opcode))
    $len = $Data.Length
    if ($len -lt 126) { $ms.WriteByte([byte](0x80 -bor $len)) }
    elseif ($len -lt 65536) { $ms.WriteByte(0xFE); $ms.WriteByte([byte]($len -shr 8)); $ms.WriteByte([byte]($len -band 0xFF)) }
    else {
        $ms.WriteByte(0xFF)
        for ($s = 56; $s -ge 0; $s -= 8) { $ms.WriteByte([byte](([long]$len -shr $s) -band 0xFF)) }
    }
    $mask = [byte[]]::new(4); [System.Random]::new().NextBytes($mask)
    $ms.Write($mask, 0, 4)
    $masked = [byte[]]::new($len)
    for ($i = 0; $i -lt $len; $i++) { $masked[$i] = $Data[$i] -bxor $mask[$i % 4] }
    $ms.Write($masked, 0, $len)
    $frame = $ms.ToArray(); $ms.Dispose()
    $Ws.Ssl.Write($frame, 0, $frame.Length)
    $Ws.Ssl.Flush()
}

# Take one complete frame off the front of $Ws.Buf: @{ Opcode; Fin; Payload } or $null.
function Pop-TikTokWsFrame([hashtable]$Ws) {
    $b = $Ws.Buf.GetBuffer(); $n = [int]$Ws.Buf.Length
    if ($n -lt 2) { return $null }
    $len = [long]($b[1] -band 0x7F); $off = 2
    if ($len -eq 126) { if ($n -lt 4) { return $null }; $len = ([long]$b[2] -shl 8) -bor $b[3]; $off = 4 }
    elseif ($len -eq 127) {
        if ($n -lt 10) { return $null }
        $len = 0; for ($i = 2; $i -lt 10; $i++) { $len = ($len -shl 8) -bor $b[$i] }; $off = 10
    }
    if ($b[1] -band 0x80) { throw (New-TikTokError 'WebSocketError' 'server sent a masked frame') }
    if ($n -lt $off + $len) { return $null }
    $payload = [byte[]]::new($len)
    [Array]::Copy($b, $off, $payload, 0, $len)
    $rest = [System.IO.MemoryStream]::new()
    $rest.Write($b, [int]($off + $len), [int]($n - $off - $len))
    $Ws.Buf.Dispose(); $Ws.Buf = $rest
    return @{ Opcode = $b[0] -band 0x0F; Fin = ($b[0] -band 0x80) -ne 0; Payload = $payload }
}

# Wait up to $TimeoutMs for data; return complete binary messages (byte[][]).
# Answers pings; sets $Ws.Closed on close frame / EOF.
function Receive-TikTokWsMessages([hashtable]$Ws, [int]$TimeoutMs) {
    $messages = [System.Collections.Generic.List[object]]::new()
    if (-not $Ws.Pending) { $Ws.Pending = $Ws.Ssl.ReadAsync($Ws.Chunk, 0, $Ws.Chunk.Length) }
    while ($Ws.Pending.Wait($TimeoutMs)) {
        $read = $Ws.Pending.Result
        $Ws.Pending = $null
        if ($read -le 0) { $Ws.Closed = $true; break }
        $Ws.Buf.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
        $Ws.Buf.Write($Ws.Chunk, 0, $read)
        while ($frame = Pop-TikTokWsFrame $Ws) {
            switch ($frame.Opcode) {
                8 { $Ws.Closed = $true }
                9 { Send-TikTokWsFrame $Ws $frame.Payload 10 }
                10 {}
                default {
                    # 0 = continuation, 1 = text, 2 = binary
                    if ($frame.Opcode -ne 0) { $Ws.Fragments = [System.IO.MemoryStream]::new() }
                    $Ws.Fragments.Write($frame.Payload, 0, $frame.Payload.Length)
                    if ($frame.Fin) { $messages.Add($Ws.Fragments.ToArray()); $Ws.Fragments.Dispose(); $Ws.Fragments = $null }
                }
            }
        }
        if ($Ws.Closed) { break }
        $Ws.Pending = $Ws.Ssl.ReadAsync($Ws.Chunk, 0, $Ws.Chunk.Length)
        $TimeoutMs = 0
    }
    return , $messages.ToArray()
}

# -Graceful sends a close frame first (user disconnect); dropped connections just dispose.
function Close-TikTokWebSocket([hashtable]$Ws, [switch]$Graceful) {
    try {
        if ($Graceful -and -not $Ws.Closed -and $Ws.Tcp.Connected) { Send-TikTokWsFrame $Ws ([byte[]]@(0x03, 0xE8)) 8 }
    } finally {
        $Ws.Closed = $true
        $Ws.Ssl.Dispose()
        $Ws.Tcp.Dispose()
    }
}
