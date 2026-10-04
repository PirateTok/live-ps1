@{
    RootModule           = 'PirateTok.Live.psm1'
    ModuleVersion        = '0.2.0'
    GUID                 = 'a7e3b1c4-9f2d-4e8a-b5c6-1d3f7a8e9b0c'
    Author               = 'Zmole Cristian'
    CompanyName          = 'PirateTok'
    Copyright            = '(c) 2026 Zmole Cristian. 0BSD License.'
    Description          = 'TikTok Live WebSocket connector -- real-time chat, gifts, likes, and viewer events. No authentication required.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Get-TikTokRoomId', 'Get-TikTokRoomInfo', 'Get-TikTokRoomAudience', 'Get-TikTokTtwid',
        'Connect-TikTokLive', 'Receive-TikTokEvent', 'Disconnect-TikTokLive', 'Start-TikTokLive',
        'ConvertTo-TikTokEvents', 'Get-TikTokTopViewers', 'Test-TikTokComboGift', 'Test-TikTokStreakOver', 'Get-TikTokDiamondTotal',
        'New-TikTokLikeAccumulator', 'New-TikTokGiftStreakTracker', 'New-TikTokProfileCache', 'Get-TikTokProfile',
        'Get-TikTokRandomUserAgent', 'Get-TikTokSystemTimezone', 'Get-TikTokSystemLocale'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('tiktok', 'live', 'websocket', 'streaming', 'events', 'chat', 'protobuf')
            LicenseUri   = 'https://github.com/PirateTok/live-ps1/blob/main/LICENSE'
            ProjectUri   = 'https://piratetok.rosint.org/'
            IconUri      = 'https://raw.githubusercontent.com/PirateTok/live-ps1/main/logo.png'
            ReleaseNotes = '0.2.0: full parity rewrite — reconnecting poll client (ttwid retry + reuse, healthy-session budget), proxy, language/region/compress, 64 typed event types, top viewers, audience roster, helpers. Homepage piratetok.rosint.org.'
        }
    }
}
