#!/usr/bin/env pwsh
# Full audience roster of a live room. Login-gated: needs TikTok session cookies.
# Usage: pwsh examples/audience.ps1 <username> "sessionid=xxx; sid_tt=xxx"
param([Parameter(Mandatory, Position = 0)][string]$Username, [Parameter(Mandatory, Position = 1)][string]$Cookies)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

$live = Get-TikTokRoomId $Username
try {
    $aud = Get-TikTokRoomAudience $live.RoomId -AnchorId $live.AnchorId -Cookies $Cookies
} catch [PirateTok.Live.TikTokLiveException] {
    Write-Host "[$($_.Exception.ErrorKind)] $($_.Exception.Message)"
    exit $(if ($_.Exception.ErrorKind -eq 'SessionRequired') { 4 } else { 3 })
}
Write-Host "total=$($aud.Total) anonymous=$($aud.Anonymous) named=$($aud.Viewers.Count)"
foreach ($v in $aud.Viewers) {
    Write-Host ("#{0} {1} ({2}) score={3} followers={4}" -f $v.Rank, $v.Username, $v.Nickname, $v.Score, $v.FollowerCount)
}
