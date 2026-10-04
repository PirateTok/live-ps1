# TikTok HTTP endpoints: ttwid, room id (check_online), room info, audience roster.
# Parsers are separate pure functions so tests can feed fixtures.

$script:TiktokUrl = 'https://www.tiktok.com/'
$script:WebcastUrl = 'https://webcast.tiktok.com/webcast/'
$script:TtwidFetchAttempts = 8
$script:TtwidRetryDelayMs = 750

# Sleep hook (tests replace it).
$script:SleepMs = { param([int]$Ms) Start-Sleep -Milliseconds $Ms }

function Get-TikTokTtwid {
    <#
    .SYNOPSIS
    Fetch a ttwid cookie (anonymous GET to tiktok.com) — the only credential WSS needs.
    TikTok sets it intermittently, so a response without the cookie is retried up to
    8 times, 750 ms apart. Transport errors fail immediately. -NoRetry = single request.
    #>
    [CmdletBinding()]
    param(
        [string]$UserAgent,
        [string]$Proxy,
        [int]$TimeoutSec = 10,
        [switch]$NoRetry,
        [Parameter(DontShow)][string]$Url = $script:TiktokUrl
    )
    $attempts = if ($NoRetry) { 1 } else { $script:TtwidFetchAttempts }
    for ($attempt = 1; ; $attempt++) {
        $resp = Invoke-TikTokGet -Url $Url -UserAgent $UserAgent -Proxy $Proxy -TimeoutSec $TimeoutSec -Accept 'text/html'
        foreach ($cookie in $resp.SetCookies) {
            if ($cookie -match '^ttwid=([^;]+)') { return $Matches[1] }
        }
        if ($attempt -ge $attempts) {
            throw (New-TikTokError 'InvalidResponse' "no ttwid cookie in tiktok.com response (after $attempt attempts)")
        }
        Write-Verbose "ttwid missing from tiktok.com response (attempt $attempt), retrying"
        & $script:SleepMs $script:TtwidRetryDelayMs
    }
}

function ConvertFrom-TikTokRoomIdResponse {
    param([int]$Status, [string]$Body, [string]$Username)
    if ($Status -eq 403 -or $Status -eq 429) {
        throw (New-TikTokError 'TikTokBlocked' "HTTP $Status — rate-limited or geo-blocked")
    }
    $json = ConvertFrom-TikTokJson $Body
    if ($null -eq $json) {
        throw (New-TikTokError 'TikTokBlocked' "empty or non-JSON response (HTTP $Status) — TikTok blocked the request")
    }
    $code = $json.statusCode
    if ($null -eq $code) { throw (New-TikTokError 'InvalidResponse' 'no statusCode in api-live/user/room response') }
    if ($code -eq 19881007) { throw (New-TikTokError 'UserNotFound' "user '$Username' does not exist on TikTok") }
    if ($code -ne 0) { throw (New-TikTokError 'ApiError' "tiktok api statusCode=$code" ([long]$code)) }

    $roomId = "$($json.data.user.roomId)"
    if (-not $roomId -or $roomId -eq '0') {
        throw (New-TikTokError 'HostNotOnline' "'$Username' is not currently live")
    }
    $status = $json.data.liveRoom.status
    if ($null -eq $status) { $status = $json.data.user.status }
    if ($status -ne 2) {
        throw (New-TikTokError 'HostNotOnline' "'$Username' is not currently live (status=$status)")
    }
    $anchor = "$($json.data.user.id)"
    return [pscustomobject]@{ RoomId = $roomId; AnchorId = $(if ($anchor) { $anchor } else { $null }) }
}

function Get-TikTokRoomId {
    <#
    .SYNOPSIS
    check_online: resolve a username to its live room. Returns RoomId + AnchorId (the
    streamer's user id). Errors (TikTokLiveException.ErrorKind): UserNotFound,
    HostNotOnline, ApiError (.Code), TikTokBlocked, HttpError.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Username,
        [string]$UserAgent,
        [string]$Proxy,
        [int]$TimeoutSec = 10,
        [string]$Language,
        [string]$Region
    )
    $clean = $Username.Trim().TrimStart('@')
    $lang, $reg = Resolve-TikTokLocale $Language $Region
    $url = "$($script:TiktokUrl)api-live/user/room?aid=1988&app_name=tiktok_web&device_platform=web_pc" +
        "&app_language=$lang&browser_language=$lang-$reg&region=$reg&user_is_login=false" +
        "&uniqueId=$([Uri]::EscapeDataString($clean))&sourceType=54&staleTime=600000"
    $resp = Invoke-TikTokGet -Url $url -UserAgent $UserAgent -Proxy $Proxy -TimeoutSec $TimeoutSec
    return ConvertFrom-TikTokRoomIdResponse -Status $resp.Status -Body $resp.Body -Username $clean
}

function ConvertFrom-TikTokRoomInfoResponse {
    param([int]$Status, [string]$Body)
    if ($Status -eq 403 -or $Status -eq 429) {
        throw (New-TikTokError 'TikTokBlocked' "HTTP $Status — rate-limited or geo-blocked")
    }
    if (-not $Body) { throw (New-TikTokError 'InvalidResponse' "empty response from room/info (http $Status)") }
    $json = ConvertFrom-TikTokJson $Body
    if ($null -eq $json) { throw (New-TikTokError 'InvalidResponse' "room/info JSON parse failed (http $Status)") }
    if ($json.status_code -eq 4003110) {
        throw (New-TikTokError 'AgeRestricted' "18+ room — pass session cookies (-Cookies 'sessionid=xxx; sid_tt=xxx')")
    }
    if ($json.status_code -and $json.status_code -ne 0) {
        throw (New-TikTokError 'InvalidResponse' "room/info status_code=$($json.status_code)" ([long]$json.status_code))
    }
    $data = $json.data
    if ($null -eq $data) { throw (New-TikTokError 'InvalidResponse' "missing 'data' in room info") }

    $streamUrl = $null
    $sdk = $data.stream_url.live_core_sdk_data.pull_data.stream_data
    $nested = ConvertFrom-TikTokJson "$sdk"
    if ($nested) {
        $q = $nested.data
        $hd = $q.hd.main.flv
        if (-not $hd) { $hd = $q.uhd.main.flv }
        $streamUrl = [pscustomobject]@{
            FlvOrigin = $q.origin.main.flv; FlvHd = $hd; FlvSd = $q.sd.main.flv
            FlvLd = $q.ld.main.flv; FlvAo = $q.ao.main.flv
        }
    }
    return [pscustomobject]@{
        Title        = "$($data.title)"
        Viewers      = [long]$data.user_count
        Likes        = [long]$data.stats.like_count
        TotalViewers = [long]$data.stats.total_user
        StreamUrl    = $streamUrl
        RawJson      = $Body
    }
}

function Get-TikTokRoomInfo {
    <#
    .SYNOPSIS
    Optional room metadata: title, viewers, likes, FLV stream URLs. Not needed for
    events. 18+ rooms need session cookies (-Cookies 'sessionid=xxx; sid_tt=xxx'),
    otherwise ErrorKind AgeRestricted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$RoomId,
        [string]$Cookies,
        [string]$UserAgent,
        [string]$Proxy,
        [int]$TimeoutSec = 10,
        [string]$Language,
        [string]$Region
    )
    $lang, $reg = Resolve-TikTokLocale $Language $Region
    $tz = [Uri]::EscapeDataString((Get-TikTokSystemTimezone))
    $url = "$($script:WebcastUrl)room/info/?aid=1988&app_name=tiktok_web&device_platform=web_pc" +
        "&app_language=$lang&browser_language=$lang-$reg&browser_name=Mozilla&browser_online=true" +
        "&browser_platform=Win32&cookie_enabled=true&focus_state=true&from_page=user" +
        "&screen_height=1080&screen_width=1920&tz_name=$tz&webcast_language=$lang&room_id=$RoomId"
    $resp = Invoke-TikTokGet -Url $url -UserAgent $UserAgent -Cookies $Cookies -Proxy $Proxy -TimeoutSec $TimeoutSec
    return ConvertFrom-TikTokRoomInfoResponse -Status $resp.Status -Body $resp.Body
}

function ConvertFrom-TikTokAudienceResponse {
    param([int]$Status, [string]$Body)
    if (-not $Body) { throw (New-TikTokError 'InvalidResponse' "empty response from online_audience (http $Status)") }
    $json = ConvertFrom-TikTokJson $Body
    if ($null -eq $json) { throw (New-TikTokError 'InvalidResponse' "online_audience JSON parse failed (http $Status)") }
    $code = $json.status_code
    if ($null -eq $code) { throw (New-TikTokError 'InvalidResponse' 'no status_code in online_audience response') }
    if ($code -eq 20003) {
        throw (New-TikTokError 'SessionRequired' 'audience roster needs login — pass session cookies (-Cookies "sessionid=xxx; sid_tt=xxx") to Get-TikTokRoomAudience' 20003)
    }
    if ($code -ne 0) {
        $msg = "online_audience status_code=$code $($json.data.message)"
        throw (New-TikTokError 'InvalidResponse' $msg.TrimEnd() ([long]$code))
    }
    $data = $json.data
    if ($null -eq $data) { throw (New-TikTokError 'InvalidResponse' "missing 'data' in online_audience") }

    $viewers = foreach ($rank in @($data.ranks)) {
        $u = $rank.user
        if ($null -eq $u) { continue }
        $userId = if ("$($u.id_str)") { "$($u.id_str)" } else { "$([long]$u.id)" }
        $avatar = @($u.avatar_thumb.url_list)[0]
        [pscustomobject]@{
            Rank          = [long]$rank.rank
            Score         = [long]$rank.score
            UserId        = $userId
            Username      = "$($u.display_id)"
            Nickname      = "$($u.nickname)"
            SecUid        = "$($u.sec_uid)"
            AvatarUrl     = $(if ($avatar) { "$avatar" } else { $null })
            FollowerCount = [long]$u.follow_info.follower_count
            Verified      = $u.verified -eq $true
            IsFollower    = $u.is_follower -eq $true
            IsFollowing   = $u.is_following -eq $true
            IsSubscriber  = $u.is_subscribe -eq $true
        }
    }
    return [pscustomobject]@{
        Total     = [long]$data.total
        Anonymous = [long]$data.anonymous
        Viewers   = @($viewers)
        RawJson   = $Body
    }
}

function Get-TikTokRoomAudience {
    <#
    .SYNOPSIS
    Full audience roster — every named viewer in the room (the web viewer panel).
    Login-gated: -Cookies 'sessionid=xxx; sid_tt=xxx' is required for this call only;
    without it you get ErrorKind SessionRequired. -AnchorId comes from Get-TikTokRoomId;
    omit it to resolve via room info (one extra request).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$RoomId,
        [string]$AnchorId,
        [string]$Cookies,
        [string]$UserAgent,
        [string]$Proxy,
        [int]$TimeoutSec = 10,
        [string]$Language,
        [string]$Region
    )
    $common = @{ UserAgent = $UserAgent; Proxy = $Proxy; TimeoutSec = $TimeoutSec; Language = $Language; Region = $Region }
    if (-not $AnchorId) {
        $info = Get-TikTokRoomInfo -RoomId $RoomId -Cookies $Cookies @common
        $AnchorId = "$((ConvertFrom-TikTokJson $info.RawJson).data.owner.id_str)"
        if (-not $AnchorId) { throw (New-TikTokError 'InvalidResponse' 'no owner id in room info') }
    }
    $lang, $reg = Resolve-TikTokLocale $Language $Region
    $url = "$($script:WebcastUrl)ranklist/online_audience/?aid=1988&app_name=tiktok_web&device_platform=web_pc" +
        "&app_language=$lang&browser_language=$lang-$reg&channel=tiktok_web&room_id=$RoomId&anchor_id=$AnchorId"
    $resp = Invoke-TikTokGet -Url $url -UserAgent $UserAgent -Cookies $Cookies -Proxy $Proxy -TimeoutSec $TimeoutSec
    return ConvertFrom-TikTokAudienceResponse -Status $resp.Status -Body $resp.Body
}
