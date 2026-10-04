#!/usr/bin/env pwsh
# Cached profile lookup (second call is served from the cache).
# Usage: pwsh examples/profile_lookup.ps1 <username>
param([Parameter(Mandatory, Position = 0)][string]$Username)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

$cache = New-TikTokProfileCache -TtlSecs 300
try {
    $p = $cache.Fetch($Username)
} catch [PirateTok.Live.TikTokLiveException] {
    Write-Host "[$($_.Exception.ErrorKind)] $($_.Exception.Message)"; exit 1
}
Write-Host "@$($p.UniqueId) — $($p.Nickname)$(if ($p.Verified) { ' (verified)' })"
Write-Host "followers $($p.FollowerCount)  following $($p.FollowingCount)  likes $($p.HeartCount)  videos $($p.VideoCount)"
Write-Host "avatar $($p.AvatarLarge)"
if ($p.BioLink) { Write-Host "link $($p.BioLink)" }
Write-Host "cached: $($null -ne $cache.Cached($Username))"
