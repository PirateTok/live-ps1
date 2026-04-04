@{
    RootModule        = 'PirateTok.Live.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a7e3b1c4-9f2d-4e8a-b5c6-1d3f7a8e9b0c'
    Author            = 'Zmole Cristian'
    CompanyName       = 'PirateTok'
    Copyright         = '(c) 2026 Zmole Cristian. 0BSD License.'
    Description       = 'TikTok Live WebSocket connector -- real-time chat, gifts, likes, and viewer events. No authentication required.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Connect-TikTokLive',
        'Get-TikTokTtwid',
        'Get-TikTokRoomId',
        'Get-TikTokStreamInfo',
        'Get-TikTokBestStreamUrl',
        'Send-TikTokHeartbeat',
        'Receive-TikTokFrame',
        'Close-TikTokLive'
    )
    PrivateData = @{
        PSData = @{
            Tags         = @('tiktok', 'live', 'websocket', 'streaming', 'events', 'chat', 'protobuf')
            LicenseUri   = 'https://github.com/PirateTok/live-ps1/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/PirateTok/live-ps1'
            IconUri      = 'https://raw.githubusercontent.com/PirateTok/live-ps1/main/logo.png'
            ReleaseNotes = 'Initial release -- 8 cmdlets, 64 decoded event types, typed errors, UA rotation, sub-routed convenience events, enriched user fields, PS 5.1 + PS 7 support.'
        }
    }
}
