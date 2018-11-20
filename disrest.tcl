# disrest.tcl --
#
#       This file implements the Tcl code for interacting with the Discord HTTP
#       API.
#
# Copyright (c) 2016, Yixin Zhang
#
# See the file "LICENSE" for information on usage and redistribution of this
# file.

package require Tcl 8.6
package require http
package require tls
package require json
package require json::write
package require logger

::http::register https 443 ::tls::socket

namespace eval discord::rest {
    variable log [logger::init discord::rest]

    set HttpApiVersion 6

    variable SendId 0
    variable SendInfo [dict create]

    variable RateLimits [dict create]
    variable SendCount [dict create]
    variable BurstLimitSend 5
    variable BurstLimitPeriod 1
    
    set ::json::write::quotes \
      [list "\"" "\\\"" \\ \\\\ \b \\b \f \\f \n \\n \r \\r \t \\t \
        \x00 \\u0000 \x01 \\u0001 \x02 \\u0002 \x03 \\u0003 \
        \x04 \\u0004 \x05 \\u0005 \x06 \\u0006 \x07 \\u0007 \
        \x0b \\u000b \x0e \\u000e \x0f \\u000f \x10 \\u0010 \
        \x11 \\u0011 \x12 \\u0012 \x13 \\u0013 \x14 \\u0014 \
        \x15 \\u0015 \x16 \\u0016 \x17 \\u0017 \x18 \\u0018 \
        \x19 \\u0019 \x1a \\u001a \x1b \\u001b \x1c \\u001c \
        \x1d \\u001d \x1e \\u001e \x1f \\u001f ]
}

# discord::rest::Send --
#
#       Send HTTP requests to the Discord HTTP API.
#
# Arguments:
#       token       Bot token or OAuth2 bearer token.
#       verb        HTTP method. One of GET, POST, PUT, PATCH, DELETE.
#       resource    Path relative to the base URL, prefixed with '/'.
#       body        (optional) body to be sent in the request.
#       cmd         (optional) list containing a callback procedure, and
#                   additional arguments to be passed to it. The last two
#                   arguments will be a data dictionary, and the HTTP code or
#                   error.
#       args        (optional) addtional options and values to be passed to
#                   http::geturl.
#
# Results:
#       Raises an exception if verb is unknown.

proc discord::rest::Send { token verb resource {body {}} {cmd {}} args } {
    variable log
    variable SendId
    variable SendInfo
    variable RateLimits
    variable SendCount
    variable BurstLimitSend
    variable BurstLimitPeriod
    if {$verb ni [list GET POST PUT PATCH DELETE]} {
        ${log}::error "Send: HTTP method not recognized: '$verb'"
        return -code error "Unknown HTTP method: $verb"
    }

    if {[regexp {^(/(?:channels|guilds)/\d+)} $resource -> route]} {
        if {![dict exists $SendCount $token $route]} {
            dict set SendCount $token $route 0
        }
        set sendCount [dict get $SendCount $token $route]
        if {$sendCount == 0} {
            after [expr {$BurstLimitPeriod * 1000}] [list \
                    dict set ::discord::rest::SendCount $token $route 0]
        }
        if {$sendCount >= $BurstLimitSend} {
            ${log}::warn [join [list "Send: Reached $BurstLimitSend messages" \
                    "sent in $BurstLimitPeriod s."]]
            if {[llength $cmd] > 0} {
                {*}$cmd {} "Local rate-limit"
            }
            return
        }
        if {[dict exists $RateLimits $token $route X-RateLimit-Remaining]} {
            set remaining [dict get $RateLimits $token $route \
                    X-RateLimit-Remaining]
            if {$remaining <= 0} {
                set resetTime [dict get $RateLimits $token $route \
                        X-RateLimit-Reset]
                set secsRemain [expr {$resetTime - [clock seconds]}]
                if {$secsRemain >= -3} {
                    ${log}::warn [join [list "Send: Rate-limited on /$route," \
                            "reset in $secsRemain seconds"]]
                    return
                }
            }
        }
        dict set SendCount $token $route [incr sendCount]
    }

    set moreOptions [list]
    set moreHeaders [list]
    
    foreach {option value} $args {
        if {![regexp {^-(\w+)$} $option -> opt]} {
            return -code error "Invalid option: $option"
        } elseif {$opt in [list method command]} {
            return -code error "Option can't be used: $option"
        }
        if {$option eq "-headers"} {
            lappend moreHeaders {*}$value
        } else {
            lappend moreOptions $option $value
        }
    }

    set sendId $SendId
    incr SendId
    set callbackName ::discord::rest::SendCallback${sendId}
    interp alias {} $callbackName {} ::discord::rest::SendCallback $sendId

    variable HttpApiVersion
    set url "$::discord::ApiBaseUrl/v$HttpApiVersion$resource"
    dict set SendInfo $sendId [dict create cmd $cmd url $url token $token]
    if {[info exists route]} {
        dict set SendInfo $sendId route $route
    }
    set command [list ::http::geturl $url \
            -headers [list Authorization "Bot $token" {*}$moreHeaders] \
            -method $verb \
            {*}$moreOptions]
    if {$body ne {}} {
        lappend command -query $body
    }
    lappend command -command $callbackName
    ${log}::debug "Send: $command"
    {*}$command
    return
}

# discord::rest::SendCallback --
#
#       Callback procedure invoked when a HTTP transaction completes.
#
# Arguments:
#       id      Internal Send ID.
#       token   Returned from ::http::geturl, name of a state array.
#
# Results:
#       Invoke stored callback procedure for the corresponding send request.
#       Returns 1 on success

proc discord::rest::SendCallback { sendId token } {
    variable log
    variable SendInfo
    variable RateLimits
    interp alias {} ::discord::rest::SendCallback${sendId} {}
    if {[dict exists $SendInfo $sendId route]} {
        set route [dict get $SendInfo $sendId route]
    }
    set url [dict get $SendInfo $sendId url]
    set cmd [dict get $SendInfo $sendId cmd]
    set discordToken [dict get $SendInfo $sendId token]
    set state [array get $token]
    set status [::http::status $token]
    
    switch $status {
        ok {
            array set meta [::http::meta $token]
            foreach header [list X-RateLimit-Limit X-RateLimit-Remaining \
                    X-RateLimit-Reset] {
                if {[info exists route] && [info exists meta($header)]} {
                    dict set RateLimits $discordToken $route \
                            $header $meta($header)
                }
            }
            set code [::http::code $token]
            set ncode [::http::ncode $token]
            if {$ncode >= 300} {
                ${log}::warn [join [list \
                        "SendCallback${sendId}: $url: $code:" \
                        [::http::data $token]]]
                if {[llength $cmd] > 0} {
                    after idle [list {*}$cmd {} $state]
                }
            } else {
                ${log}::debug "SendCallback${sendId}: $url: $code"
                if {[llength $cmd] > 0} {
                    set data [::http::data $token]
                    if {$data ne {} && [catch {json::json2dict $data} data]} {
                        ${log}::error "SendCallback${sendId}: $url: $data"
                        set data {}
                    }
                    after idle [list {*}$cmd $data $state]
                }
            }
        }
        error {
            set error [::http::error $token]
            ${log}::error "SendCallback${sendId}: $url: error: $error"
            if {[llength $cmd] > 0} {
                after idle [list {*}$cmd {} $state]
            }
        }
        default {
            ${log}::error "SendCallback${sendId}: $url: $status"
            if {[llength $cmd] > 0} {
                after idle [list {*}$cmd {} $state]
            }
        }
    }
    dict unset SendInfo $sendId
    ::http::cleanup $token
    return
}

# discord::rest::CallbackCoroutine
#
#       Resume a coroutine that is waiting for the response from a previous
#       call to Send. The coroutine should call this coroutine after resumption
#       to get the results. This procedure should be passed in a list to the
#       'cmd' argument of Send, e.g.
#           Send ... [list coroutine $contextName \
#                   discord::rest::CallbackCoroutine $callerName]
#
# Arguments:
#       coroutine   Coroutine to be resumed.
#       data        Dictionary representing a JSON object, or empty if an error
#                   had occurred.
#       state       The HTTP state array in a list.
#
# Results:
#       Returns a list containing data and state.

proc discord::rest::CallbackCoroutine { coroutine data state } {
    if {[llength [info commands $coroutine]] > 0} {
        after idle $coroutine
        yield
    }
    return [list $data $state]
}

# discord::rest::DictToJson --
#
#       Serialize a dictionary as a JSON string with a specification.
#
# Arguments:
#       data    Dictionary representing a JSON object.
#       spec    Dictionary where each key is a field name, and each value is a
#               list containing two elements, the field type, metadata about the
#               type. The value can also just be the field type if no metadata
#               is required. Field types are one of object, array, string, bare.
#               Actions for each field type on the value:
#               object: Call DictToJson on the value with metadata as spec.
#               array: metadata must be one of [list object spec],
#                   [list array [list type meta]], string, bare.
#                   Performs the relevant action for the type.
#               string: Apply json::write::string.
#               bare: Nothing is done.
#       indent  (optional) boolean for setting the output indentation setting.
#               Default to false.
#       level   Used in embeds to track embed length
#
# Results:
#       Returns the modified dictionary value.
#
# Examples:
#       data: { id 12345 messages {1 2 3} user {gold 0} }
#       spec: { id {string {}}
#               messages {array string}
#               user {object {
#                       gold {bare {}}
#                     }
#                   }
#             }

proc discord::rest::DictToJson { data spec {indent false} {level {}}} {
    ::json::write::indented $indent
    set jsonData [dict create]
    set embedlen 0
    dict for {field typeInfo} $spec {
        if {![dict exists $data $field]} {
            continue
        }
        lassign $typeInfo type meta
        set value [dict get $data $field]
        switch $type {
            object {
                if {$field eq "embed"} {
                    set level "#[info level]"
                }
                set value [DictToJson $value $meta $indent $level]
            }
            array {
                if {$field eq "fields" && [llength $value] > 25} {
                    return -code error \
                        "Number of fields in embed cannot exceed 25."
                }
                set value [ListToJsonArray $value {*}$meta $level]
            }
            string {
                # embed limits
                switch $field {
                    "name" -
                    "title" {
                        if {[string length $value] > 256} {
                          set value [string range $value 0 253]
                            regexp {.+(?=\s)} $value value
                            set value "$value..."
                        }
                    }
                    "value" {
                        if {[string length $value] > 1024} {
                            set value [string range $value 0 1021]
                            regexp {.+(?=\s)} $value value
                            set value "$value..."
                        }
                    }
                    "footer" -
                    "description" {
                        if {[string length $value] > 2048} {
                          set value [string range $value 0 2045]
                            regexp {.+(?=\s)} $value value
                            set value "$value..."
                        }
                    }
                }
                if {$level != ""} {
                    uplevel $level [list incr embedlen [string length $value]]
                }
                set value [::json::write::string $value]
            }
            bare {
                if {$field eq "color"} {
                  array set colours {
                    white   ffffff
                    silver  c0c0c0
                    gray    808080
                    black   000000
                    red     ff0000
                    maroon  800000
                    yellow  ffff00
                    olive   808000
                    lime    00ff00
                    green   008000
                    aqua    00ffff
                    teal    008080
                    blue    0000ff
                    navy    000080
                    fuchsia ff00ff
                    purple  800080
                  }
                  if {$level != ""} {
                      uplevel $level [list incr embedlen [string length $value]]
                  }
                  if {[regexp -nocase {^[0-9a-f]{1,6}$} $value]} {
                      set value [format %d "0x$value"]
                  } elseif {[string tolower $value] in [array names colours]} {
                      set value [format %d "0x$colours([string tolower $value])"]
                  }
                }
            }
            default {
                return -code error "Unknown type: $type"
            }
        }
        dict set jsonData $field $value
    }
    if {$embedlen > 6000} {
      return -code error "Total length of embed cannot exceed 6000 characters."
    }
    return [::json::write::object {*}$jsonData]
}

# discord::rest::ListToJsonArray --
#
#       Serialize a list as a JSON array.
#
# Arguments:
#       list    List of elements to seralize.
#       type    The type to serialize each element into.
#       meta    (optional) type and meta of subarrays if type is array, or JSON
#               specification if type is object. Refer to
#               discord::rest::DictToJson's spec argument for details.
#       level   Used in embeds to track embed length
#
# Results:
#       Returns a JSON array.

proc discord::rest::ListToJsonArray { list type {meta {}} {level {}}} {
    set jsonArray [list]
    switch $type {
        object {
            foreach element $list {
                lappend jsonArray [DictToJson $element $meta false $level]
            }
        }
        array {
            lassign $meta subtype submeta
            foreach element $list {
                lappend jsonArray [ListToJsonArray $element $subtype $submeta $level]
            }
        }
        string {
            foreach element $list {
                if {$level != ""} {
                    uplevel $level [list incr embedlen [string length $element]]
                }
                lappend jsonArray [::json::write::string $element]
            }
        }
        bare {
            if {$level != ""} {
                uplevel $level [list incr embedlen [string length $list]]
            }
            set jsonArray $list
        }
        default {
            return -code error "Invalid array element type: $type"
        }
    }
    return [::json::write::array {*}$jsonArray]
}
