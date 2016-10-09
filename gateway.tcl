# gateway.tcl --
#
#       This file implements the Tcl code for interacting with the Discord
#       Gateway.
#
# Copyright (c) 2016, Yixin Zhang
#
# See the file "LICENSE" for information on usage and redistribution of this
# file.

package require Tcl 8.5
package require http
package require tls
package require websocket
package require rest
package require json::write
package require logger

::http::register https 443 ::tls::socket

namespace eval discord::gateway {
    namespace export connect disconnect logWsMsg
    namespace ensemble create

    set LogWsMsg 0
    set MsgLogLevel debug

# Compression only used for Dispatch "READY" event. Set CompressEnabled to 1 if
# you are able to get mkZiplib onto your system.

    set CompressEnabled 0
    if $CompressEnabled {
        package require mkZiplib
        set DefCompress true
    } else {
        set DefCompress false
    }

    set log [logger::init discord::gateway]
    ${log}::setlevel debug

    set DefHeartbeatInterval 10000
    set Sockets [dict create]

    set OpTokens {
        0   DISPATCH
        1   HEARTBEAT
        2   IDENTIFY
        3   STATUS_UPDATE
        4   VOICE_STATE_UPDATE
        5   VOICE_SERVER_PING
        6   RESUME
        7   RECONNECT
        8   REQUEST_GUILD_MEMBERS
        9   INVALID_SESSION
        10  HELLO
        11  HEARTBEAT_ACK
    }
    set ProcOps {
        Heartbeat   1
        Identify    2
        Resume      6
    }

}

# discord::gateway::connect --
#
#       Establish a WebSocket connection to the Gateway.
#
# Arguments:
#       token   Bot token or OAuth2 bearer token.
#
# Results:
#       Returns the connection's WebSocket object.

proc discord::gateway::connect { token } {
    variable log
    variable DefHeartbeatInterval
    variable DefCompress
    set gateway [discord::GetGateway]
    ${log}::notice "Connecting to the Gateway: '$gateway'"

    set sock [websocket::open $gateway ::discord::gateway::Handler]
    SetConnectionInfo $sock s null
    SetConnectionInfo $sock token $token
    SetConnectionInfo $sock session_id null
    SetConnectionInfo $sock heartbeat_interval $DefHeartbeatInterval
    SetConnectionInfo $sock compress $DefCompress
    return $sock
}

# discord::gateway::disconnect --
#
#       Disconnect from the Gateway.
#
# Arguments:
#       sock    WebSocket object.
#
# Results:
#       None.

proc discord::gateway::disconnect { sock } {
    ${::discord::gateway::log}::notice "Disconnecting from the Gateway."

# Manually construct the Close frame body, as the websocket library's close
# procedure does not actually send anything as of version 1.4.

	set msg [binary format Su 1000]
	set msg [string range $msg 0 124];
	websocket::send $sock 8 $msg
    return
}

# discord::gateway::logWsMsg --
#
#       Toggle logging of sent and received WebSocket text messages.
#
# Arguments:
#       on      Disable printing when set to 0, enabled otherwise.
#       level   (optional) Logging level to print messages to. Levels are
#               debug, info, notice, warn, error, critical, alert, emergency.
#               Defaults to debug.
#
# Results:
#       Returns 1 if changes were made, 0 otherwise.

proc discord::gateway::logWsMsg { on {level "debug"} } {
    variable LogWsMsg
    variable MsgLogLevel
    if {$level ni {debug info notice warn error critical alert emergency}} {
        return 0
    }
    if {$on == 0} {
        set LogWsMsg 0
    } else {
        set LogWsMsg 1
    }
    set MsgLogLevel $level
    return 1
}

# discord::gateway::Every --
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

proc discord::gateway::Every {interval script} {
    variable log
    variable EveryIds
    ${log}::debug [info level 0]
    if {$interval eq "cancel"} {
        catch {after cancel $EveryIds($script)}
        return
    }
    set afterId [after $interval [info level 0]]
    set EveryIds($script) $afterId
    uplevel #0 $script
    return $afterId
}

# discord::gateway::GetConnectionInfo --
#
#       Get a detail of the Gateway connection.
#
# Arguments:
#       sock    WebSocket object.
#       what    Name of the connection detail to return.
#
# Results:
#       Returns the connection detail.

proc discord::gateway::GetConnectionInfo { sock what } {
    return [dict get $::discord::gateway::Sockets $sock connInfo $what]
}

# discord::gateway::SetConnectionInfo --
#
#       Set a detail of the Gateway connection.
#
# Arguments:
#       sock    WebSocket object.
#       what    Name of the connection detail to set.
#       value   Value to set the connection detail to.
#
# Results:
#       Returns a string of the connection detail.

proc discord::gateway::SetConnectionInfo { sock what value } {
    return [dict set ::discord::gateway::Sockets $sock connInfo $what $value]
}

# discord::gateway::CheckOp --
#
#       Check if an opcode value is supported.
#
# Arguments:
#       op  A JSON integer.
#
# Results:
#       Returns 1 if the opcode is valid, and 0 otherwise.

proc discord::gateway::CheckOp { op } {
    variable log
    variable OpTokens
    if ![dict exists $OpTokens $op] {
        ${log}::error "op not supported: '$op'"
        return 0
    } else {
        return 1
    }
}

# discord::gateway::EventHandler --
#
#       Handle events from Gateway Dispatch messages.
#
# Arguments:
#       sock    WebSocket object.
#       msg     The message as a dictionary that represents a JSON object.
#
# Results:
#       Returns 1 if the event is handled successfully, and 0 otherwise.

proc discord::gateway::EventHandler { sock msg } {
    variable log
    set t [dict get $msg t]
    set s [dict get $msg s]
    set d [dict get $msg d]
    SetConnectionInfo $sock seq $s
    ${log}::debug "EventHandler: sock: '$sock' t: '$t' seq: $s"
    switch -glob -- $t {
        READY {
            foreach field [dict keys $d] {
                switch $field {
                    default {
                        SetConnectionInfo $sock $field [dict get $d $field]
                    }
                }
            }

            set interval [GetConnectionInfo $sock heartbeat_interval]
            ${log}::debug "EventHandler: Sending heartbeat every $interval ms"
            ::discord::gateway::Every $interval \
                    [list ::discord::gateway::Send $sock Heartbeat]
        }
        RESUME {    ;# Not much to do here
            if {[dict exists $d _trace]} {
                SetConnectionInfo $sock _trace [dict get $d _trace]
            }
        }
        default {
            ${log}::warn "EventHandler: Event not implemented: $t"
            return 0
        }
    }
    return 1
}

# discord::gateway::OpHandler --
#
#       Handles Gateway messages that contain an opcode.
#
# Arguments:
#       sock    WebSocket object.
#       msg     The message as a dictionary that represents a JSON object.
#
# Results:
#       Returns 1 if the message is handled successfully, and 0 otherwise.

proc discord::gateway::OpHandler { sock msg } {
    set op [dict get $msg op]
    if ![CheckOp $op] {
        return 0
    }

    variable log
    variable OpTokens
    set opToken [dict get $OpTokens $op]
    ${log}::debug "OpHandler: op: $op ($opToken)"

    switch -glob -- $opToken {
        DISPATCH {
            after idle [list discord::gateway::EventHandler $sock $msg]
        }
        RECONNECT {
            after idle [list discord::gateway::Send $sock Resume]
        }
        INVALID_SESSION {
            after idle [list discord::gateway::Send $sock Identify]
        }
        HELLO {
            SetConnectionInfo $sock heartbeat_interval \
                    [dict get $msg heartbeat_interval]
        }
        HEARTBEAT_ACK {
            ${log}::debug "OpHandler: Heartbeat ACK received"
        }
        default {
            ${log}::warn "OpHandler: op not implemented: ($opToken)"
            return 0
        }
    }
    return 1
}

# discord::gateway::TextHandler --
#
#       Handles all WebSocket text messages.
#
# Arguments:
#       sock    WebSocket object.
#       msg     The message as a JSON string.
#
# Results:
#       Returns 1 if the message is handled successfully, and 0 otherwise.

proc discord::gateway::TextHandler { sock msg } {
    variable log
    variable LogWsMsg
    variable MsgLogLevel
    if {$LogWsMsg} {
        ${log}::${MsgLogLevel} "TextHandler: $msg"
    }
    if {[catch {rest::format_json $msg} res]} {
        ${log}::error "TextHandler: $res"
        return 0
    }
    if {[dict exists $res op]} {
        after idle [list ::discord::gateway::OpHandler $sock $res]
        return 1
    } else {
        ${log}::warn "TextHandler: no op: $msg"
        return 0
    }
}

# discord::gateway::Handler --
#
#       Callback procedure invoked when a WebSocket message is received.
#
# Arguments:
#       sock    WebSocket object.
#       msg     The message as a dictionary that represents a JSON object.
#
# Results:
#       Returns 1 if the message is handled successfully, and 0 otherwise.

proc discord::gateway::Handler { sock type msg } {
    variable log
    variable Sockets
    ${log}::debug "Handler: type: $type"
    switch -glob -- $type {
        text {
            after idle [list ::discord::gateway::TextHandler $sock $msg]
        }
        binary {
            if {![catch {::inflate $msg} res]} {
                after idle [list ::discord::gateway::TextHandler $sock $res]
            } else {
                set bytes [string length $res]
                ${log}::warn "Handler: $bytes bytes of binary data."
            }
        }
        connect {
            after idle [list ::discord::gateway::Send $sock Identify]
        }
        close {
            ::discord::gateway::Every cancel \
                    [list ::discord::gateway::Send $sock Heartbeat]
            ${log}::notice "Handler: Connection closed."
        }
        disconnect {
            dict unset Sockets $sock
            ${log}::notice "Handler: Disconnect."
        }
        ping {      ;# Not sure if Discord uses this.
            ${log}::notice "Handler: ping: $msg"
        }
        default {
            ${log}::warn "Handler: type not implemented: '$type'"
            return 0
        }
    }
    ${log}::debug "Exit Handler"
    return 1
}

# discord::gateway::Send --
#
#       Send WebSocket messages to the Gateway.
#
# Arguments:
#       sock    WebSocket object.
#       opProc  Suffix of the Make* procedure that returns the message data.
#
# Results:
#       Returns 1 if the message is sent successfully, and 0 otherwise.

proc discord::gateway::Send { sock opProc } {
    variable log
    variable ProcOps
    variable LogWsMsg
    variable MsgLogLevel
    if {![dict exists $ProcOps $opProc]} {
        ${log}::error "Invalid procedure suffix: '$opProc'"
        return 0
    }
    set op [dict get $ProcOps $opProc]
    set data [Make${opProc} $sock]
    set msg [json::write::object op $op d $data]
    if {$LogWsMsg} {
        ${log}::${MsgLogLevel} "Send: $msg"
    }
    if [catch {websocket::send $sock text $msg} res] {
        ${log}::error "websocket::send: $res"
        return 0
    }

    return 1
}

# discord::gateway::MakeHeartbeat --
#
#       Create a message to tell the Gateway that you are alive. Do this
#       periodically.
#
# Arguments:
#       sock    WebSocket object.
#
# Results:
#       Returns the last sequence number received.

proc discord::gateway::MakeHeartbeat { sock } {
    return [GetConnectionInfo $sock seq]
}

# discord::gateway::MakeIdentify --
#
#       Create a message to identify yourself to the Gateway.
#
# Arguments:
#       sock    WebSocket object.
#       args    List of options and their values to set in the message. Prepend
#               options with a '-'. Accepted options are: os, browser, device,
#               referrer, referring_domain, compress, large_threshold, shard.
#               Example: -os linux
#
# Results:
#       Returns a JSON object containing the required information.

proc discord::gateway::MakeIdentify { sock args } {
    variable log
    set token               [json::write::string \
                                    [GetConnectionInfo $sock token]]
    set os                  [json::write::string linux]
    set browser             [json::write::string "discord.tcl 0.1"]
    set device              [json::write::string "discord.tcl 0.1"]
    set referrer            [json::write::string ""]
    set referring_domain    [json::write::string ""]
    set compress            [GetConnectionInfo $sock compress]
    set large_threshold     50
    set shard               [json::write::array 0 1]
    foreach { option value } $args {
        if {[string index $option 0] ne -} {
            continue
        }
        set opt [string range $option 1 end]
        if {$opt ni {os browser device referrer referring_domain compress
                      large_threshold shard}} {
            ${log}::error "Invalid option: '$opt'"
            continue
        }
        switch -glob -- $opt {
            compress {
                if {$value ni {true false}} {
                    ${log}::error \
                            "MakeIdentify: compress: Invalid value: '$value'"
                    continue
                }
            }
            large_threshold {
                if {![string is integer -strict $value] \
                            || $value < 50 || $value > 250} {
                    ${log}::error \
                        "MakeIdentify: large_threshold: Invalid value: '$value'"
                }
            }
        }
        set $opt $value
    }
    return [json::write::object \
            token $token \
            properties [json::write::object \
                {$os} $os \
                {$browser} $browser \
                {$device} $device \
                {$referrer} $referrer \
                {$referring_domain} $referring_domain] \
            compress $compress \
            large_threshold $large_threshold \
            shard $shard]
}

# discord::gateway::MakeResume --
#
#       Create a message to resume a connection after you are disconnected from 
#       the Gateway.
#
# Arguments:
#       sock    WebSocket object.
#
# Results:
#       Returns a JSON object containing the required information.

proc discord::gateway::MakeResume { sock } {
    return [json::write::object \
            token [GetConnectionInfo $sock token] \
            session_id [GetConnectionInfo $sock session_id] \
            seq [GetConnectionInfo $sock seq]]
}
