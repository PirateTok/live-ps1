# Wire message → typed events. Tier A (39) + Tier B (25) decode into Data hashtables
# (snake_case proto field names); everything else is Unknown { Method, RawPayload }.
# Sub-routed messages fire the raw event AND the convenience event.

$script:EventTypes = @{
    # Tier A — core
    WebcastChatMessage                   = 'Chat'
    WebcastGiftMessage                   = 'Gift'
    WebcastLikeMessage                   = 'Like'
    WebcastMemberMessage                 = 'Member'
    WebcastSocialMessage                 = 'Social'
    WebcastRoomUserSeqMessage            = 'RoomUserSeq'
    WebcastControlMessage                = 'Control'
    # Tier A — useful
    WebcastLiveIntroMessage              = 'LiveIntro'
    WebcastRoomMessage                   = 'RoomMessage'
    WebcastCaptionMessage                = 'Caption'
    WebcastGoalUpdateMessage             = 'GoalUpdate'
    WebcastImDeleteMessage               = 'ImDelete'
    # Tier A — niche
    WebcastRankUpdateMessage             = 'RankUpdate'
    WebcastPollMessage                   = 'Poll'
    WebcastEnvelopeMessage               = 'Envelope'
    WebcastRoomPinMessage                = 'RoomPin'
    WebcastUnauthorizedMemberMessage     = 'UnauthorizedMember'
    WebcastLinkMicMethod                 = 'LinkMicMethod'
    WebcastLinkMicBattle                 = 'LinkMicBattle'
    WebcastLinkMicArmies                 = 'LinkMicArmies'
    WebcastLinkMessage                   = 'LinkMessage'
    WebcastLinkLayerMessage              = 'LinkLayer'
    WebcastLinkMicLayoutStateMessage     = 'LinkMicLayoutState'
    WebcastGiftPanelUpdateMessage        = 'GiftPanelUpdate'
    WebcastInRoomBannerMessage           = 'InRoomBanner'
    WebcastGuideMessage                  = 'Guide'
    # Tier A — cross-lib consensus + Ophanim-only
    WebcastEmoteChatMessage              = 'EmoteChat'
    WebcastQuestionNewMessage            = 'QuestionNew'
    WebcastSubNotifyMessage              = 'SubNotify'
    WebcastBarrageMessage                = 'Barrage'
    WebcastHourlyRankMessage             = 'HourlyRank'
    WebcastMsgDetectMessage              = 'MsgDetect'
    WebcastLinkMicFanTicketMethod        = 'LinkMicFanTicket'
    WebcastRoomVerifyMessage             = 'RoomVerify'
    WebcastOecLiveShoppingMessage        = 'OecLiveShopping'
    WebcastGiftBroadcastMessage          = 'GiftBroadcast'
    WebcastRankTextMessage               = 'RankText'
    WebcastGiftDynamicRestrictionMessage = 'GiftDynamicRestriction'
    WebcastViewerPicksUpdateMessage      = 'ViewerPicksUpdate'
    # Tier B
    WebcastAccessControlMessage          = 'AccessControl'
    WebcastAccessRecallMessage           = 'AccessRecall'
    WebcastAlertBoxAuditResultMessage    = 'AlertBoxAuditResult'
    WebcastBindingGiftMessage            = 'BindingGift'
    WebcastBoostCardMessage              = 'BoostCard'
    WebcastBottomMessage                 = 'BottomMessage'
    WebcastGameRankNotifyMessage         = 'GameRankNotify'
    WebcastGiftPromptMessage             = 'GiftPrompt'
    WebcastLinkStateMessage              = 'LinkState'
    WebcastLinkMicBattlePunishFinish     = 'LinkMicBattlePunishFinish'
    WebcastLinkmicBattleTaskMessage      = 'LinkmicBattleTask'
    WebcastMarqueeAnnouncementMessage    = 'MarqueeAnnouncement'
    WebcastNoticeMessage                 = 'Notice'
    WebcastNotifyMessage                 = 'Notify'
    WebcastPartnershipDropsUpdateMessage = 'PartnershipDropsUpdate'
    WebcastPartnershipGameOfflineMessage = 'PartnershipGameOffline'
    WebcastPartnershipPunishMessage      = 'PartnershipPunish'
    WebcastPerceptionMessage             = 'Perception'
    WebcastSpeakerMessage                = 'Speaker'
    WebcastSubCapsuleMessage             = 'SubCapsule'
    WebcastSubPinEventMessage            = 'SubPinEvent'
    WebcastSubscriptionNotifyMessage     = 'SubscriptionNotify'
    WebcastToastMessage                  = 'Toast'
    WebcastSystemMessage                 = 'SystemMessage'
    WebcastLiveGameIntroMessage          = 'LiveGameIntro'
}

function New-TikTokEvent([string]$Type, [string]$Method, $Data, [byte[]]$Payload) {
    return [pscustomobject]@{ Type = $Type; Method = $Method; Data = $Data; RawPayload = $Payload }
}

function ConvertTo-TikTokEvents {
    <#
    .SYNOPSIS
    Decode one wire message (method + protobuf payload) into events. Returns the raw
    event plus Follow / Share / Join / LiveEnded convenience events where they apply.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Payload)

    $type = $script:EventTypes[$Method]
    if (-not $type) { return New-TikTokEvent 'Unknown' $Method $null $Payload }

    try {
        $data = [PirateTok.Live.ProtoCodec]::Decode($Method, $Payload)
    } catch [System.Management.Automation.MethodInvocationException] {
        $evt = New-TikTokEvent 'Unknown' $Method $null $Payload
        $evt | Add-Member -NotePropertyName DecodeError -NotePropertyValue $_.Exception.GetBaseException().Message
        return $evt
    }

    $events = [System.Collections.Generic.List[object]]::new()
    $events.Add((New-TikTokEvent $type $Method $data $Payload))
    $action = $data['action']
    switch ($Method) {
        'WebcastSocialMessage' {
            if ($action -eq 1) { $events.Add((New-TikTokEvent 'Follow' $Method $data $Payload)) }
            elseif ($action -ge 2 -and $action -le 5) { $events.Add((New-TikTokEvent 'Share' $Method $data $Payload)) }
        }
        'WebcastMemberMessage' {
            if ($action -eq 1) { $events.Add((New-TikTokEvent 'Join' $Method $data $Payload)) }
        }
        'WebcastControlMessage' {
            if ($action -eq 3) { $events.Add((New-TikTokEvent 'LiveEnded' $Method $data $Payload)) }
        }
    }
    return $events.ToArray()
}

# ---- gift helpers (operate on a Gift event's Data) ----

function Test-TikTokComboGift([Parameter(Mandatory)]$Gift) {
    return ($null -ne $Gift.gift_details) -and $Gift.gift_details.gift_type -eq 1
}

function Test-TikTokStreakOver([Parameter(Mandatory)]$Gift) {
    return (-not (Test-TikTokComboGift $Gift)) -or $Gift.repeat_end -eq 1
}

function Get-TikTokDiamondTotal([Parameter(Mandatory)]$Gift) {
    if ($null -eq $Gift.gift_details) { return [long]0 }
    return [long]$Gift.gift_details.diamond_count * [Math]::Max([long]$Gift.repeat_count, 1)
}

# ---- RoomUserSeq helper ----

function Get-TikTokTopViewers([Parameter(Mandatory)]$RoomUserSeq) {
    <#
    .SYNOPSIS
    The top-viewers box next to the viewer counter: ranks_list entries with a decoded
    user, sorted by rank ascending. Pass a RoomUserSeq event's Data. No cookies needed.
    #>
    return , @(@($RoomUserSeq.ranks_list) | Where-Object { $null -ne $_ -and $null -ne $_.user } | Sort-Object { $_.rank })
}
