# Minimal HTTP GET over System.Net.Http.HttpClient: no auto-redirect, no cookie jar
# (Set-Cookie headers come back raw), optional proxy, per-request timeout.

Add-Type -AssemblyName System.Net.Http

# Transport hook — tests swap this for a fake. Returns @{ Status; SetCookies; Body }.
$script:HttpGet = {
    param([string]$Url, [hashtable]$Headers, [string]$Proxy, [int]$TimeoutSec)

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    if ([PirateTok.Live.TlsTrust]::PinnedThumbprint) {
        $handler.ServerCertificateCustomValidationCallback = [PirateTok.Live.TlsTrust].GetMethod('Validate').CreateDelegate(
            [System.Func[System.Net.Http.HttpRequestMessage, System.Security.Cryptography.X509Certificates.X509Certificate2, System.Security.Cryptography.X509Certificates.X509Chain, System.Net.Security.SslPolicyErrors, bool]])
    }
    if ($Proxy) {
        # http://[user:pass@]host:port — credentials go out as Basic on the proxy's 407 challenge
        $p = [Uri]$Proxy
        $handler.Proxy = [System.Net.WebProxy]::new("$($p.Scheme)://$($p.Authority)")
        if ($p.UserInfo) {
            $user, $pass = [Uri]::UnescapeDataString($p.UserInfo) -split ':', 2
            $handler.Proxy.Credentials = [System.Net.NetworkCredential]::new($user, $pass)
        }
        $handler.UseProxy = $true
    }
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    foreach ($name in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name]) }

    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $setCookies = @()
        $values = $null
        if ($response.Headers.TryGetValues('Set-Cookie', [ref]$values)) { $setCookies = @($values) }
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return @{ Status = [int]$response.StatusCode; SetCookies = $setCookies; Body = $body }
    } catch {
        throw (New-TikTokError 'HttpError' "GET $([Uri]::new($Url).Host) failed: $($_.Exception.GetBaseException().Message)")
    } finally {
        $request.Dispose()
        $client.Dispose()
    }
}

# SOCKS is not supported (the WSS path speaks HTTP CONNECT only); fail loudly instead of
# silently bypassing or half-using the proxy.
function Assert-TikTokProxy([string]$Proxy) {
    $scheme = ([Uri]$Proxy).Scheme
    if ($scheme -notin 'http', 'https') {
        throw (New-TikTokError 'InvalidUrl' "unsupported proxy scheme '$scheme' — only HTTP CONNECT proxies (http://[user:pass@]host:port)")
    }
}

function Invoke-TikTokGet {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$UserAgent,
        [string]$Cookies,
        [string]$Proxy,
        [int]$TimeoutSec = 10,
        [string]$Accept = 'application/json'
    )
    $headers = @{
        'User-Agent'      = $(if ($UserAgent) { $UserAgent } else { Get-TikTokRandomUserAgent })
        'Accept'          = $Accept
        'Referer'         = 'https://www.tiktok.com/'
        'Accept-Language' = 'en-US,en;q=0.9'
    }
    if ($Cookies) { $headers['Cookie'] = $Cookies }
    if ($Proxy) { Assert-TikTokProxy $Proxy }
    return & $script:HttpGet $Url $headers $Proxy $TimeoutSec
}

# JSON body → object, or $null when the body is empty / not JSON (callers map that
# to TikTokBlocked or InvalidResponse).
function ConvertFrom-TikTokJson([string]$Body) {
    if (-not $Body -or $Body.TrimStart()[0] -notin '{', '[') { return $null }
    try { return $Body | ConvertFrom-Json } catch [System.ArgumentException] { return $null }
}
