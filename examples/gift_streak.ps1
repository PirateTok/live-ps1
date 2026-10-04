#!/usr/bin/env pwsh
# Gift streak tracking: per-event deltas and diamond totals from TikTok's running counts.
# Usage: pwsh examples/gift_streak.ps1 <username>
param([Parameter(Mandatory, Position = 0)][string]$Username)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

$tracker = New-TikTokGiftStreakTracker
$client = Connect-TikTokLive $Username
Start-TikTokLive $client -OnEvent {
    param($e)
    if ($e.Type -eq 'Reconnecting') { $tracker.Reset() }
    if ($e.Type -ne 'Gift') { return }
    $s = $tracker.Process($e.Data)
    $who = $e.Data.user.unique_id
    $name = $e.Data.gift_details.name
    if ($s.IsFinal) {
        Write-Host "[final]  $who $name x$($s.TotalGiftCount) = $($s.TotalDiamondCount) diamonds"
    } elseif ($s.EventGiftCount -gt 0) {
        Write-Host "[streak] $who $name +$($s.EventGiftCount) (running x$($s.TotalGiftCount))"
    }
}
