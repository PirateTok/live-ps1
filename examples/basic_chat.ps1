#!/usr/bin/env pwsh
# Connect and print chat, gifts, likes, joins, follows, viewer counts. Ctrl+C to stop.
# Usage: pwsh examples/basic_chat.ps1 <username>
param([Parameter(Mandatory, Position = 0)][string]$Username)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

$client = Connect-TikTokLive $Username
Start-TikTokLive $client -OnEvent {
    param($e)
    $d = $e.Data
    switch ($e.Type) {
        'Connected' { Write-Host "connected — room $($d.room_id)" }
        'Chat' { Write-Host "[chat] $($d.user.unique_id): $($d.comment)" }
        'Gift' { Write-Host "[gift] $($d.user.unique_id) sent $($d.gift_details.name) x$($d.repeat_count)" }
        'Like' { Write-Host "[like] $($d.user.unique_id) +$($d.count) (total $($d.total))" }
        'Join' { Write-Host "[join] $($d.user.unique_id)" }
        'Follow' { Write-Host "[follow] $($d.user.unique_id)" }
        'Share' { Write-Host "[share] $($d.user.unique_id)" }
        'RoomUserSeq' { Write-Host "[viewers] $($d.viewer_count)" }
        'LiveEnded' { Write-Host '[ended]'; Disconnect-TikTokLive $client }
        'Reconnecting' { Write-Host "[reconnecting] attempt $($d.attempt)/$($d.max_retries) in $($d.delay_secs)s — $($d.reason)" }
        'Disconnected' { Write-Host "[disconnected] $($d.reason)" }
    }
}
