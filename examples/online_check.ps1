#!/usr/bin/env pwsh
# Check if a TikTok user is currently live.

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Username
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

try {
    $roomId = Get-TikTokRoomId $Username
    Write-Host "LIVE  $Username  room_id=$roomId"
} catch {
    $ex = $_.Exception
    if ($ex -is [TikTokLiveException]) {
        switch ($ex.ErrorKind) {
            "UserNotFound"  { Write-Host "404   $Username does not exist"; exit 1 }
            "HostNotOnline" { Write-Host "OFF   $Username"; exit 1 }
            "TikTokBlocked" { Write-Host "BLOCKED  $($ex.Message)"; exit 1 }
            default         { Write-Host "ERROR [$($ex.ErrorKind)] $($ex.Message)"; exit 1 }
        }
    }
    Write-Host "ERROR $($ex.Message)"
    exit 1
}
