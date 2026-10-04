# Protobuf schemas (proto3 text) parsed at import by src/Proto.ps1.
# Tag numbers match live-rs (ground truth). Undeclared fields are skipped.
$script:ProtoSchemaText = @'
// ---- common ----

message Image {
    repeated string urls = 1;
    string uri = 2;
    int32 width = 3;
    int32 height = 4;
}

message PrivilegeLogExtra {
    string data_version = 1;
    string privilege_id = 2;
    string level = 5;
}

message BadgeImage {
    Image image = 2;
}

message BadgeText {
    string key = 2;
    string default_pattern = 3;
}

message BadgeString {
    string content_str = 2;
}

message BadgeStruct {
    int32 display_type = 1;
    int32 badge_scene = 3;
    bool display = 11;
    PrivilegeLogExtra log_extra = 12;
    BadgeImage image_badge = 20;
    BadgeText text_badge = 21;
    BadgeString string_badge = 22;
}

message FollowInfo {
    int64 following_count = 1;
    int64 follower_count = 2;
    int64 follow_status = 3;
}

message FansClubData {
    string club_name = 1;
    int32 level = 2;
}

message FansClubMember {
    FansClubData data = 1;
}

message User {
    int64 id = 1;
    string nickname = 3;
    string bio_description = 5;
    Image avatar_thumb = 9;
    Image avatar_medium = 10;
    Image avatar_large = 11;
    bool verified = 12;
    FollowInfo follow_info = 22;
    FansClubMember fans_club = 24;
    int32 top_vip_no = 31;
    int64 pay_score = 34;
    int64 fan_ticket_count = 35;
    string unique_id = 38;
    string display_id = 46;
    repeated BadgeStruct badge_list = 64;
    int64 follow_status = 1024;
    bool is_follower = 1029;
    bool is_following = 1030;
    bool is_subscribe = 1090;
}

message GiftDetails {
    int64 id = 5;
    bool combo = 10;
    int32 gift_type = 11;
    int32 diamond_count = 12;
    string name = 16;
}

message TopGifter {
    User user = 1;
    int64 coins = 2;
}

// ---- frames ----

message WebcastPushFrame {
    uint64 seq_id = 1;
    int64 log_id = 2;
    uint64 service = 3;
    uint64 method = 4;
    map<string, string> headers = 5;
    string payload_encoding = 6;
    string payload_type = 7;
    bytes payload = 8;
}

message WebcastResponseMessage {
    string type = 1;
    bytes payload = 2;
}

message WebcastResponse {
    repeated WebcastResponseMessage messages = 1;
    string cursor = 2;
    int64 fetch_interval = 3;
    int64 now = 4;
    string internal_ext = 5;
    int32 fetch_type = 6;
    map<string, string> route_params = 7;
    int64 heartbeat_duration = 8;
    bool needs_ack = 9;
    string push_server = 10;
    bool is_first = 11;
    string history_comment_cursor = 12;
    bool history_no_more = 13;
}

message HeartbeatMessage {
    uint64 room_id = 1;
}

message WebcastImEnterRoomMessage {
    int64 room_id = 1;
    string room_tag = 2;
    string live_region = 3;
    int64 live_id = 4;
    string identity = 5;
    string cursor = 6;
    int32 account_type = 7;
    int64 enter_unique_id = 8;
    string filter_welcome_msg = 9;
    bool is_anchor_continue_keep_msg = 10;
}

// ---- messages ----

// ─── Core events (7) ─────────────────────────────────────

message WebcastChatMessage {
    bytes common = 1;
    User user = 2;
    string comment = 3;
    string content_language = 14;
}

message WebcastGiftMessage {
    bytes common = 1;
    int32 gift_id = 2;
    int64 fan_ticket_count = 3;
    int32 group_count = 4;
    int32 repeat_count = 5;
    int32 combo_count = 6;
    User user = 7;
    User to_user = 8;
    int32 repeat_end = 9;
    uint64 group_id = 11;
    GiftDetails gift_details = 15;
    bool is_first_sent = 25;
}

message WebcastLikeMessage {
    bytes common = 1;
    int32 count = 2;
    int32 total = 3;
    User user = 5;
}

message WebcastMemberMessage {
    bytes common = 1;
    User user = 2;
    int32 member_count = 3;
    int32 action = 10;
}

message WebcastSocialMessage {
    bytes common = 1;
    User user = 2;
    int64 share_type = 3;
    int64 action = 4;
    string share_target = 5;
    int32 follow_count = 6;
}

message Contributor {
    int64 score = 1;
    User user = 2;
    int64 rank = 3;
    int64 delta = 4;
}

message WebcastRoomUserSeqMessage {
    bytes common = 1;
    repeated Contributor ranks_list = 2;
    int64 viewer_count = 3;
    string pop_str = 4;
    repeated Contributor seats_list = 5;
    int64 popularity = 6;
    int64 total_user = 7;
    int64 anonymous = 8;
}

message WebcastControlMessage {
    bytes common = 1;
    int32 action = 2;
    string reason = 3;
}

// ─── Useful events (5) ───────────────────────────────────

message WebcastLiveIntroMessage {
    bytes common = 1;
    int64 room_id = 2;
    int32 audit_status = 3;
    string content = 4;
    User host = 5;
}

message WebcastRoomMessage {
    bytes common = 1;
    string content = 2;
}

message CaptionData {
    string language = 1;
    string text = 2;
}

message WebcastCaptionMessage {
    bytes common = 1;
    uint64 timestamp = 2;
    CaptionData caption_data = 4;
}

message WebcastGoalUpdateMessage {
    bytes common = 1;
    int64 contributor_id = 4;
    int64 contribute_count = 9;
    int64 contribute_score = 10;
    bool pin = 13;
    bool unpin = 14;
}

message WebcastImDeleteMessage {
    bytes common = 1;
    repeated int64 delete_msg_ids = 2;
    repeated int64 delete_user_ids = 3;
}

// ─── Niche events ───────────────────────────────────────

message WebcastRankUpdateMessage {
    bytes common = 1;
    int64 group_type = 3;
    int64 priority = 5;
}

message WebcastPollMessage {
    bytes common = 1;
    int32 message_type = 2;
    int64 poll_id = 3;
    bytes start_content = 4;
    bytes end_content = 5;
    bytes update_content = 6;
    int32 poll_kind = 7;
}

message EnvelopeInfo {
    string envelope_id = 1;
    int32 business_type = 2;
    int32 diamond_count = 5;
    int32 people_count = 6;
}

message WebcastEnvelopeMessage {
    bytes common = 1;
    EnvelopeInfo envelope_info = 2;
    int32 display = 3;
}

message WebcastRoomPinMessage {
    bytes common = 1;
    bytes pinned_message = 2;
    string original_msg_type = 30;
    uint64 timestamp = 31;
}

message WebcastUnauthorizedMemberMessage {
    bytes common = 1;
    int32 action = 2;
    bytes nick_name_prefix = 3;
    string nick_name = 4;
}

message WebcastLinkMicMethod {
    bytes common = 1;
    int32 message_type = 2;
    int64 user_id = 5;
    int64 channel_id = 8;
}

message WebcastLinkMicBattle {
    bytes common = 1;
    int64 battle_id = 2;
    int32 action = 4;
}

message WebcastLinkMicArmies {
    bytes common = 1;
    int64 battle_id = 2;
    int64 channel_id = 4;
    int32 battle_status = 7;
}

message WebcastLinkMessage {
    bytes common = 1;
    int32 message_type = 2;
    int64 linker_id = 3;
    int32 scene = 4;
}

message WebcastLinkLayerMessage {
    bytes common = 1;
    int32 message_type = 2;
    int64 channel_id = 3;
    int32 scene = 4;
}

message WebcastLinkMicLayoutStateMessage {
    bytes common = 1;
    int64 room_id = 2;
    int32 layout_state = 3;
    string layout_key = 6;
}

message WebcastGiftPanelUpdateMessage {
    bytes common = 1;
    int64 room_id = 2;
    int64 panel_version = 3;
}

message WebcastInRoomBannerMessage {
    bytes common = 1;
    int32 position = 3;
    int32 action_type = 4;
}

message WebcastGuideMessage {
    bytes common = 1;
    int32 guide_type = 2;
    int64 duration_ms = 5;
    string scene = 7;
}

// ─── Extended events ────────────────────────────────────

message WebcastEmoteChatMessage {
    bytes common = 1;
    User user = 2;
    string emote_id = 3;
    Image emote_image = 4;
}

message WebcastQuestionNewMessage {
    bytes common = 1;
    string content = 2;
    User user = 3;
}

message WebcastSubNotifyMessage {
    bytes common = 1;
    User user = 2;
}

message WebcastBarrageMessage {
    bytes common = 1;
}

message WebcastHourlyRankMessage {
    bytes common = 1;
}

message WebcastMsgDetectMessage {
    bytes common = 1;
}

message WebcastLinkMicFanTicketMethod {
    bytes common = 1;
}

message WebcastRoomVerifyMessage {
    bytes common = 1;
}

message WebcastOecLiveShoppingMessage {
    bytes common = 1;
}

message WebcastGiftBroadcastMessage {
    bytes common = 1;
}

message WebcastRankTextMessage {
    bytes common = 1;
}

message WebcastGiftDynamicRestrictionMessage {
    bytes common = 1;
}

message WebcastViewerPicksUpdateMessage {
    bytes common = 1;
}

// ---- messages_ext ----

message WebcastAccessControlMessage { bytes common = 1; }
message WebcastAccessRecallMessage { bytes common = 1; }
message WebcastAlertBoxAuditResultMessage { bytes common = 1; }
message WebcastBindingGiftMessage { bytes common = 1; }
message WebcastBoostCardMessage { bytes common = 1; }
message WebcastBottomMessage { bytes common = 1; }
message WebcastGameRankNotifyMessage { bytes common = 1; }
message WebcastGiftPromptMessage { bytes common = 1; }
message WebcastLinkStateMessage { bytes common = 1; }
message WebcastLinkMicBattlePunishFinish { bytes common = 1; }
message WebcastLinkmicBattleTaskMessage { bytes common = 1; }
message WebcastMarqueeAnnouncementMessage { bytes common = 1; }
message WebcastNoticeMessage { bytes common = 1; }
message WebcastNotifyMessage { bytes common = 1; }
message WebcastPartnershipDropsUpdateMessage { bytes common = 1; }
message WebcastPartnershipGameOfflineMessage { bytes common = 1; }
message WebcastPartnershipPunishMessage { bytes common = 1; }
message WebcastPerceptionMessage { bytes common = 1; }
message WebcastSpeakerMessage { bytes common = 1; }
message WebcastSubCapsuleMessage { bytes common = 1; }
message WebcastSubPinEventMessage { bytes common = 1; }
message WebcastSubscriptionNotifyMessage { bytes common = 1; }
message WebcastToastMessage { bytes common = 1; }
message WebcastSystemMessage { bytes common = 1; }
message WebcastLiveGameIntroMessage { bytes common = 1; }

'@
