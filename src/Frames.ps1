# WSS URL + push frames (heartbeat, enter_room, ack).

# Byte-exact view of WebcastResponse: internal_ext must be echoed back verbatim in acks,
# so it is decoded as bytes, not as a UTF-8 string.
[PirateTok.Live.ProtoCodec]::Load(@'
message PsWebcastResponse {
    repeated WebcastResponseMessage messages = 1;
    bytes internal_ext = 5;
    bool needs_ack = 9;
}
'@)

$script:CdnHosts = @{ global = 'webcast-ws.tiktok.com'; eu = 'webcast-ws.eu.tiktok.com'; us = 'webcast-ws.us.tiktok.com' }

function New-TikTokWsUrl {
    param(
        [Parameter(Mandatory)][string]$CdnHost,
        [Parameter(Mandatory)][string]$RoomId,
        [string]$Language = 'en',
        [string]$Region = 'US',
        [bool]$Compress = $true,
        [double]$HeartbeatInterval = 10
    )
    $rtt = (100 + (Get-Random -Minimum 0.0 -Maximum 100.0)).ToString('F3', [System.Globalization.CultureInfo]::InvariantCulture)
    $params = @(
        'version_code=180800', 'device_platform=web', 'cookie_enabled=true', 'screen_width=1920', 'screen_height=1080'
        "browser_language=$Language-$Region", 'browser_platform=Linux%20x86_64', 'browser_name=Mozilla'
        'browser_version=5.0%20(X11)', 'browser_online=true', "tz_name=$([Uri]::EscapeDataString((Get-TikTokSystemTimezone)))"
        'app_name=tiktok_web', 'sup_ws_ds_opt=1', 'update_version_code=2.0.0'
        "compress=$(if ($Compress) { 'gzip' } else { '' })", "webcast_language=$Language", 'ws_direct=1', 'aid=1988'
        'live_id=12', "app_language=$Language", 'client_enter=1', "room_id=$RoomId", 'identity=audience'
        'history_comment_count=6', "last_rtt=$rtt", "heartbeat_duration=$([long]($HeartbeatInterval * 1000))"
        'resp_content_type=protobuf', 'did_rule=3'
    )
    return "wss://$CdnHost/webcast/im/ws_proxy/ws_reuse_supplement/?$($params -join '&')"
}

function New-TikTokPushFrame([string]$Type, [byte[]]$Payload, $LogId = $null) {
    $frame = @{ payload_encoding = 'pb'; payload_type = $Type; payload = $Payload }
    if ($null -ne $LogId) { $frame.log_id = $LogId }
    return ConvertTo-TikTokProto 'WebcastPushFrame' $frame
}

function New-TikTokHeartbeatFrame([string]$RoomId) {
    return New-TikTokPushFrame 'hb' (ConvertTo-TikTokProto 'HeartbeatMessage' @{ room_id = [uint64]$RoomId })
}

function New-TikTokEnterRoomFrame([string]$RoomId) {
    $msg = @{ room_id = [long]$RoomId; live_id = 12; identity = 'audience'; filter_welcome_msg = '0' }
    return New-TikTokPushFrame 'im_enter_room' (ConvertTo-TikTokProto 'WebcastImEnterRoomMessage' $msg)
}

function New-TikTokAckFrame($LogId, [byte[]]$InternalExt) {
    return New-TikTokPushFrame 'ack' $InternalExt $LogId
}
