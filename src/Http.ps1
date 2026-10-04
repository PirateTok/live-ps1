# Minimal HTTP GET over System.Net.Http.HttpClient: no auto-redirect, no cookie jar
# (Set-Cookie headers come back raw), optional proxy, per-request timeout.

Add-Type -AssemblyName System.Net.Http

# Transport hook — tests swap this for a fake. Returns @{ Status; SetCookies; Body }.
$script:HttpGet = {
    param([string]$Url, [hashtable]$Headers, [string]$Proxy, [int]$TimeoutSec)

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    if ($Proxy) {
        $handler.Proxy = [System.Net.WebProxy]::new($Proxy)
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
    return & $script:HttpGet $Url $headers $Proxy $TimeoutSec
}

# JSON body → object, or $null when the body is empty / not JSON (callers map that
# to TikTokBlocked or InvalidResponse).
function ConvertFrom-TikTokJson([string]$Body) {
    if (-not $Body -or $Body.TrimStart()[0] -notin '{', '[') { return $null }
    try { return $Body | ConvertFrom-Json } catch [System.ArgumentException] { return $null }
}
