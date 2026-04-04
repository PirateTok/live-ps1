#!/usr/bin/env pwsh
# Track gifts in a TikTok live stream.
# Usage: pwsh examples/gift_tracker.ps1 <username> [duration_seconds]

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Username,
    [int]$Duration = 60
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

Write-Host "Connecting to $Username..."
$conn = Connect-TikTokLive $Username
Write-Host "Connected! room_id=$($conn.RoomId) (tracking gifts for ${Duration}s)"
Write-Host ""

$deadline = [DateTime]::UtcNow.AddSeconds($Duration)
$totalDiamonds = 0
$giftCount = 0

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        $events = Receive-TikTokFrame $conn
        if ($null -eq $events) {
            Write-Host "Connection closed."
            break
        }
        foreach ($e in $events) {
            if ($e.Method -eq "WebcastGiftMessage") {
                $giftCount++
                $nick = if ($e.User) { $e.User.UniqueId } else { "?" }
                $name = if ($e.GiftName) { $e.GiftName } else { "gift" }
                $diamonds = if ($e.DiamondCount) { $e.DiamondCount } else { 0 }
                $count = if ($e.RepeatCount) { $e.RepeatCount } else { 1 }
                $total = $diamonds * $count
                $totalDiamonds += $total
                Write-Host "[GIFT] $nick sent $name x$count ($total diamonds)"
            }
            if ($e.Method -eq "WebcastControlMessage" -and $e.Action -eq 3) {
                Write-Host "[ENDED] Stream ended."
                $deadline = [DateTime]::UtcNow
            }
        }
    }
} finally {
    Close-TikTokLive $conn
    Write-Host ""
    Write-Host "--- Summary ---"
    Write-Host "$giftCount gifts, $totalDiamonds total diamonds"
}
