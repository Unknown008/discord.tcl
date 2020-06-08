# callback.tcl --
#
#       This file implements the Tcl code for callback procedures.
#       Essentially updating the local database based on events
#
# Copyright (c) 2016, Yixin Zhang
# Copyright (c) 2018-2020, Jerry Yong
#
# See the file "LICENSE" for information on usage and redistribution of this
# file.

package require Tcl 8.6
package require sqlite3

namespace eval discord::callback::event {
    sqlite3 guild guilds.sqlite3

    guild eval {
        CREATE TABLE IF NOT EXISTS guild(
            guildId text PRIMARY KEY ON CONFLICT REPLACE,
            data text
        )
    }

    guild eval {
        CREATE TABLE IF NOT EXISTS chan(
            channelId text PRIMARY KEY ON CONFLICT REPLACE,
            guildId text
        )
    }

    guild eval {
        CREATE TABLE IF NOT EXISTS users(
            userId text PRIMARY KEY ON CONFLICT REPLACE,
            data text
        )
    }

    guild eval {DELETE FROM guild}
    guild eval {DELETE FROM chan}
    guild eval {DELETE FROM users}
}

# Shared Arguments:
#       sessionNs   Name of session namespace.
#       event       Event name.
#       data        Dictionary representing a JSON object

# discord::callback::event::Ready --
#
#       Callback procedure for Dispatch Ready event. Get our user object, list
#       of DM channels, guilds, and session_id.
#
# Results:
#       Updates variables in session namespace.

proc discord::callback::event::Ready {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Handling ready event"

    set ${sessionNs}::self [dict get $data user]
    foreach dmChannel [dict get $data private_channels] {
        dict set ${sessionNs}::dmChannels [dict get $dmChannel id] $dmChannel
    }
    set ${sessionNs}::SessionId [dict get $data session_id]

    ${log}::debug "Ready"
}

# discord::callback::event::Resumed --
#
#       Callback procedure for Dispatch event Resumed.
#
# Results:
#       Log information.

proc discord::callback::event::Resumed {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Resumed session"
}

# discord::callback::event::Log --
#
#       Callback procedure for Dispatch various events that only get logged.
#
# Results:
#       Log information.

proc discord::callback::event::Log {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "$event: $data"
}

# discord::callback::event::Channel --
#
#       Callback procedure for Dispatch Channel events Create, Update, Delete.
#
# Results:
#       Modify session channel information.

proc discord::callback::event::Channel {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Handling dispatch channel"

    set id [dict get $data id]
    set typeNames [dict create {*}$::discord::ChannelTypes]
    set type [dict get $data type]
    if {![dict exists $typeNames $type]} {
        ${log}::error "Unknown type '$type': $data"
        return
    }
    set typeName [dict get $typeNames $type]
    if {$typeName eq "DM"} {
        switch $event {
            CHANNEL_CREATE {
                dict set ${sessionNs}::dmChannels $id $data
            }
            CHANNEL_UPDATE {
                dict for {field value} $data {
                    dict set ${sessionNs}::dmChannels $id $field $value
                }
            }
            CHANNEL_DELETE {
                if {[dict exists ${sessionNs}::dmChannels $id]} {
                    dict unset ${sessionNs}::dmChannels $id
                }
            }
        }
        set users [dict get $data recipients]
        ${log}::debug "typeName: $typeName, $event"
        foreach user $users {
            set userId [dict get $user id]
            foreach field {username discriminator} {
                set $field [dict get $user $field]
            }
            ${log}::debug "user: ${username}#$discriminator ($userId)"
        }
    } else {
        set guildId [dict get $data guild_id]
        set guildData [guild eval {
            SELECT data FROM guild WHERE guildId = :guildId
        }]
        set guildData {*}$guildData
        set channels [dict get $guildData channels]
        switch $event {
            CHANNEL_CREATE {
                lappend channels $data
                dict set guildData channels $channels
                guild eval {INSERT INTO chan VALUES (:id, :guildId)}
            }
            CHANNEL_UPDATE {
                set newChannels [list]
                foreach channel $channels {
                    if {$id == [dict get $channel id]} {
                        dict for {field value} $data {
                            dict set channel $field $value
                        }
                    }
                    lappend newChannels $channel
                }
                dict set guildData channels $newChannels
            }
            CHANNEL_DELETE {
                set newChannels [list]
                foreach channel $channels {
                    if {$id == [dict get $channel id]} {
                        continue
                    }
                    lappend newChannels $channel
                }
                dict set guildData channels $newChannels
                guild eval {DELETE FROM chan WHERE channelId = :id}
            }
        }
        guild eval {
            UPDATE guild SET data = :guildData WHERE guildId = :guildId
        }
        set name [dict get $data name]
        ${log}::debug "typeName: $typeName, $event '$name' ($id)"
    }
}

# discord::callback::event::Guild --
#
#       Callback procedure for Dispatch Guild events Create, Update, Delete.
#
# Results:
#       Modify session guild information.

proc discord::callback::event::Guild {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Dispatching guild"
    set id [dict get $data id]
    switch $event {
        GUILD_CREATE {
            set existing [guild eval {SELECT 1 FROM guild WHERE guildId = :id}]
            if {$existing != ""} {
                guild eval {UPDATE guild SET data = :data WHERE guildId = :id}
            } else {
                guild eval {INSERT INTO guild VALUES (:id, :data)}
            }
            foreach channel [dict get $data channels] {
                set channelId [dict get $channel id]
                set exists [guild eval {
                    SELECT 1 FROM chan WHERE channelId = :channelId
                }]
                if {$exists != ""} {
                    guild eval {DELETE FROM chan WHERE channelId = :channelId}
                }
                guild eval {INSERT INTO chan VALUES (:channelId, :id)}
            }
            foreach member [dict get $data members] {
                set user [dict get $member user]
                set userId [dict get $user id]
                set userData [guild eval {
                    SELECT data FROM users WHERE userId = :userId
                }]
                set exists $userData
                if {$userData == ""} {
                    dict for {field value} $user {
                        dict set userData $field $value
                    }
                    if {[dict exists $member nick]} {
                        dict set userData nick $id [dict get $member nick]
                    }
                    guild eval {INSERT INTO users VALUES (:userId, :userData)}
                } else {
                    set userData {*}$userData
                    if {[dict exists $member nick]} {
                        dict set userData nick $id [dict get $member nick]
                    }
                    guild eval {
                        UPDATE users SET data = :userData WHERE userId = :userId
                    }
                }
            }
            foreach presence [dict get $data presences] {
                PresenceUpdate $sessionNs "${event}_PresenceUpdate" $presence
            }
        }
        GUILD_UPDATE {
            set guildData [guild eval {
                SELECT data FROM guild WHERE guildId = :id
            }]
            set guildData {*}$guildData
            dict for {field value} $data {
                dict set guildData $field $value
            }
            guild eval {UPDATE guild SET data = :guildData WHERE guildId = :id}
        }
        GUILD_DELETE {
            guild eval {DELETE FROM guild WHERE guildId = :id}
        }
    }

    if {[dict exists $data name]} {
        set name [dict get $data name]
        ${log}::debug "$event: '$name' ($id)"
    }
}

# discord::callback::event::GuildBan --
#
#       Callback procedure for Dispatch Guild Ban events Add, Remove.
#
# Results:
#       None.

proc discord::callback::event::GuildBan {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Dispatching guild ban"
    set user [dict get $data user]
    set guildId [dict get $data guild_id]
    switch $event {
        GUILD_BAN_ADD -
        GUILD_BAN_REMOVE {
            set guildData [guild eval {
                SELECT data FROM guild WHERE guildId = :guildId
            }]
            set guildData {*}$guildData
            set guildName [dict get $guildData name]
            foreach field {id username discriminator} {
                set $field [dict get $user $field]
            }
            set msg "$event '$guildName' ($guildId): "
            append msg "${username}#$discriminator ($id)"
            ${log}::debug $msg
        }
    }
}

# discord::callback::event::GuildEmojisUpdate --
#
#       Callback procedure for Dispatch event Guild Emojis Update.
#
# Results:
#       Modify session guild information.

proc discord::callback::event::GuildEmojisUpdate {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Updating guild emojis"
    set guildId [dict get $data guild_id]
    set guildData [guild eval {SELECT data FROM guild WHERE guildId = :guildId}]
    set guildData {*}$guildData
    set guildName [dict get $guildData name]
    dict set guildData emojis [dict get $data emojis]
    guild eval {UPDATE guild SET data = :guildData WHERE guildId = :guildId}
    ${log}::debug "$event: '$guildName' ($guildId)"
}

# discord::callback::event::GuildIntegrationsUpdate --
#
#       Callback procedure for Guild Integrations Update.
#
# Results:
#       Modify session guild information.

proc discord::callback::event::GuildIntegrationsUpdate {
    sessionNs event data
} {
    set log [set ${sessionNs}::log]
    ${log}::info "Updating guild integrations"
    set guildId [dict get $data guild_id]
    set guildData [guild eval {SELECT data FROM guild WHERE guildId = :guildId}]
    set guildData {*}$guildData
    set guildName [dict get $guildData name]
    ${log}::debug "$event: '$guildName' ($guildId)"
}

# discord::callback::event::GuildMember --
#
#       Callback procedure for Dispatch Guild Member events Add, Remove, Update.
#
# Results:
#       Modify session guild information.

proc discord::callback::event::GuildMember {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Updating guild members"
    set user [dict get $data user]
    set id [dict get $user id]
    set guildId [dict get $data guild_id]
    set guildData [guild eval {SELECT data FROM guild WHERE guildId = :guildId}]
    set guildData {*}$guildData
    set members [dict get $guildData members]
    switch $event {
        GUILD_MEMBER_ADD {
            lappend members [dict remove $data guild_id]
            dict set guildData members $members
        }
        GUILD_MEMBER_REMOVE {
            set newMembers [list]
            foreach member $members {
                if {$id != [dict get $member user id]} {
                    lappend newMembers $member
                }
            }
            dict set guildData members $newMembers
        }
        GUILD_MEMBER_UPDATE {
            set newMembers [list]
            foreach member $members {
                if {$id == [dict get $member user id]} {
                    dict for {field value} [dict remove $data guild_id] {
                        dict set member $field $value
                    }
                }
                lappend newMembers $member
            }
            dict set guildData members $newMembers
        }
    }
    guild eval {UPDATE guild SET data = :guildData WHERE guildId = :guildId}
    set guildName [dict get $guildData name]
    foreach field {username discriminator} {
        set $field [dict get $user $field]
    }
    set msg "$event: '$guildName' ($guildId): ${username}#$discriminator ($id)"
    ${log}::debug $msg
}

# discord::callback::event::GuildMembersChunk -
#
#       Callback procedure for Dispatch event Guild Members Chunk.
#
# Results:
#       Modify session guild information.

proc discord::callback::event::GuildMembersChunk {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Dispatching guild members"
    set guildId [dict get $data guild_id]
    set members [dict get $data members]
    set guildData [guild eval {SELECT data FROM guild WHERE guildId = :guildId}]
    set guildData {*}$guildData
    set guildName [dict get $guildData name]
    set msg "$event: Received [llength $members] offline members in "
    append msg "'$guildName' ($guildId)"
    ${log}::debug $msg
}

# discord::callback::event::GuildRole --
#
#       Callback procedure for Dispatch Guild Role events Create, Update,
#       Delete.
#
# Results:
#       Modify session guild information.

proc discord::callback::event::GuildRole {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Dispatching guild roles"
    set guildId [dict get $data guild_id]
    set guildData [guild eval {SELECT data FROM guild WHERE guildId = :guildId}]
    set guildData {*}$guildData
    set roles [dict get $guildData roles]
    set role {}
    switch $event {
        GUILD_ROLE_CREATE {
            set role [dict get $data role]
            lappend roles $role
            dict set guildData roles $roles
        }
        GUILD_ROLE_UPDATE {
            set role [dict get $data role]
            set id [dict get $role id]
            set newRoles [list]
            foreach r $roles {
                if {$id == [dict get $r id]} {
                    dict for {field value} $role {
                        dict set r $field $value
                    }
                }
                lappend newRoles $r
            }
            dict set guildData roles $newRoles
        }
        GUILD_ROLE_DELETE {
            set id [dict get $data role_id]
            set newRoles [list]
            foreach r $roles {
                if {$id == [dict get $r id]} {
                    set role $r
                    continue
                }
                lappend newRoles $r
            }
            dict set guildData roles $newRoles
        }
    }
    guild eval {UPDATE guild SET data = :guildData WHERE guildId = :guildId}
    foreach field {id name} {
        set $field [dict get $role $field]
    }
    set guildName [dict get $guildData name]
    ${log}::debug "$event '$guildName' ($guildId): '$name' ($id)"
}

# discord::callback::event::Message --
#
#       Callback procedure for Dispatch Message events Create, Update, Delete.
#
# Results:
#       Log message information.

proc discord::callback::event::Message {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Dispatching message"
    set id [dict get $data id]
    set channelId [dict get $data channel_id]
    switch $event {
        MESSAGE_CREATE {
            set timestamp [dict get $data timestamp]
            set author [dict get $data author]
            set username [dict get $author username]
            set discriminator [dict get $author discriminator]
            set content [dict get $data content]
            ${log}::debug "$timestamp ${username}#${discriminator}: $content"
        }
        MESSAGE_UPDATE -
        MESSAGE_DELETE {
            ${log}::debug "$event: $data"
        }
    }
}

# discord::callback::event::MessageDeleteBulk --
#
#       Callback procedure for Dispatch event Message Delete Bulk.
#
# Results:
#       Log information.

proc discord::callback::event::MessageDeleteBulk {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Dispatching message delete bulk"
    set ids [dict get $data ids]
    set channelId [dict get $data channel_id]
    ${log}::debug "$event: [llength $ids] messages deleted from $channelId."
}

# discord::callback::event::PresenceUpdate --
#
#       Callback procedure for Dispatch event Presence Update.
#
# Results:
#       Modify session user and guild information.

proc discord::callback::event::PresenceUpdate {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Updating presence"
    set user [dict get $data user]
    set userId [dict get $user id]
    set userData [lindex [guild eval {
        SELECT data FROM users WHERE userId = :userId
    }] 0]
    dict for {field value} $user {
        dict set userData $field $value
    }
    foreach field {game status} {
        catch {
            set value [dict get $data $field]
            dict set userData $field $value
        }
    }
    guild eval {UPDATE users SET data = :userData WHERE userId = :userId}
    if {[dict exists $data guild_id]} {
        set guildId [dict get $data guild_id]
        set newMembers [list]
        set guildData [guild eval {
            SELECT data FROM guild WHERE guildId = :guildId
        }]
        set guildData {*}$guildData
        set members [dict get $guildData members]
        foreach member $members {
            set memberUser [dict get $member user]
            set memberUserId [dict get $memberUser id]
            if {$memberUserId eq $userId} {
                foreach field [list roles nick] {
                    catch {
                        set value [dict get $data $field]
                        dict set member $field $value
                    }
                }
            }
            lappend newMembers $member
        }
        dict set guildData members $newMembers
        guild eval {UPDATE guild SET data = :guildData WHERE guildId = :guildId}
    }
    ${log}::debug "$event: $userId"
}

# discord::callback::event::UserUpdate --
#
#       Callback procedure for Dispatch event User Update.
#
# Results:
#       Modify session user information.

proc discord::callback::event::UserUpdate {sessionNs event data} {
    set log [set ${sessionNs}::log]
    ${log}::info "Updating user"
    set id [dict get $data id]
    set userData [guild eval {SELECT data FROM users WHERE userId = :id}]
    set userData {*}$userData
    dict for {field value} $data {
        dict set userData $field $value
    }
    guild eval {UPDATE users SET data = :userData WHERE userId = :id}
    foreach field {username discriminator} {
        set field [dict get $userData $field]
    }
    ${log}::debug "$event: ${username}#${discriminator} ($id)"
}
