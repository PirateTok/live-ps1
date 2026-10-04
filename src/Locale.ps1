# User agent pool + system timezone / language / region detection.

$script:UserAgents = @(
    "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:139.0) Gecko/20100101 Firefox/139.0"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

function Get-TikTokRandomUserAgent {
    return $script:UserAgents[(Get-Random -Minimum 0 -Maximum $script:UserAgents.Count)]
}

# IANA timezone: $TZ, .NET local zone (IANA id on Unix, mapped on Windows), /etc/timezone,
# /etc/localtime symlink; "UTC" when nothing resolves.
function Get-TikTokSystemTimezone {
    $tz = "$env:TZ".TrimStart(':').Trim()
    if ($tz.Contains('/')) { return $tz }

    $local = [System.TimeZoneInfo]::Local
    if ($local.Id.Contains('/')) { return $local.Id }
    $convert = [System.TimeZoneInfo].GetMethod('TryConvertWindowsIdToIanaId', [type[]]@([string], [string].MakeByRefType()))
    if ($convert) {
        $iana = $null
        if ([System.TimeZoneInfo]::TryConvertWindowsIdToIanaId($local.Id, [ref]$iana) -and $iana) { return $iana }
    }

    if (Test-Path -LiteralPath '/etc/timezone') {
        $tz = (Get-Content -LiteralPath '/etc/timezone' -TotalCount 1).Trim()
        if ($tz.Contains('/')) { return $tz }
    }
    if (Test-Path -LiteralPath '/etc/localtime') {
        $target = (Get-Item -LiteralPath '/etc/localtime').Target
        if ($target -and "$target" -match '/zoneinfo/(.+)$') { return $Matches[1] }
    }
    return 'UTC'
}

# (language, region) from LC_ALL / LANG (POSIX), else the current .NET culture, else en-US.
function Get-TikTokSystemLocale {
    foreach ($var in 'LC_ALL', 'LANG') {
        $val = [Environment]::GetEnvironmentVariable($var)
        if (-not $val -or $val -eq 'C' -or $val -eq 'POSIX') { continue }
        $base = ($val -split '\.')[0]
        if ($base -match '^([A-Za-z]{2,})[_-]([A-Za-z]+)') { return @($Matches[1].ToLower(), $Matches[2].ToUpper()) }
        if ($base -match '^([A-Za-z]{2,})') { return @($Matches[1].ToLower(), 'US') }
    }
    $culture = [System.Globalization.CultureInfo]::CurrentCulture.Name
    if ($culture -match '^([a-z]{2,})-([A-Z]{2})') { return @($Matches[1], $Matches[2]) }
    return @('en', 'US')
}

function Resolve-TikTokLocale([string]$Language, [string]$Region) {
    $sys = Get-TikTokSystemLocale
    $lang = if ($Language) { $Language } else { $sys[0] }
    $reg = if ($Region) { $Region } else { $sys[1] }
    return @($lang, $reg)
}
