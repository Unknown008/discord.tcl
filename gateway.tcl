# gateway.tcl --
#
#       This file implements the Tcl code for interacting with the Discord
#       Gateway.
#
# Copyright (c) 2016, Yixin Zhang
# Copyright (c) 2018-2020, Jerry Yong
#
# See the file "LICENSE" for information on usage and redistribution of this
# file.

package require Tcl 8.6
package require http
package require tls
package require websocket
package require json
package require json::write
package require logger
package require zlib

::http::register https 443 ::tls::socket

namespace eval discord::gateway {
    namespace export connect disconnect setCallback setDefaultCallback logWsMsg
    namespace ensemble create

    variable log [::logger::init discord::gateway]
    ${log}::setlevel debug
    
    variable GatewayCloseEventCode 0

    variable LogWsMsg 0
    variable MsgLogLevel debug

    variable GatewayApiEncoding json
    variable GatewayResource /gateway
    variable CachedGatewayUrls [dict create]

    variable LimitPeriod 60
    variable LimitSend 120
    variable LimitStatusChange 5

    variable GatewayId 0
    variable Gateways [dict create]
    variable HandlerReExcute ""

    variable EventCallbacks $::discord::defCallbacks

    # Compression only used for Dispatch "READY" event. Set DefCompress to true
    # before connecting. zlib inflate doesn't work right now.

    variable DefCompress false

    variable DefHeartbeatInterval 10000

    variable OpTokens {
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

    variable ProcOps {
        Heartbeat   1
        Identify    2
        Resume      6
    }

    variable GatewayCloseEventCodes {
        4000    {Unknown error}
        4001    {Unknown opcode}
        4002    {Decode error}
        4003    {Not authenticated}
        4004    {Authentication failed}
        4005    {Already authenticated}
        4007    {Invalid seq}
        4008    {Rate limited}
        4009    {Session timed out}
        4010    {Invalid shard}
        4011    {Sharding required}
        4012    {Invalid API version}
        4013    {Invalid intent(s)}
        4014    {Disallowed intent(s)}
    }

    variable RpcCloseEventCodes {
        4000	{Invalid client ID}
        4001	{Invalid origin}
        4002	{Rate limited}
        4003	{Token revoked}
        4004	{Invalid version}
        4005	{Invalid encoding}
    }
}

# discord::gateway::connect --
#
#       Establish a WebSocket connection to the Gateway.
#
# Arguments:
#       token       Bot token or OAuth2 bearer token.
#       cmd         (optional) list that includes a callback procedure, and any
#                   arguments to be passed to the callback. The last argument
#                   passed will be a WebSocket object, which can be used to
#                   register Dispatch event callbacks using
#                   discord::gateway::setCallbacks. The callback is invoked
#                   before the Identify message is sent.
#       shardInfo   (optional) list with two elements, the shard ID and number
#                   of shards. Defaults to {0 1}, meaning shard ID 0 and 1 shard
#                   in total.
#
# Results:
#       Returns the name of a namespace that is created for the session if the
#       connection is successful. An error will be raised if retrieving the
#       Gateway API URL failed, or connecting to the WebSocket server failed.

proc discord::gateway::connect {token {cmd {}} {shardInfo {0 1}}} {
    variable log
    ${log}::info "Connecting to gateway"
    if {[catch {GetGateway $::discord::ApiBaseUrl} gateway options]} {
        ${log}::error "$gateway"
        return -options $options $gateway
    }
    variable GatewayApiEncoding
    append gateway "/?v=${::discord::DiscordApiVersion}&"
    append gateway "encoding=$GatewayApiEncoding"
    ${log}::notice $gateway

    # There might be a race condition where the Gateways dictionary doesn't get
    # initialized with the new socket before Handler gets called.
    if {
        [catch {::websocket::open $gateway ::discord::gateway::Handler} \
            sock options]
    } {
        ${log}::error "Error opening websocket on $gateway: $sock"
        return -options $options $sock
    }
    variable Gateways
    variable DefHeartbeatInterval
    variable DefCompress
    variable EventCallbacks
    variable HandlerReExcute
    set gatewayNs [CreateGateway]
    dict set Gateways $sock $gatewayNs
    set ${gatewayNs}::sock $sock
    set ${gatewayNs}::defEventCallback ::discord::gateway::EventCallbackStub
    set ${gatewayNs}::sendCount 0
    set ${gatewayNs}::seq null
    set ${gatewayNs}::session_id null
    set ${gatewayNs}::connectCallback $cmd
    set ${gatewayNs}::eventCallbacks [dict get $EventCallbacks]
    set ${gatewayNs}::shard $shardInfo
    set ${gatewayNs}::token $token
    set ${gatewayNs}::heartbeat_interval $DefHeartbeatInterval
    set ${gatewayNs}::compress $DefCompress

    # Handling race condition
    if {$HandlerReExcute != ""} {
        ${log}::warn "Running rexecution."
        uplevel #0 $HandlerReExcute
        set HandlerReExcute ""
    }

    return $gatewayNs
}

# discord::gateway::disconnect --
#
#       Disconnect from the Gateway.
#
# Arguments:
#       gatewayNs   Gateway namespace returned from discord::gateway::connect.
#
# Results:
#       Deletes the gateway namespace. Returns 1 if gatewayNs is valid, or 0
#       otherwise.

proc discord::gateway::disconnect {gatewayNs} {
    variable log
    ${log}::info "Disconnecting from the gateway"
    if {![namespace exists $gatewayNs]} {
        return -code error "Unknown gateway: $gatewayNs"
    }
    # Manually construct the Close frame body, as the websocket library's close
    # procedure does not actually send anything as of version 1.4.

    set msg [binary format Su 1000]
    set msg [string range $msg 0 124];
    ::websocket::send [set ${gatewayNs}::sock] 8 $msg
    return
}

# discord::gateway::setCallback --
#
#       Register a callback procedure for a specified Dispatch event. The
#       callback is invoked after the event is handled by EventHandler; it
#       will accept two required arguments, 'event' and 'data', and an optional
#       argument 'cmd'. Refer to discord::gateway::EventCallbackStub for an
#       example.
#
# Arguments:
#       sock    WebSocket object.
#       event   Event name.
#       cmd     (optional) list that includes a callback procedure, and any
#               arguments to be passed to the callback. The last two arguments
#               passed will be the event name, and a dictionary representing a
#               JSON object. The callback is invoked at the end of EventHandler.
#               Set this to the empty string to unregister a callback.
#
# Results:
#       Returns 1 if the event is supported, or 0 otherwise.

proc discord::gateway::setCallback {sock event cmd} {
    variable log
    ${log}::info "Registering callback for event '$event': $cmd"
    set eventCallbacks [GetGatewayInfo $sock eventCallbacks]
    if {![dict exists $eventCallbacks $event]} {
        ${log}::error "Event not recognized: '$event'"
        return 0
    }

    dict set eventCallbacks $event $cmd
    SetGatewayInfo $sock eventCallbacks $eventCallbacks
    return 1
}

# discord::gateway::setDefaultCallback --
#
#       Register a default callback procedure for Dispatch events. The
#       callback is invoked after the event is handled by EventHandler; it
#       will accept two required arguments, 'event' and 'data', and an optional
#       argument 'cmd'. Refer to discord::gateway::EventCallbackStub for an
#       example.
#
# Arguments:
#       sock    WebSocket object.
#       cmd     (optional) list that includes a callback procedure, and any
#               arguments to be passed to the callback. The last two arguments
#               passed will be the event name, and a dictionary representing a
#               JSON object. The callback is invoked at the end of EventHandler.
#               Set this to the empty string to unregister a callback.
#
# Results:
#       Returns 1 if the event is supported, or 0 otherwise.

proc discord::gateway::setDefaultCallback {sock cmd} {
    variable log
    ${log}::info "Setting default callback: $cmd"
    SetGatewayInfo $sock defEventCallback $cmd
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
#       Returns 1 if changes were made, or 0 otherwise.

proc discord::gateway::logWsMsg {on {level "debug"}} {
    variable LogWsMsg
    variable MsgLogLevel
    variable log
    ${log}::info "Setting log level of websocket"
    if {$level ni $::discord::logLevels} {
        return 0
    }
    set LogWsMsg [expr {!!$on}]
    set MsgLogLevel $level
    return 1
}

# discord::gateway::GetGateway --
#
#       Retrieve the WebSocket Secure (wss) URL for the Discord Gateway API.
#
# Arguments:
#       baseUrl Base URL for Discord API.
#       cached  If true, return a cached URL value if available, or else send a
#               new request to retrieve one. Defaults to true.
#       args    Additional arguments to be passed to http::geturl.
#
# Results:
#       Caches the Gateway API wss URL string in the variable GatewayUrl and
#       returns the value. An error will be raised if the request was
#       unsuccessful, the returned body is not valid JSON, or if there is no
#       "url" field in the object.

proc discord::gateway::GetGateway {baseUrl {cached true} args} {
    variable log
    variable CachedGatewayUrls
    ${log}::info "Setting log level of websocket"
    if {[string is true -strict $cached]} {
        if {[dict exists $CachedGatewayUrls $baseUrl]} {
            ${log}::info "Using cached Gateway API URL for $baseUrl"
            return [dict get $CachedGatewayUrls $baseUrl]
        } else {
            ${log}::notice "No cached Gateway API URL for $baseUrl"
        }
    }
    variable GatewayResource
    set url "$baseUrl/v$::discord::DiscordApiVersion$GatewayResource"
    ${log}::info "Retrieving Gateway API URL from $url"
    if {[catch {::http::geturl $url {*}$args} token options]} {
        ${log}::error "Error retrieving gateway API URL: $token"
        return -options $options $token
    }

    set ncode [::http::ncode $token]
    upvar #0 $token state

    set code $state(http)       ;# HTTP/1.1 200 OK
    set body $state(body)       ;# {"url": "wss://gateway.discord.gg"}
    set status $state(status)   ;# ok
    ::http::cleanup $token
    if {$status ne "ok"} {
        ${log}::error "Status not OK retrieving gateway API URL: $status"
        return -code error $status
    } elseif {$ncode != 200} {
        ${log}::error "Code not 200 gateway API URL: $code\n$body"
        return -code error $ncode
    }
    if {[catch {::json::json2dict $body} data options]} {
        ${log}::error "JSON parsing failed, body:\n$body"
        return -options $options $data
    }
    if {![dict exists $data url]} {
        return -code error "\"url\" field not found in JSON object."
    }
    set gatewayUrl [dict get $data url]
    dict set CachedGatewayUrls $baseUrl $gatewayUrl
    ${log}::info "Cached Gateway API URL for $baseUrl: $gatewayUrl"
    return $gatewayUrl
}

# discord::gateway::CreateGateway --
#
#       Create a namespace for a gateway.
#
# Arguments:
#       None.
#
# Results:
#       Creates a namespace specific to a gateway. Returns the namespace name.

proc discord::gateway::CreateGateway {} {
    variable GatewayId
    variable log
    ${log}::info "Creating gateway"
    set gatewayNs ::discord::gateway::gateway::$GatewayId
    incr GatewayId
    namespace eval $gatewayNs {}
    set ${gatewayNs}::log [::logger::init $gatewayNs]
    return $gatewayNs
}

# discord::gateway::DeleteGateway --
#
#       Delete a gateway namespace
#
# Arguments:
#       gatewayNs   Name of fully-qualified namespace to delete.
#
# Results:
#       None.

proc discord::gateway::DeleteGateway {gatewayNs} {
    variable log
    ${log}::info "Deleting gateway"
    [set ${gatewayNs}::log]::delete
    namespace delete $gatewayNs
}

# discord::gateway::DeleteUnusedGateways --
#
#       Delete a gateway namespace
#
# Arguments:
#       sock       Gateway socket that is in use.
#
# Results:
#       None.

proc discord::gateway::DeleteUnusedGateways {sock} {
    variable log
    ${log}::info "Deleting gateway"
    variable Gateways
    set socks [dict keys $Gateways]
    foreach oldSock [dict keys $Gateways] {
        if {$sock != $oldSock} {
            DeleteGateway [dict get $Gateways $oldSock]
            dict unset Gateways $oldSock
        }
    }
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
    ${log}::info "Executing script every $interval ms"
    if {$interval eq "cancel"} {
        catch {after cancel $EveryIds($script)}
        return
    }
    set afterId [after $interval [info level 0]]
    set EveryIds($script) $afterId
    
    if {[catch {uplevel #0 $script}]} {
        after cancel $EveryIds($script)
    } else {
        return $afterId
    }
}

# discord::gateway::GetGatewayInfo --
#
#       Get a detail of the Gateway connection.
#
# Arguments:
#       sock    WebSocket object.
#       what    Name of the gateway information to return.
#
# Results:
#       Returns the gateway information.

proc discord::gateway::GetGatewayInfo {sock what} {
    variable Gateways
    variable log 
    ${log}::info "Getting gateway info for $sock from $Gateways"
    if {[dict exists $Gateways $sock]} {
        return [set [dict get $Gateways $sock]::$what]
    }
    ${log}::warn "Could not find socket"
    return -code error "Socket does not exist in Gateways"
}

# discord::gateway::SetGatewayInfo --
#
#       Set gateway information
#
# Arguments:
#       sock    WebSocket object.
#       what    Name of the gateway information to set.
#       value   Value to the gateway information to.
#
# Results:
#       Returns the gateway information.

proc discord::gateway::SetGatewayInfo {sock what value} {
    variable Gateways
    variable log
    ${log}::info "Setting gateway info for $sock"
    return [set [dict get $Gateways $sock]::$what $value]
}

# discord::gateway::CheckOp --
#
#       Check if an opcode value is supported.
#
# Arguments:
#       op  A JSON integer.
#
# Results:
#       Returns 1 if the opcode is valid, or 0 otherwise.

proc discord::gateway::CheckOp {op} {
    variable log
    variable OpTokens
    ${log}::info "Checking op code"
    if {![dict exists $OpTokens $op]} {
        ${log}::error "op not supported: '$op'"
        return 0
    }
    return 1
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
#       Returns 1 if the event is handled successfully, or 0 otherwise.

proc discord::gateway::EventHandler {sock msg} {
    variable log
    variable GatewayCloseEventCode
    set t [dict get $msg t]
    set s [dict get $msg s]
    set d [dict get $msg d]
    ${log}::info "Handling event: sock: '$sock' t: '$t' seq: $s"
    SetGatewayInfo $sock seq $s
    switch -glob -- $t {
        READY {
            dict for {field value} $d {
                SetGatewayInfo $sock $field $value
            }

            set interval [GetGatewayInfo $sock heartbeat_interval]
            ${log}::debug "Sending heartbeat every $interval ms"
            ::discord::gateway::Every $interval \
                [list ::discord::gateway::Send $sock Heartbeat]

            DeleteUnusedGateways $sock
        }
        RESUMED {    ;# Not much to do here
            if {[dict exists $d _trace]} {
                SetGatewayInfo $sock _trace [dict get $d _trace]
            }
            set interval [GetGatewayInfo $sock heartbeat_interval]
            ::discord::gateway::Every $interval \
                [list ::discord::gateway::Send $sock Heartbeat]
            set GatewayCloseEventCode 0

            DeleteUnusedGateways $sock
        }
    }
    set eventCallbacks [GetGatewayInfo $sock eventCallbacks]
    if {[catch {dict get $eventCallbacks $t} res]} {
        ${log}::warn "Unknown Event: $t"
        set res {}
    }
    if {$res eq {}} {
        after idle [list {*}[GetGatewayInfo $sock defEventCallback] $t $d]
    } else {
        after idle [list {*}$res $t $d]
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
#       Returns 1 if the message is handled successfully, or 0 otherwise.

proc discord::gateway::OpHandler {sock msg} {
    variable log
    ${log}::info "Handling op code"
    set op [dict get $msg op]
    if {![CheckOp $op]} {
        return 0
    }

    variable log
    variable OpTokens
    if {[dict exists $OpTokens $op]} {
        set opToken [dict get $OpTokens $op]
    } else {
        ${log}::warn "op not implemented: $op"
        return 0
    }
    ${log}::debug "op: $op ($opToken)"

    switch -glob -- $opToken {
        DISPATCH {
            after idle [list discord::gateway::EventHandler $sock $msg]
        }
        HEARTBEAT {
            ${log}::debug "Heartbeat received"
        }
        RECONNECT {
            after idle [list discord::gateway::Send $sock Resume]
        }
        INVALID_SESSION {
            variable GatewayCloseEventCode
            set GatewayCloseEventCode 0
            after idle [list discord::gateway::Send $sock Identify]
        }
        HELLO {
            SetGatewayInfo $sock heartbeat_interval \
                [dict get $msg d heartbeat_interval]
        }
        HEARTBEAT_ACK {
            ${log}::debug "Heartbeat ACK received"
        }
        default {
            ${log}::warn "op not implemented: ($opToken)"
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
#       Returns 1 if the message is handled successfully, or 0 otherwise.

proc discord::gateway::TextHandler {sock msg} {
    variable log
    variable LogWsMsg
    variable MsgLogLevel
    ${log}::info "Handling text"
    if {$LogWsMsg} {
        ${log}::${MsgLogLevel} "msg: $msg"
    }
    regsub -all {:null} $msg {:""} msg
    if {[catch {::json::json2dict $msg} res]} {
        ${log}::error "$res"
        return 0
    }
    if {[dict exists $res op]} {
        after idle [list discord::gateway::OpHandler $sock $res]
        return 1
    } else {
        ${log}::warn "no op: $res"
        return 0
    }
}

# discord::gateway::Handler --
#
#       Callback procedure invoked when a WebSocket message is received.
#
# Arguments:
#       sock    WebSocket object.
#       type    The type of event.
#       msg     The message as a dictionary that represents a JSON object.
#
# Results:
#       Returns 1 if the message is handled successfully, or 0 otherwise.

proc discord::gateway::Handler {sock type msg} {
    variable log
    variable GatewayCloseEventCode
    variable Gateways
    variable HandlerReExcute
    ${log}::info "type: $type\nHandler: msg: $msg"
    switch -glob -- $type {
        text {
            after idle [list discord::gateway::TextHandler $sock $msg]
        }
        binary {
            if {![catch {::zlib inflate $msg} res]} {
                after idle [list discord::gateway::TextHandler $sock $res]
            } else {
                set bytes [string length $msg]
                ${log}::warn "$bytes bytes of binary data."
            }
        }
        connect {
            if {[catch {GetGatewayInfo $sock connectCallback} cmd]} {
                set HandlerReExcute [list ::discord::gateway::Handler $sock \
                    $type $msg]
                ${log}::warn "Failed to get gateway info. Postponing execution."
                return 0
            }

            if {[llength $cmd] > 0} {
                ::[lindex $cmd 0] {*}[lrange $cmd 1 end] $sock
            }
            if {$GatewayCloseEventCode in [list 0 1000]} {
                after idle [list discord::gateway::Send $sock Identify]
                ${log}::notice "Connected."
            } else {
                set data [MakeResume $sock]
                after idle [list discord::gateway::Send $sock Resume]
                ${log}::notice "Reconnected."
            }
        }
        close {
            ::discord::gateway::Every cancel \
                [list ::discord::gateway::Send $sock Heartbeat]
            after cancel [list ::discord::gateway::SetGatewayInfo $sock \
                sendCount 0]
            ${log}::notice "Connection closed from $sock."
            set GatewayCloseEventCode [lindex $msg 0]
        }
        disconnect {
            variable Gateways
            variable GatewayCloseEventCodes
            ${log}::notice "Disconnected from $sock"
            if {$GatewayCloseEventCode ni [dict keys $RpcCloseEventCodes]} {
                set interval [GetGatewayInfo $sock heartbeat_interval]
                set gatewayNs [dict get $Gateways $sock]
                set sessionNs ::discord::session::[expr {
                    $::discord::SessionId - 1
                }]
                after $interval [list ::discord::gateway::reconnect \
                    $gatewayNs $sessionNs $sock]
            } else {
                ${log}::notice \
                    [dict get $GatewayCloseEventCodes $GatewayCloseEventCode]
                exit
            }
        }
        error {      ;# Not sure if Discord uses this.
            ${log}::notice "ping: $msg"
        }
        default {
            ${log}::warn "Type not implemented: '$type'"
            return 0
        }
    }
    ${log}::debug "Exiting handler"
    return 1
}

# discord::gateway::Send --
#
#       Send WebSocket messages to the Gateway, rate limited to 120 per minute.
#
# Arguments:
#       sock    WebSocket object.
#       opProc  Suffix of the Make* procedure that returns the message data.
#       args    Arguments to pass to opProc.
#
# Results:
#       Returns 1 if the message is sent successfully, or 0 otherwise.

proc discord::gateway::Send {sock opProc args} {
    variable log
    variable ProcOps
    variable LogWsMsg
    variable MsgLogLevel
    variable LimitPeriod
    variable LimitSend
    ${log}::info "Sending websocket message"
    set sendCount [GetGatewayInfo $sock sendCount]
    if {$sendCount == 0} {
        after [expr {$LimitPeriod * 1000}] \
                [list ::discord::gateway::SetGatewayInfo $sock sendCount 0]
    }
    if {$sendCount >= $LimitSend} {
        ${log}::warn "Reached $LimitSend messages sent in $LimitPeriod s"
        return 0
    }
    if {![dict exists $ProcOps $opProc]} {
        ${log}::error "Invalid procedure suffix: '$opProc'"
        return 0
    }
    set op [dict get $ProcOps $opProc]
    set data [Make${opProc} $sock {*}$args]
    set msg [::json::write::object op $op d $data]
    if {$LogWsMsg} {
        ${log}::${MsgLogLevel} "$msg"
    }
    if [catch {::websocket::send $sock text $msg} res] {
        ${log}::error "::websocket::send: $res"
        return 0
    }
    SetGatewayInfo $sock sendCount [incr sendCount]
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

proc discord::gateway::MakeHeartbeat {sock} {
    variable log
    ${log}::info "Making heartbeat"
    return [GetGatewayInfo $sock seq]
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

proc discord::gateway::MakeIdentify {sock args} {
    variable log
    ${log}::info "Creating identify"
    set token               [::json::write::string \
                                    [GetGatewayInfo $sock token]]
    set os                  [::json::write::string linux]
    set agent               "discord.tcl $::discord::DiscordTclVersion"
    set browser             [::json::write::string $agent]
    set device              [::json::write::string $agent]
    set referrer            [::json::write::string ""]
    set referring_domain    [::json::write::string ""]
    set compress            [GetGatewayInfo $sock compress]
    set large_threshold     50
    set shardInfo [GetGatewayInfo $sock shard]
    set shardId [lindex $shardInfo 0]
    set numShards [lindex $shardInfo 1]
    if {![string is integer -strict $numShards] || $numShards < 1} {
        ${log}::warn "Invalid num_shards, setting to 1: $numShards"
        set numShards 1
    }
    if {
        ![string is integer -strict $shardId] ||
        ($shardId < 0) ||
        ($numShards <= $shardId)
    } { 
        ${log}::warn "Invalid shard_id, setting to 0: $shardId"
        set shardId 0
    }
    set shard [::json::write::array $shardId $numShards]
    foreach {option value} $args {
        if {[string index $option 0] ne -} {continue}
        set opt [string range $option 1 end]
        set validOpts  {
            os browser device referrer referring_domain compress 
            large_threshold shard
        }
        if {$opt ni $validOpts} {
            ${log}::error "Invalid option: '$opt'"
            continue
        }
        switch -glob -- $opt {
            compress {
                if {$value ni {true false}} {
                    ${log}::error "Compress: Invalid value: '$value'"
                    continue
                }
            }
            large_threshold {
                if {
                    ![string is integer -strict $value] ||
                    ($value < 50) ||
                    ($value > 250)
                } {
                    ${log}::error "Large_threshold: Invalid value: '$value'"
                    continue
                }
            }
        }
        set $opt $value
    }
    return [::json::write::object \
        token $token \
        properties [::json::write::object \
            {$os} $os \
            {$browser} $browser \
            {$device} $device \
            {$referrer} $referrer \
            {$referring_domain} $referring_domain \
        ] \
        compress $compress \
        large_threshold $large_threshold \
        shard $shard \
    ]
}

# discord::gateway::reconnect --
#
#       Create a message to resume a connection after you are disconnected from 
#       the Gateway.
#
# Arguments:
#       pGatewayNs  Name of previous fully-qualified namespace to delete.
#       sessionNs   Name of a session namespace.
#       prevSock    Previous WebSocket object.
#
# Results:
#       Returns a JSON object containing the required information.

proc discord::gateway::reconnect {pGatewayNs sessionNs prevSock} {
    variable log
    
    ${log}::info "Reconnecting $pGatewayNs $sessionNs $prevSock"
    if {[catch {GetGateway $::discord::ApiBaseUrl} gateway options]} {
        ${log}::error "Error getting gateway: $gateway"
        return -options $options $gateway
    }
    variable GatewayApiEncoding
    append gateway "/?v=${discord::DiscordApiVersion}&"
    append gateway "encoding=$GatewayApiEncoding"
    ${log}::debug "$gateway"
    # There might be a race condition where the Gateways dictionary doesn't get
    # initialized with the new socket before Handler gets called.
    if {
        [catch {::websocket::open $gateway ::discord::gateway::Handler} \
            sock options]
    } {
        ${log}::error "Error connecting to websocket: $gateway: $sock"
        set interval [GetGatewayInfo $prevSock heartbeat_interval]
        after $interval [list ::discord::gateway::reconnect $pGatewayNs \
            $sessionNs $prevSock]
        return 1
    }
    ${log}::notice "Gateway replied with $sock"
    variable Gateways
    variable DefHeartbeatInterval
    variable DefCompress
    variable EventCallbacks
    variable HandlerReExcute
    set gatewayNs [CreateGateway]
    dict set Gateways $sock $gatewayNs
    set ${gatewayNs}::sock               $sock
    set ${gatewayNs}::defEventCallback   [set ${pGatewayNs}::defEventCallback]
    set ${gatewayNs}::sendCount          0
    set ${gatewayNs}::seq                [set ${pGatewayNs}::seq]
    set ${gatewayNs}::session_id         [set ${pGatewayNs}::session_id]
    set ${gatewayNs}::connectCallback    [set ${pGatewayNs}::connectCallback]
    set ${gatewayNs}::eventCallbacks     [set ${pGatewayNs}::eventCallbacks]
    set ${gatewayNs}::shard              [set ${pGatewayNs}::shard]
    set ${gatewayNs}::token              [set ${pGatewayNs}::token]
    set ${gatewayNs}::heartbeat_interval [set ${pGatewayNs}::heartbeat_interval]
    set ${gatewayNs}::compress           [set ${pGatewayNs}::compress]

    set ${sessionNs}::gatewayNs $gatewayNs

    # Handling race condition
    if {$HandlerReExcute != ""} {
        ${log}::warn "Running rexecution."
        uplevel #0 $HandlerReExcute
        set HandlerReExcute ""
    }
    return 1
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

proc discord::gateway::MakeResume {sock} {
    variable log
    ${log}::info "Resuming"
    return [::json::write::object \
        token [::json::write::string [GetGatewayInfo $sock token]] \
        session_id [::json::write::string [GetGatewayInfo $sock session_id]] \
        seq [GetGatewayInfo $sock seq] \
    ]
}

# discord::gateway::EventCallbackStub --
#
#       Stub for Dispatch events.
#
# Arguments:
#       event   Event name.
#       data    Dictionary representing a JSON object
#
# Results:
#       None.

proc discord::gateway::EventCallbackStub {event data} {
    variable log
    ${log}::info "Stub"
    return
}
