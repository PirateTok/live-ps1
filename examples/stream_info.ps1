#!/usr/bin/env pwsh
# Fetch room metadata and stream URLs.
# Usage: pwsh examples/stream_info.ps1 <username> [cookies]

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Username,
    [string]$Cookies = ""
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

try {
    $roomId = Get-TikTokRoomId $Username
    Write-Host "=== Room Info ==="
    Write-Host "Username: @$Username"
    Write-Host "Room ID:  $roomId"

    $info = Get-TikTokStreamInfo $roomId -Cookies $Cookies
    Write-Host "Title:    $($info.title)"
    Write-Host "Viewers:  $($info.user_count)"
    Write-Host ""

    $best = Get-TikTokBestStreamUrl $info
    if ($best) {
        Write-Host "=== Best Stream URL ($($best.Quality)) ==="
        Write-Host $best.Url
    }

    if ($info.stream_url) {
        Write-Host ""
        Write-Host "=== All Stream URLs ==="
        $info.stream_url | ConvertTo-Json -Depth 3
    }
} catch {
    $ex = $_.Exception
    if ($ex -is [TikTokLiveException] -and $ex.ErrorKind -eq "AgeRestricted") {
        Write-Host "18+ room -- pass session cookies: pwsh stream_info.ps1 $Username 'sessionid=xxx; sid_tt=xxx'"
    } else {
        Write-Host "ERROR: $($ex.Message)"
    }
    exit 1
}
