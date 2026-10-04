# Stateful helpers — exported, never used by the core pipeline.
#   LikeAccumulator   monotonizes TikTok's inconsistent total like count
#   GiftStreakTracker per-event deltas from TikTok's running combo totals
#   ProfileCache      SIGI profile scrape with TTL cache + managed ttwid

class TikTokLikeAccumulator {
    [long]$MaxTotal = 0
    [long]$Accumulated = 0

    # $Like = a Like event's Data (fields: count, total)
    [pscustomobject] Process($Like) {
        $count = [long]$Like.count
        $total = [long]$Like.total
        $this.Accumulated += $count
        $backwards = $total -lt $this.MaxTotal
        if ($total -gt $this.MaxTotal) { $this.MaxTotal = $total }
        return [pscustomobject]@{
            EventLikeCount   = $count
            TotalLikeCount   = $this.MaxTotal
            AccumulatedCount = $this.Accumulated
            WentBackwards    = $backwards
        }
    }

    [void] Reset() { $this.MaxTotal = 0; $this.Accumulated = 0 }
}

class TikTokGiftStreakTracker {
    static [double]$StaleSecs = 60
    [hashtable]$Streaks = @{}

    # $Gift = a Gift event's Data
    [pscustomobject] Process($Gift) {
        $details = $Gift.gift_details
        $diamondPer = if ($details) { [long]$details.diamond_count } else { [long]0 }
        $isCombo = $details -and $details.gift_type -eq 1
        $isFinal = $Gift.repeat_end -eq 1
        $groupId = "$($Gift.group_id)"
        $repeatCount = [long]$Gift.repeat_count

        if (-not $isCombo) {
            return [pscustomobject]@{
                StreakId = $groupId; IsActive = $false; IsFinal = $true
                EventGiftCount = [long]1; TotalGiftCount = [long]1
                EventDiamondCount = $diamondPer; TotalDiamondCount = $diamondPer
            }
        }

        $now = [DateTime]::UtcNow
        foreach ($id in @($this.Streaks.Keys)) {
            if (($now - $this.Streaks[$id].LastSeen).TotalSeconds -ge [TikTokGiftStreakTracker]::StaleSecs) { $this.Streaks.Remove($id) }
        }
        $prev = if ($this.Streaks.ContainsKey($groupId)) { $this.Streaks[$groupId].LastRepeatCount } else { [long]0 }
        $delta = [Math]::Max($repeatCount - $prev, [long]0)
        if ($isFinal) { $this.Streaks.Remove($groupId) }
        else { $this.Streaks[$groupId] = @{ LastRepeatCount = $repeatCount; LastSeen = $now } }

        return [pscustomobject]@{
            StreakId = $groupId; IsActive = -not $isFinal; IsFinal = $isFinal
            EventGiftCount = $delta; TotalGiftCount = $repeatCount
            EventDiamondCount = $diamondPer * $delta
            TotalDiamondCount = $diamondPer * [Math]::Max($repeatCount, [long]1)
        }
    }

    [int] ActiveStreaks() { return $this.Streaks.Count }
    [void] Reset() { $this.Streaks.Clear() }
}

function New-TikTokLikeAccumulator { return [TikTokLikeAccumulator]::new() }
function New-TikTokGiftStreakTracker { return [TikTokGiftStreakTracker]::new() }

# ---- profile scrape (stateless) ----

function ConvertFrom-TikTokProfileHtml([string]$Html, [string]$Username) {
    $marker = 'id="__UNIVERSAL_DATA_FOR_REHYDRATION__"'
    $at = $Html.IndexOf($marker)
    if ($at -lt 0) { throw (New-TikTokError 'ProfileScrape' 'SIGI script tag not found') }
    $start = $Html.IndexOf('>', $at) + 1
    $end = $Html.IndexOf('</script>', $start)
    if ($start -le 0 -or $end -lt 0) { throw (New-TikTokError 'ProfileScrape' 'unterminated SIGI script tag') }
    $blob = ConvertFrom-TikTokJson $Html.Substring($start, $end - $start)
    if ($null -eq $blob) { throw (New-TikTokError 'ProfileScrape' 'SIGI JSON parse failed') }
    $detail = $blob.__DEFAULT_SCOPE__.'webapp.user-detail'
    if ($null -eq $detail) { throw (New-TikTokError 'ProfileScrape' 'missing webapp.user-detail') }

    switch ([long]$detail.statusCode) {
        0 {}
        10222 { throw (New-TikTokError 'ProfilePrivate' "profile is private: @$Username") }
        { $_ -in 10221, 10223 } { throw (New-TikTokError 'ProfileNotFound' "profile not found: @$Username") }
        default { throw (New-TikTokError 'ProfileError' "profile fetch error: statusCode=$_" $_) }
    }
    $u = $detail.userInfo.user
    if ($null -eq $u) { throw (New-TikTokError 'ProfileScrape' 'missing userInfo.user') }
    $s = $detail.userInfo.stats
    return [pscustomobject]@{
        UserId = "$($u.id)"; UniqueId = "$($u.uniqueId)"; Nickname = "$($u.nickname)"; Bio = "$($u.signature)"
        AvatarThumb = "$($u.avatarThumb)"; AvatarMedium = "$($u.avatarMedium)"; AvatarLarge = "$($u.avatarLarger)"
        Verified = $u.verified -eq $true; PrivateAccount = $u.privateAccount -eq $true
        IsOrganization = [long]$u.isOrganization -ne 0; RoomId = "$($u.roomId)"
        BioLink = $(if ($u.bioLink.link) { "$($u.bioLink.link)" } else { $null })
        FollowerCount = [long]$s.followerCount; FollowingCount = [long]$s.followingCount
        HeartCount = [long]$s.heartCount; VideoCount = [long]$s.videoCount; FriendCount = [long]$s.friendCount
    }
}

function Get-TikTokProfile {
    <#
    .SYNOPSIS
    Scrape a profile page (SIGI JSON). Stateless — use New-TikTokProfileCache for caching.
    Errors: ProfilePrivate, ProfileNotFound, ProfileError, ProfileScrape.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Username,
        [Parameter(Mandatory)][string]$Ttwid,
        [string]$UserAgent,
        [string]$Cookies,
        [string]$Proxy,
        [int]$TimeoutSec = 15
    )
    $clean = $Username.Trim().TrimStart('@').ToLower()
    $extra = @("$Cookies" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notlike 'ttwid=*' })
    $cookie = (@("ttwid=$Ttwid") + $extra) -join '; '
    $resp = Invoke-TikTokGet -Url "$($script:TiktokUrl)@$clean" -UserAgent $UserAgent -Cookies $cookie -Proxy $Proxy `
        -TimeoutSec $TimeoutSec -Accept 'text/html,application/xhtml+xml'
    if (-not $resp.Body) { throw (New-TikTokError 'ProfileScrape' 'empty HTML response') }
    return ConvertFrom-TikTokProfileHtml $resp.Body $clean
}

class TikTokProfileCache {
    [hashtable]$Entries = @{}
    [string]$Ttwid
    [double]$TtlSecs = 300
    [string]$UserAgent
    [string]$Cookies
    [string]$Proxy

    static [string] Key([string]$Username) { return $Username.Trim().TrimStart('@').ToLower() }

    # Cached profile or a fresh scrape. Private / not-found / error results are cached too.
    [pscustomobject] Fetch([string]$Username) {
        $key = [TikTokProfileCache]::Key($Username)
        $now = [DateTime]::UtcNow
        $entry = $this.Entries[$key]
        if ($entry -and ($now - $entry.At).TotalSeconds -lt $this.TtlSecs) {
            if ($entry.Error) { throw $entry.Error }
            return $entry.Profile
        }
        if (-not $this.Ttwid) { $this.Ttwid = Get-TikTokTtwid -UserAgent $this.UserAgent -Proxy $this.Proxy }
        try {
            $profile = Get-TikTokProfile -Username $key -Ttwid $this.Ttwid -UserAgent $this.UserAgent -Cookies $this.Cookies -Proxy $this.Proxy
        } catch [PirateTok.Live.TikTokLiveException] {
            $err = $_.Exception
            if ($err.ErrorKind -in 'ProfilePrivate', 'ProfileNotFound', 'ProfileError') {
                $this.Entries[$key] = @{ Error = $err; At = $now }
            }
            throw
        }
        $this.Entries[$key] = @{ Profile = $profile; At = $now }
        return $profile
    }

    # Cached profile without fetching; $null on miss, expiry or cached error.
    [pscustomobject] Cached([string]$Username) {
        $entry = $this.Entries[[TikTokProfileCache]::Key($Username)]
        if (-not $entry -or $entry.Error) { return $null }
        if (([DateTime]::UtcNow - $entry.At).TotalSeconds -ge $this.TtlSecs) { return $null }
        return $entry.Profile
    }

    [void] Invalidate([string]$Username) { $this.Entries.Remove([TikTokProfileCache]::Key($Username)) }
    [void] InvalidateAll() { $this.Entries.Clear() }
}

function New-TikTokProfileCache {
    param([double]$TtlSecs = 300, [string]$UserAgent, [string]$Cookies, [string]$Proxy)
    $cache = [TikTokProfileCache]::new()
    $cache.TtlSecs = $TtlSecs; $cache.UserAgent = $UserAgent; $cache.Cookies = $Cookies; $cache.Proxy = $Proxy
    return $cache
}
