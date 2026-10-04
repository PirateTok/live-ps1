# PirateTok.Live — TikTok Live WebSocket connector for PowerShell 5.1+ / 7+.
# Import-Module PirateTok.Live; $c = Connect-TikTokLive username_here
# while ($c.State -ne 'Disconnected') { foreach ($e in Receive-TikTokEvent $c) { ... } }

$ErrorActionPreference = 'Stop'

if ([System.Net.ServicePointManager]::SecurityProtocol -ne [System.Net.SecurityProtocolType]::SystemDefault) {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}
Add-Type -AssemblyName System.IO.Compression

foreach ($file in 'Schemas', 'Codec', 'Locale', 'Http', 'Api', 'Events', 'Helpers', 'Wss', 'Frames', 'Client') {
    . (Join-Path $PSScriptRoot "src/$file.ps1")
}

Export-ModuleMember -Function @(
    # check_online / metadata / audience
    'Get-TikTokRoomId', 'Get-TikTokRoomInfo', 'Get-TikTokRoomAudience', 'Get-TikTokTtwid'
    # live client
    'Connect-TikTokLive', 'Receive-TikTokEvent', 'Disconnect-TikTokLive', 'Start-TikTokLive'
    # event decoding + helpers
    'ConvertTo-TikTokEvents', 'Get-TikTokTopViewers', 'Test-TikTokComboGift', 'Test-TikTokStreakOver', 'Get-TikTokDiamondTotal'
    'New-TikTokLikeAccumulator', 'New-TikTokGiftStreakTracker', 'New-TikTokProfileCache', 'Get-TikTokProfile'
    # locale / UA
    'Get-TikTokRandomUserAgent', 'Get-TikTokSystemTimezone', 'Get-TikTokSystemLocale'
)
