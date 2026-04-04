#!/usr/bin/env pwsh
# Connect to a TikTok Live room and print events.

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Username,
    [int]$Duration = 30
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

Write-Host "Connecting to $Username..."
$conn = Connect-TikTokLive $Username
Write-Host "Connected! room_id=$($conn.RoomId) (running ${Duration}s)"
Write-Host ""

$deadline = [DateTime]::UtcNow.AddSeconds($Duration)
$eventCount = 0

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        $events = Receive-TikTokFrame $conn
        if ($null -eq $events) {
            Write-Host "Connection closed."
            break
        }
        foreach ($e in $events) {
            $eventCount++
            switch ($e.Method) {
                "WebcastChatMessage" {
                    $nick = if ($e.User) { $e.User.UniqueId } else { "?" }
                    Write-Host "[CHAT] $nick`: $($e.Content)"
                }
                "WebcastGiftMessage" {
                    $nick = if ($e.User) { $e.User.UniqueId } else { "?" }
                    $name = if ($e.GiftName) { $e.GiftName } else { "gift" }
                    $diamonds = if ($e.DiamondCount) { " ($($e.DiamondCount) diamonds)" } else { "" }
                    $combo = if ($e.IsCombo) { " [COMBO x$($e.ComboCount)]" } else { "" }
                    Write-Host "[GIFT] $nick sent $name x$($e.RepeatCount)$diamonds$combo"
                }
                "WebcastLikeMessage" {
                    $nick = if ($e.User) { $e.User.UniqueId } else { "?" }
                    Write-Host "[LIKE] $nick (total: $($e.TotalLikes))"
                }
                "Follow" {
                    $nick = if ($e.User) { $e.User.UniqueId } else { "?" }
                    Write-Host "[FOLLOW] $nick"
                }
                "Share" {
                    $nick = if ($e.User) { $e.User.UniqueId } else { "?" }
                    Write-Host "[SHARE] $nick"
                }
                "Join" {
                    $nick = if ($e.User) { $e.User.UniqueId } else { "?" }
                    Write-Host "[JOIN] $nick"
                }
                "WebcastRoomUserSeqMessage" {
                    Write-Host "[VIEWERS] $($e.ViewerCount)"
                }
                "LiveEnded" {
                    Write-Host "[ENDED] Stream ended."
                    $deadline = [DateTime]::UtcNow
                }
                default {
                    # skip raw duplicates of sub-routed events
                    if ($e.Method -notin @("WebcastSocialMessage","WebcastMemberMessage","WebcastControlMessage")) {
                        Write-Host "[OTHER] $($e.Method)"
                    }
                }
            }
        }
    }
} finally {
    Close-TikTokLive $conn
    Write-Host ""
    Write-Host "Done. $eventCount events in ${Duration}s."
}
