#!/usr/bin/env pwsh
# Check whether a user is live, without opening the WSS.
# Usage: pwsh examples/online_check.ps1 <username>
param([Parameter(Mandatory, Position = 0)][string]$Username)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../PirateTok.Live.psd1" -Force

try {
    $live = Get-TikTokRoomId $Username
    Write-Host "LIVE  @$Username — room $($live.RoomId) (anchor $($live.AnchorId))"
} catch [PirateTok.Live.TikTokLiveException] {
    switch ($_.Exception.ErrorKind) {
        'HostNotOnline' { Write-Host "OFF   @$Username — not currently live"; exit 1 }
        'UserNotFound' { Write-Host "404   @$Username — user does not exist"; exit 2 }
        default { Write-Host "ERR   [$($_.Exception.ErrorKind)] $($_.Exception.Message)"; exit 3 }
    }
}
