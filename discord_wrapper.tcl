# discord_wrapper.tcl --
#
#       This file implements the Tcl code that wraps around the procedures in
#       the disrest_*.tcl files.
#
# Copyright (c) 2016, Yixin Zhang
# Copyright (c) 2018-2020, Jerry Yong
#
# See the file "LICENSE" for information on usage and redistribution of this
# file.

namespace eval discord {
    namespace export getChannel modifyChannel deleteChannel getMessages \
        getMessage sendMessage uploadFile editMessage deleteMessage \
        bulkDeleteMessages editChannelPermissions deleteChannelPermission \
        getChannelInvites createChannelInvite triggerTyping \
        getPinnedMessages pinMessage unpinMessage getGuild modifyGuild \
        getChannels createChannel changeChannelPositions getMember \
        getMembers addMember modifyMember modifyBotnick addGuildMemberRole \
        removeGuildMemberRole kickMember getBans ban unban getRoles \
        createRole batchModifyRoles modifyRole deleteRole getPruneCount \
        prune getGuildVoiceRegions getGuildInvites getIntegrations \
        createIntegration modifyIntegration deleteIntegration \
        syncIntegration getGuildWidget getGuildVanityUrl modifyGuildWidget \
        getAuditLog getCurrentUser getUser modifyCurrentUser getGuilds \
        leaveGuild getDMs createDM getConnections getVoiceRegions sendDM \
        closeDM createReaction deleteOwnReaction deleteReaction getReactions \
        deleteAllReactions deleteAllReactionsForEmoji

    namespace ensemble create
}

# discord::GenApiProc --
#
#       Used in place of the proc command for easier programming of API calls
#       in the discord namespace. Code for dealing with coroutine will be
#       added.
#
# Arguments:
#       _name   Name of the procedure that will be created in the discord
#               namespace.
#       _args   Arguments that the procedure will accept.
#       _body   Script to run.
#
# Results:
#       A procedure discord::$name will be created, with these additions:
#       The argument "sessionNs" is prepended to the list of args.
#       The argument "getResult" is appended to the list of args.
#       The variable "cmd" should be passed to discord::rest procedures that
#       take a callback argument.

proc discord::GenApiProc {_name _args _body} {
    set _args [list sessionNs {*}$_args {getResult 0}]
    set _setup {
        if {$getResult == 1} {
            set _caller [uplevel info coroutine]
        } else {
            set _caller {}
        }
        set cmd [list]
        set _coro {}
        if {$_caller ne {}} {
            set _myName [lindex [info level 0] 0]
            dict incr ${sessionNs}::WrapperCallCount $_myName
            set _count [dict get [set ${sessionNs}::WrapperCallCount] $_myName]
            set _coro ${_myName}$_count
            set cmd [list coroutine $_coro discord::rest::CallbackCoroutine \
                $_caller]
        }
    }
    proc ::discord::$_name $_args "$_setup\n$_body\nreturn \$_coro"
}

# Shared Arguments:
#       sessionNs   Name of session namespace.
#       getResult   (optional) boolean, set to 1 if the caller is a coroutine
#                   and will cleanup the returned result coroutine. Defaults to
#                   0, which means an empty string will be returned to the
#                   caller.

# Shared Results:
#       Returns a coroutine context name if the caller is a coroutine, and an
#       empty string otherwise. If the caller is a coroutine, it should yield
#       after calling this procedure. The caller can then get the HTTP response
#       by calling the returned coroutine. Refer to
#       discord::rest::CallbackCoroutine for more details.

# discord::getChannel --
#
#       Get a channel by ID.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getChannel {channelId} {
    rest::GetChannel [set ${sessionNs}::token] $channelId $cmd
}

# discord::modifyChannel --
#
#       Update a channel's settings.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       data        Dictionary representing a JSON object. Each key is one of
#                   name, position, topic, bitrate, user_limit. All keys are
#                   optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc modifyChannel {channelId data} {
    rest::ModifyChannel [set ${sessionNs}::token] $channelId $data $cmd
}

# discord::deleteChannel --
#
#       Delete a guild channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc deleteChannel {channelId} {
    rest::DeleteChannel [set ${sessionNs}::token] $channelId $cmd
}

# discord::getMessages --
#
#       Get the messages for a channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       data        Dictionary representing a JSON object. Each key is one of
#                   around, before, after, limit. All keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc getMessages {channelId data} {
    rest::GetChannelMessages [set ${sessionNs}::token] $channelId $data $cmd
}

# discord::getMessage --
#
#       Get a channel message by ID.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getMessage {channelId messageId} {
    rest::GetChannelMessage [set ${sessionNs}::token] $channelId $messageId $cmd
}

# discord::sendMessage --
#
#       Send a message to the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       content     Message content.
#       getResult   See "Shared Arguments".

discord::GenApiProc sendMessage {channelId content} {
    rest::CreateMessage [set ${sessionNs}::token] $channelId $content $cmd
}

# discord::uploadFile --
#
#       Upload a file to the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       filename    Name of the file.
#       type        Content-Type value.
#       file        File data.
#       getResult   See "Shared Arguments".

discord::GenApiProc uploadFile {channelId filename type file} {
    rest::UploadFile [set ${sessionNs}::token] $channelId $filename $type \
        $file $cmd
}

# discord::editMessage --
#
#       Edit a message in the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       content     New message content.
#       getResult   See "Shared Arguments".

discord::GenApiProc editMessage {channelId messageId content} {
    rest::EditMessage [set ${sessionNs}::token] $channelId $messageId \
        $content $cmd
}

# discord::deleteMessage --
#
#       Delete a message from the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc deleteMessage {channelId messageId} {
    rest::DeleteMessage [set ${sessionNs}::token] $channelId $messageId $cmd
}

# discord::bulkDeleteMessages --
#
#       Bulk delete messages from the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageIds  List of Message IDs.
#       getResult   See "Shared Arguments".

discord::GenApiProc bulkDeleteMessages {channelId messageIds} {
    rest::BulkDeleteMessages [set ${sessionNs}::token] $channelId \
        [dict create messages $messageIds] $cmd
}

# discord::editChannelPermissions --
#
#       Edit the channel's permission overwrite.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       overwriteId Overwrite ID.
#       data        Dictionary representing a JSON object. Each key is one of
#                   allow, deny, type. All keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc editChannelPermissions {channelId overwriteId data} {
    rest::EditChannelPermissions [set ${sessionNs}::token] $channelId \
        $overwriteId $data $cmd
}

# discord::deleteChannelPermission --
#
#       Delete permission overwrite for the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       overwriteId Overwrite ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc deleteChannelPermission {channelId overwriteId} {
    rest::DeleteChannelPermission [set ${sessionNs}::token] $channelId \
        $overwriteId $cmd
}

# discord::getChannelInvites --
#
#       Get a list of invites for the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getChannelInvites {channelId} {
    rest::GetChannelInvites [set ${sessionNs}::token] $channelId $cmd
}

# discord::createChannelInvite --
#
#       Create a new invite for the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       data        Dictionary representing a JSON object. Each key is one of
#                   max_age, max_uses, temporary, unique. All keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc createChannelInvite {channelId data} {
    rest::CreateChannelInvite [set ${sessionNs}::token] $channelId $data $cmd
}

# discord::triggerTyping --
#
#       Post a typing indicator to the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc triggerTyping {channelId} {
    rest::TriggerTypingIndicator [set ${sessionNs}::token] $channelId $cmd
}

# discord::getPinnedMessages --
#
#       Get all pinned messages in the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getPinnedMessages {channelId} {
    rest::GetPinnedMessages [set ${sessionNs}::token] $channelId $cmd
}

# discord::pinMessage --
#
#       Pin a message in the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc pinMessage {channelId messageId} {
    rest::AddPinnedChannelMessage [set ${sessionNs}::token] $channelId \
        $messageId $cmd
}

# discord::unpinMessage --
#
#       Unpin message in the channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc unpinMessage {channelId messageId} {
    rest::DeletePinnedChannelMessage [set ${sessionNs}::token] $channelId \
        $messageId $cmd
}

# discord::getGuild --
#
#       Get a guild by ID.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getGuild {guildId} {
    rest::GetGuild [set ${sessionNs}::token] $guildId $cmd
}

# discord::modifyGuild --
#
#       Modify a guild's settings.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       data        Dictionary representing a JSON object. Each key is one of
#                   name, region, verification_level,
#                   default_message_notifications, afk_channel_id, afk_timeout,
#                   icon, owner_id, splash. All keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc modifyGuild {guildId data} {
    rest::ModifyGuild [set ${sessionNs}::token] $guildId $data $cmd
}

# discord::getChannels --
#
#       Get a list of channels in the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getChannels {guildId} {
    rest::GetGuildChannels [set ${sessionNs}::token] $guildId $cmd
}

# discord::createChannel --
#
#       Create a new channel for the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       name        Channel name.
#       data        Dictionary representing a JSON object. Each key is one of
#                   type, bitrate, user_limit, permission_overwrites. All keys
#                   are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc createChannel {guildId name data} {
    dict set data name $name
    rest::CreateGuildChannel [set ${sessionNs}::token] $guildId $data $cmd
}

# discord::changeChannelPositions --
#
#       Change the position of the guild channels.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       data        List of sublists, each sublist contains the channel ID and
#                   the new position. All affected channels must be specified.
#       getResult   See "Shared Arguments".

discord::GenApiProc changeChannelPositions {guildId data} {
    set positions [lmap list $data {
        lassign $list channelId position
        set list [dict create id $channelId position $position]
    }]
    rest::ModifyGuildChannelPosition  [set ${sessionNs}::token] $guildId \
        $positions $cmd
}

# discord::getMember --
#
#       Get a guild member by user ID.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       userId      User ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getMember {guildId userId} {
    rest::GetGuildMember [set ${sessionNs}::token] $guildId $userId $cmd
}

# discord::getMembers --
#
#       Get a list of guild members.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       limit       (optional) maximum number of members to return. Defaults to
#                   1.
#       after       (optional) user ID. Only include members after this ID.
#                   Defaults to 0.
#       getResult   See "Shared Arguments".

discord::GenApiProc getMembers {guildId {limit 1} {after 0}} {
    rest::ListGuildMembers [set ${sessionNs}::token] $guildId \
        [dict create limit $limit after $after] $cmd
}

# discord::addMember --
#
#       Add a user to the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       userId      User ID.
#       accessToken OAuth2 access token.
#       data        Dictionary representing a JSON object. Each key is one of
#                   nick, roles, mute, deaf. All keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc addMember {guildId userId accessToken data} {
    dict set data access_token $accessToken
    rest::AddGuildMember [set ${sessionNs}::token] $guildId $userId $data $cmd
}

# discord::modifyMember --
#
#       Modify attributes of a guild member.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       userId      User ID.
#       data        Dictionary representing a JSON object. Each key is one of
#                   nick, roles, mute, deaf, channel_id. All keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc modifyMember {guildId userId data} {
    rest::ModifyGuildMember [set ${sessionNs}::token] $guildId $userId $data \
        $cmd
}

# discord::modifyBotnick --
#
#       Modify current user's nickname.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       data        Dictionary representing a JSON object. The key must be
#                   nick
#       getResult   See "Shared Arguments".

discord::GenApiProc modifyBotnick {guildId data} {
    rest::ModifyCurrentUserNick [set ${sessionNs}::token] $guildId $data $cmd
}

# discord::addGuildMemberRole --
#
#       Add a role to a guild member.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       userId      User ID.
#       roleId      Role ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc addGuildMemberRole {guildId userId roleId} {
    rest::AddGuildMemberRole [set ${sessionNs}::token] $guildId $userId \
        $roleId $cmd
}

# discord::removeGuildMemberRole --
#
#       Remove a role to a guild member.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       userId      User ID.
#       roleId      Role ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc removeGuildMemberRole {guildId userId data} {
    rest::RemoveGuildMemberRole [set ${sessionNs}::token] $guildId $userId \
        $roleId $cmd
}

# discord::kickMember --
#
#       Remove a member from the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       userId      User ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc kickMember {guildId userId} {
    rest::RemoveGuildMember [set ${sessionNs}::token] $guildId $userId $cmd
}

# discord::getBans --
#
#       Get a list of users that are banned from the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getBans {guildId} {
    rest::GetGuildBans [set ${sessionNs}::token] $guildId $cmd
}

# discord::ban --
#
#       Create a guild ban.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       userId      User ID.
#       delMsgDays  Number of days to delete messages for.
#       getResult   See "Shared Arguments".

discord::GenApiProc ban {guildId userId {delMsgDays 0}} {
    rest::CreateGuildBan [set ${sessionNs}::token] $guildId $userId \
        [dict create delete-message-days $delMsgDays] $cmd
}

# discord::unban --
#
#       Remove the ban for a user.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       userId      User ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc unban {guildId userId} {
    rest::RemoveGuildBan [set ${sessionNs}::token] $guildId $userId $cmd
}

# discord::getRoles --
#
#       Get a list of roles for the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getRoles {guildId} {
    rest::GetGuildRoles [set ${sessionNs}::token] $guildId $cmd
}

# discord::createRole --
#
#      Create a new empty role for the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc createRole {guildId} {
    rest::CreateGuildRole [set ${sessionNs}::token] $guildId $cmd
}

# discord::batchModifyRoles --
#
#      Batch modify a set of guild roles.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       data        List of dictionaries representing JSON objects. Each key is
#                   one of id, name, permissions, position, color, hoist,
#                   mentionable. All keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc batchModifyRoles {guildId data} {
    rest::BatchModifyGuildRole [set ${sessionNs}::token] $guildId $data $cmd
}

# discord::modifyRole --
#
#      Modify a guild role.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       roleId      Role ID.
#       data        Dictionary representing a JSON object. Each key is one of
#                   name, permissions, position, color, hoist, mentionable. All
#                   keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc modifyRole {guildId roleId data} {
    rest::ModifyGuildRole [set ${sessionNs}::token] $guildId $roleId \
        $data $cmd
}

# discord::deleteRole --
#
#      Delete a guild role.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       roleId      Role ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc deleteRole {guildId roleId} {
    rest::DeleteGuildRole [set ${sessionNs}::token] $guildId $roleId $cmd
}

# discord::getPruneCount --
#
#      Get the number of members that would be removed in a prune operation.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       days        (optional) number of days to count prune for. Defauls to 1.
#       getResult   See "Shared Arguments".

discord::GenApiProc getPruneCount {guildId {days 1}} {
    rest::GetGuildPruneCount [set ${sessionNs}::token] $guildId \
        [dict create days $days] $cmd
}

# discord::prune --
#
#      Begin a prune operation.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       days        (optional) number of days to count prune for. Defauls to 1.
#       getResult   See "Shared Arguments".

discord::GenApiProc prune {guildId {days 1}} {
    rest::BeginGuildPrune [set ${sessionNs}::token] $guildId \
        [dict create days $days] $cmd
}

# discord::getGuildVoiceRegions --
#
#      Get a list of voice regions for the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getGuildVoiceRegions {guildId} {
    rest::GetGuildVoiceRegions [set ${sessionNs}::token] $guildId $cmd
}

# discord::getGuildInvites --
#
#      Get a list of invites for the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getGuildInvites {guildId} {
    rest::GetGuildInvites [set ${sessionNs}::token] $guildId $cmd
}

# discord::getIntegrations --
#
#      Get a list of integrations for the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getIntegrations {guildId} {
    rest::GetGuildIntegrations [set ${sessionNs}::token] $guildId $cmd
}

# discord::createIntegration --
#
#      Attach an integration from the current user to the guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       data        Dictionary representing a JSON object. Each key is one of
#                   type, id.
#       getResult   See "Shared Arguments".

discord::GenApiProc createIntegration {guildId data} {
    rest::CreateGuildIntegration [set ${sessionNs}::token] $guildId $data $cmd
}

# discord::modifyIntegration --
#
#      Modify the behaviour and settings of an integration for the guild.
#
# Arguments:
#       sessionNs       Name of session namespace.
#       guildId         Guild ID.
#       integrationId   Integration ID.
#       data            Dictionary representing a JSON object. Each key is one
#                       of expire_behavior, expire_grace_period,
#                       enable_emoticons.
#       getResult       See "Shared Arguments".

discord::GenApiProc modifyIntegration {guildId integrationId data} {
    rest::ModifyGuildIntegration [set ${sessionNs}::token] $guildId \
        $integrationId $data $cmd
}

# discord::deleteIntegration --
#
#      Delete the attached integration for the guild.
#
# Arguments:
#       sessionNs       Name of session namespace.
#       guildId         Guild ID.
#       integrationId   Integration ID.
#       getResult       See "Shared Arguments".

discord::GenApiProc deleteIntegration {guildId integrationId} {
    rest::DeleteGuildIntegration [set ${sessionNs}::token] $guildId \
        $integrationId $cmd
}

# discord::syncIntegration --
#
#      Sync an integration for the guild.
#
# Arguments:
#       sessionNs       Name of session namespace.
#       guildId         Guild ID.
#       integrationId   Integration ID.
#       getResult       See "Shared Arguments".

discord::GenApiProc syncIntegration {guildId integrationId} {
    rest::SyncGuildIntegration [set ${sessionNs}::token] $guildId \
        $integrationId $cmd
}

# discord::getGuildWidget --
#
#      Get the guild widget.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getGuildWidget {guildId} {
    rest::GetGuildWidget [set ${sessionNs}::token] $guildId $cmd
}

# discord::getGuildVanityUrl --
#
#      Get the guild vanity URL.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc getGuildVanityUrl {guildId} {
    rest::GetGuildVanityUrl [set ${sessionNs}::token] $guildId $cmd
}

# discord::modifyGuildWidget --
#
#      Modify the guild widget.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       data        Dictionary representing a guild widget JSON object. Each key
#                   if one of enabled, channel_id. All keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc modifyGuildWidget {guildId data} {
    rest::ModifyGuildWidget [set ${sessionNs}::token] $guildId $data $cmd
}

# discord::getAuditLog --
#
#       Get the audit log entry.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       data        Additional queries
#       getResult   See "Shared Arguments".

discord::GenApiProc getAuditLog {guildId {data {}}} {
    rest::GetGuildAuditLog [set ${sessionNs}::token] $guildId $data $cmd
}

# discord::getCurrentUser --
#
#       Get the user of the requstor's account.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       getResult   See "Shared Arguments".

discord::GenApiProc getCurrentUser {} {
    rest::GetCurrentUser [set ${sessionNs}::token] $cmd
}

# discord::getUser --
#
#       Get a user by ID.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       userId      (optional) user ID. Defaults to @me.
#       getResult   See "Shared Arguments".

discord::GenApiProc getUser {{userId @me}} {
    rest::GetUser [set ${sessionNs}::token] $userId $cmd
}

# discord::modifyCurrentUser --
#
#       Modify the requestor's user account settings.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       data        Dictionary representing a JSON object. Each key is one of
#                   username, avator. All keys are optional.
#       getResult   See "Shared Arguments".

discord::GenApiProc modifyCurrentUser {data} {
    rest::ModifyCurrentUser [set ${sessionNs}::token] $data $cmd
}

# discord::getGuilds --
#
#       Get a list of user guilds the current user is a member of.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       getResult   See "Shared Arguments".

discord::GenApiProc getGuilds {} {
    rest::GetCurrentUserGuilds [set ${sessionNs}::token] $cmd
}

# discord::leaveGuild --
#
#       Leave a guild.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       guildId     Guild ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc leaveGuild {guildId} {
    rest::LeaveGuild [set ${sessionNs}::token] $guildId $cmd
}

# discord::getDMs --
#
#       Get a list of DM channels.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       getResult   See "Shared Arguments".

discord::GenApiProc getDMs {} {
    rest::GetUserDMs [set ${sessionNs}::token] $cmd
}

# discord::createDM --
#
#       Start a new DM with a user.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       userId      userId
#       getResult   See "Shared Arguments".

discord::GenApiProc createDM {userId} {
    rest::CreateDM [set ${sessionNs}::token] \
        [dict create recipient_id $userId] $cmd
}

# discord::getConnections --
#
#       Get a list of connections.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       getResult   See "Shared Arguments".

discord::GenApiProc getConnections {} {
    rest::GetUsersConnections [set ${sessionNs}::token] $cmd
}

# discord::getVoiceRegions --
#
#      Get a list of voice regions that can be used when creating servers.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       getResult   See "Shared Arguments".

discord::GenApiProc getVoiceRegions {} {
    rest::ListVoiceRegions [set ${sessionNs}::token] $cmd
}

# discord::sendDM --
#
#       Send a DM to the user.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       content     Message content.
#       getResult   See "Shared Arguments".
#
# Results:
#       See "Shared Results". Also raises an exception if a DM channel is not
#       opened for the user.

discord::GenApiProc sendDM {channelId content} {    
    rest::CreateMessage [set ${sessionNs}::token] $channelId $content $cmd
}

# discord::closeDM --
#
#       Close a DM channel.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc closeDM {channelId} {
    rest::DeleteChannel [set ${sessionNs}::token] $channelId $cmd
}

# discord::createReaction --
#
#       Adds a reaction to a message.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       emoji       The emoji to add.
#       getResult   See "Shared Arguments".

discord::GenApiProc createReaction {channelId messageId emoji} {
    rest::CreateReaction [set ${sessionNs}::token] $channelId $messageId \
        $emoji $cmd
}

# discord::deleteOwnReaction --
#
#       Deletes own reaction to a message
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       emoji       The emoji to add.
#       getResult   See "Shared Arguments".

discord::GenApiProc deleteOwnReaction {channelId messageId emoji} {
    rest::DeleteOwnReaction [set ${sessionNs}::token] $channelId $messageId \
        $emoji $cmd
}

# discord::deleteReaction --
#
#       Deletes a reaction to a message (Requires MANAGE_MESSAGES permission)
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       emoji       The emoji to add.
#       userId      The user ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc deleteReaction {channelId messageId emoji userId} {
    rest::DeleteReaction [set ${sessionNs}::token] $channelId $messageId \
        $emoji $userId $cmd
}

# discord::getReactions --
#
#       Gets the users who added the emoji to a certain message
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       emoji       The emoji to add.
#       getResult   See "Shared Arguments".

discord::GenApiProc getReactions {channelId messageId emoji} {
    rest::GetReactions [set ${sessionNs}::token] $channelId $messageId \
        $emoji $cmd
}

# discord::deleteAllReactions --
#
#       Deletes all reactions on a message (requires MANAGE_MESSAGES permission)
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       getResult   See "Shared Arguments".

discord::GenApiProc deleteAllReactions {channelId messageId} {
    rest::DeleteAllReactions [set ${sessionNs}::token] $channelId $messageId \
        $cmd
}

# discord::deleteAllReactionsForEmoji --
#
#       Deletes all reactions on a message (requires MANAGE_MESSAGES permission)
#       for a certain emoji
#
# Arguments:
#       sessionNs   Name of session namespace.
#       channelId   Channel ID.
#       messageId   Message ID.
#       emoji       The emoji.
#       getResult   See "Shared Arguments".

discord::GenApiProc deleteAllReactionsForEmoji {channelId messageId emoji} {
    rest::DeleteAllReactionsForEmoji [set ${sessionNs}::token] $channelId \
        $messageId $emoji $cmd
}