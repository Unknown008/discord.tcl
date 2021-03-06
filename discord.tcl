# discord.tcl --
#
#       This file implements the Tcl code for interacting with the Discord API.
#
# Copyright (c) 2016, Yixin Zhang
# Copyright (c) 2018-2020, Jerry Yong
#
# See the file "LICENSE" for information on usage and redistribution of this
# file.

package require Tcl 8.6
package require http
package require tls
package require json
package require logger
package require sqlite3

::http::register https 443 ::tls::socket

namespace eval discord {
    namespace export connect disconnect setCallback
    namespace ensemble create

    variable DiscordTclVersion 0.7.0
    variable DiscordApiVersion 6
    variable DiscordApiDate "11-May-2020"
    variable UserAgent [format \
        "DiscordBot (discord.tcl, %s for Discord API v%s %s)" \
        $DiscordTclVersion $DiscordApiVersion $DiscordApiDate]

    ::http::config -useragent $UserAgent

    variable ApiBaseUrl "https://discordapp.com/api"
    
    variable log [::logger::init discord]
    variable logLevels {debug info notice warn error critical alert emergency}
    ${log}::setlevel debug

    variable SessionId 0
    variable defCallbacks {
        READY                         {}
        RESUMED                       {}
        INVALID_SESSION               {}
        CHANNEL_CREATE                {}
        CHANNEL_UPDATE                {}
        CHANNEL_DELETE                {}
        CHANNEL_PINS_UPDATE           {}
        GUILD_CREATE                  {}
        GUILD_UPDATE                  {}
        GUILD_DELETE                  {}
        GUILD_BAN_ADD                 {}
        GUILD_BAN_REMOVE              {}
        GUILD_EMOJIS_UPDATE           {}
        GUILD_INTEGRATIONS_UPDATE     {}
        GUILD_MEMBER_ADD              {}
        GUILD_MEMBER_REMOVE           {}
        GUILD_MEMBER_UPDATE           {}
        GUILD_MEMBERS_CHUNK           {}
        GUILD_ROLE_CREATE             {}
        GUILD_ROLE_UPDATE             {}
        GUILD_ROLE_DELETE             {}
        INVITE_CREATE                 {}
        INVITE_DELETE                 {}
        MESSAGE_CREATE                {}
        MESSAGE_UPDATE                {}
        MESSAGE_DELETE                {}
        MESSAGE_DELETE_BULK           {}
        MESSAGE_REACTION_ADD          {}
        MESSAGE_REACTION_REMOVE       {}
        MESSAGE_REACTION_REMOVE_AL    {}
        MESSAGE_REACTION_REMOVE_EMOJI {}
        PRESENCE_UPDATE               {}
        TYPING_START                  {}
        USER_UPDATE                   {}
        VOICE_STATE_UPDATE            {}
        VOICE_SERVER_UPDATE           {}
        WEBHOOKS_UPDATE               {}
    }

    variable EventToProc {
        READY                         Ready
        RESUMED                       Resumed
        INVALID_SESSION               Log
        CHANNEL_CREATE                Channel
        CHANNEL_UPDATE                Channel
        CHANNEL_DELETE                Channel
        CHANNEL_PINS_UPDATE           Log
        GUILD_CREATE                  Guild
        GUILD_UPDATE                  Guild
        GUILD_DELETE                  Guild
        GUILD_BAN_ADD                 GuildBan
        GUILD_BAN_REMOVE              GuildBan
        GUILD_EMOJIS_UPDATE           GuildEmojisUpdate
        GUILD_INTEGRATIONS_UPDATE     GuildIntegrationsUpdate
        GUILD_MEMBER_ADD              GuildMember
        GUILD_MEMBER_REMOVE           GuildMember
        GUILD_MEMBER_UPDATE           GuildMember
        GUILD_MEMBERS_CHUNK           GuildMembersChunk
        GUILD_ROLE_CREATE             GuildRole
        GUILD_ROLE_UPDATE             GuildRole
        GUILD_ROLE_DELETE             GuildRole
        INVITE_CREATE                 Log
        INVITE_DELETE                 Log
        MESSAGE_CREATE                Message
        MESSAGE_UPDATE                Message
        MESSAGE_DELETE                Message
        MESSAGE_DELETE_BULK           MessageDeleteBulk
        MESSAGE_REACTION_ADD          Log
        MESSAGE_REACTION_REMOVE       Log
        MESSAGE_REACTION_REMOVE_ALL   Log
        MESSAGE_REACTION_REMOVE_EMOJI Log
        PRESENCE_UPDATE               PresenceUpdate
        TYPING_START                  Log
        USER_UPDATE                   UserUpdate
        VOICE_STATE_UPDATE            Voice
        VOICE_SERVER_UPDATE           Voice
        WEBHOOK_UPDATE                Log
    }
    
    variable ChannelTypes {
        0     GUILD_TEXT
        1     DM
        2     GUILD_VOICE
        3     GROUP_DM
        4     GUILD_CATEGORY
    }
}

# discord::connect --
#
#       Starts a new session. Connects to the Discord Gateway, and update
#       session details continuously by monitoring Dispatch events.
#
# Arguments:
#       token       Bot token or OAuth2 bearer token
#       cmd         (optional) list that includes a callback procedure, and any
#                   arguments to be passed to the callback. The last argument
#                   passed will be the session namespace, which can be used to
#                   register event callbacks using discord::setCallback. The
#                   callback is invoked before the Identify message is sent, but
#                   after the library sets up internal callbacks.
#       shardInfo   (optional) list with two elements, the shard ID and number
#                   of shards. Defaults to {0 1}, meaning shard ID 0 and 1 shard
#                   in total.
#
# Results:
#       Returns the name of a namespace that is created for the session if the
#       connection is sucessful, or an empty string otherwise.

proc discord::connect {token {cmd {}} {shardInfo {0 1}}} {
    variable log
    ${log}::info "Connecting to discord"
    set sessionNs [CreateSession]
    if {[catch {gateway::connect $token [list ::discord::SetupEventCallbacks \
        $cmd $sessionNs] $shardInfo} gatewayNs options]
    } {
        ${log}::error "Error connecting: $gatewayNs"
        return -options $options $gatewayNs
    }
    variable defCallbacks
    set ${sessionNs}::gatewayNs $gatewayNs
    set ${sessionNs}::token $token
    set ${sessionNs}::self [dict create]
    set ${sessionNs}::dmChannels [dict create]
    set ${sessionNs}::callbacks $defCallbacks
    return $sessionNs
}

# discord::disconnect --
#
#       Stop an existing session. Disconnect from the Discord Gateway.
#
# Arguments:
#       sessionNs   Session namespace returned from discord::connect
#
# Results:
#       Deletes the session namespace. Raises an error if the namespace does not
#       exist.

proc discord::disconnect {sessionNs} {
    variable log
    ${log}::info "Disconnecting from discord"
    if {![namespace exists $sessionNs]} {
        return -code error "Unknown session: $sessionNs"
    }

    if {[catch {gateway::disconnect [set ${sessionNs}::gatewayNs]} res]} {
        ${log}::error "Error disconnecting: $res"
    }
    DeleteSession $sessionNs
    MonitorNetwork
    return 1
}

# discord::setCallback --
#
#       Register a callback procedure for a specified Dispatch event. The
#       callback is invoked after the event is handled by the library callback;
#       it will accept three arguments, 'sessionNs', 'event' and 'data'. Refer
#       to callback.tcl for examples.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       event       Event name.
#       cmd         List that includes a callback procedure, and any
#                   arguments to be passed to the callback. Set this to the
#                   empty string to unregister a callback.
#
# Results:
#       Returns 1 if the event is supported, or 0 otherwise.

proc discord::setCallback {sessionNs event cmd} {
    variable log
    ${log}::info "Setting callback for '$event': $cmd"
    if {![dict exists [set ${sessionNs}::callbacks] $event]} {
        ${log}::error "Event not recognized: '$event'"
        return 0
    }

    dict set ${sessionNs}::callbacks $event $cmd
    return 1
}

# discord::CreateSession --
#
#       Create a namespace for a session.
#
# Arguments:
#       None.
#
# Results:
#       Creates a namespace specific to a session. Returns the namespace name.

proc discord::CreateSession { } {
    variable SessionId
    variable log
    ${log}::info "Creating session"
    set sessionNs ::discord::session::$SessionId
    incr SessionId
    namespace eval $sessionNs {}
    set ${sessionNs}::log [::logger::init $sessionNs]
    return $sessionNs
}

# discord::DeleteSession --
#
#       Delete a session namespace
#
# Arguments:
#       sessionNs   Name of fully-qualified namespace to delete.
#
# Results:
#       None.

proc discord::DeleteSession {sessionNs} {
    variable log
    ${log}::info "Deleting session"
    [set ${sessionNs}::log]::delete
    namespace delete $sessionNs
    return
}

# discord::Every --
#
#       Run a command periodically at the specified interval. Allows
#       cancellation of the command. Must be called using the full name.
#
# Arguments:
#       interval    Duration in milliseconds between each command execution.
#                   Use "cancel" to stop executing the command.
#       script      Command to run.
#
# Results:
#       Returns the return value of the 'after' command.

proc discord::Every {interval script} {
    variable EveryIds
    variable log
    ${log}::info "Executing script every $interval ms"
    if {$interval eq "cancel"} {
        catch {after cancel $EveryIds($script)}
        return
    }
    set afterId [after $interval [info level 0]]
    set EveryIds($script) $afterId
    uplevel #0 $script
    return $afterId
}

# discord::SetupEventCallbacks
#
#       Set callbacks for relevant Gateway Dispatch events. Invoked after a
#       connection to the Gateway is made, and before the Identify message is
#       sent.
#
# Arguments:
#       cmd         List that contains a callback procedure and any other
#                   arguments to be passed it to. The last argument to the
#                   callback will be the session namespace. The callback  is
#                   invoked at the end of this procedure.
#       sessionNs   Name of a session namespace.
#       sock        WebSocket object.
#
# Results:
#       None.

proc discord::SetupEventCallbacks {cmd sessionNs sock} {
    variable log
    ${log}::info "Setting up event callbacks"
    foreach event [dict keys [set ${sessionNs}::callbacks]] {
        gateway::setCallback $sock $event \
            [list ::discord::ManageEvents $sessionNs]
    }
    if {[llength $cmd] > 0} {
        {*}$cmd $sessionNs
    }
    return
}

# discord::ManageEvents --
#
#       Invokes internal library callback and user-defined callback if any.
#
# Arguments:
#       sessionNs   Name of session namespace.
#       event       Event name.
#       data        Dictionary representing a JSON object
#
# Results:
#       None.

proc discord::ManageEvents {sessionNs event data} {
    variable EventToProc
    variable log
    ${log}::info "Managing events"
    if {![catch {dict get $EventToProc $event} procName]} { 
        callback::event::$procName $sessionNs $event $data
    }
    if {
        ![catch {dict get [set ${sessionNs}::callbacks] $event} cmd] 
        && [llength $cmd] > 0
    } {
        {*}$cmd $sessionNs $event $data
    }
    return
}

package provide discord $::discord::DiscordTclVersion