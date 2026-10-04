#!/usr/bin/env pwsh
# Room metadata + FLV stream URLs. 18+ rooms need session cookies.
# Usage: pwsh examples/stream_info.ps1 <username> ["sessionid=xxx; sid_tt=xxx"]
param([Parameter(Mandatory, Position = 0)][string]$Username, [Parameter(Position = 1)][string]$Cookies)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

$live = Get-TikTokRoomId $Username
$info = Get-TikTokRoomInfo $live.RoomId -Cookies $Cookies
Write-Host "Title:   $($info.Title)"
Write-Host "Viewers: $($info.Viewers)  Likes: $($info.Likes)  Total: $($info.TotalViewers)"
if ($info.StreamUrl) {
    foreach ($q in 'FlvOrigin', 'FlvHd', 'FlvSd', 'FlvLd', 'FlvAo') {
        if ($info.StreamUrl.$q) { Write-Host ("{0,-10} {1}" -f $q, $info.StreamUrl.$q) }
    }
}
