# discord.tcl 0.7.0
Discord API library writtten in Tcl.
Tested with Tcl 8.6.
Supports Discord Gateway API version 6.

### Status/TODO

- HEARTBEAT and HEARTBEAT_ACK response not implemented. Currently only taking 
  the heartbeat interval from the HELLO payload and ignoring HEARTBEAT and 
  HEARTBEAT_ACK altogether. The bot still runs fine because it will attempt to 
  reconnect on the next failed HEARTBEAT *sent*.
- Need to do a full review on [Rate Limits](https://discord.com/developers/docs/topics/gateway#rate-limiting).
- Basic sharding is currently implemented. It ain't broke per se, so not fixing 
  it for now. Also includes [this](https://discord.com/developers/docs/topics/gateway#get-gateway-bot).
- [User Status](https://discord.com/developers/docs/topics/gateway#update-status) not implemented
- Request Guild Members Gateway opcode not implemented
- Most voice-related stuff not implemented; only the basic ones are implemented

Not sure yet what to do with those from previous owner todo list:
- Test cases for "pure" procs, send HTTP requests to test both HTTP responses
  and Gateway events.
- Find out why *zlib inflate* fails.
- Use "return -code error -errorcode ..." when possible for standardized
  exception handling. See ThrowError in websocket from tcllib for an example.
- Use the *try* command.
- Create a tcltest custommatch to check -errorcode.
- Test HTTP API and Gateway API with local server.

### Libraries

- [Tcllib 1.18](http://www.tcl.tk/software/tcllib) (*websocket*, *json*,
    *json::write*, *logger*, *uuid*)
- [TLS 1.6.7](https://sourceforge.net/projects/tls) (*tls*)

### Usage
Check out [MarshtompBot](https://github.com/Unknown008/MarshtompBot) for a bot 
written with this library.

DIY: For when you feel like writing your own discord.tcl.
```
package require discord

${discord::log}::setlevel info

proc messageCreate {event data} {
    set timestamp [dict get $data timestamp]
    set username [dict get $data author username]
    set discriminator [dict get $data author discriminator]
    set content [dict get $data content]
    puts "$timestamp ${username}#${discriminator}: $content"
}

proc registerCallbacks { sock } {
    discord::gateway setCallback $sock MESSAGE_CREATE messageCreate
}

set token "your token here"
set sock [discord::gateway connect $token registerCallbacks]

vwait forever

# Cleanup
discord::gateway disconnect $sock
```

Example output
```
[Wed Nov 23 18:39:19 EST 2016] [discord::gateway] [notice] 'GetGateway: No cached Gateway API URL for https://discordapp.com/api'
[Wed Nov 23 18:39:19 EST 2016] [discord::gateway] [info] 'GetGateway: Retrieving Gateway API URL from https://discordapp.com/api/v6/gateway'
[Wed Nov 23 18:39:19 EST 2016] [discord::gateway] [info] 'GetGateway: Cached Gateway API URL for https://discordapp.com/api: wss://gateway.discord.gg'
[Wed Nov 23 18:39:19 EST 2016] [discord::gateway] [notice] 'connect: wss://gateway.discord.gg/?v=6&encoding=json'
[Wed Nov 23 18:39:19 EST 2016] [discord::gateway] [notice] 'Handler: Connected.'
2016-11-23T23:39:25.953000+00:00 [redacted]#0000: Don't ever reduce achievements. Add more!!
```

### Testing

Sourcing or executing a .test file found under tests/ will test related
namespace procedures.

E.g.
```
tclsh tests/gateway.test
```

The file [local\_server.tcl](/tests/local_server.tcl) contains procedures for
setting up a local HTTP(S) server. The main proc is LocalServerSetupAll.

### Links

- [Tcl Developer Xchange](https://tcl.tk)
- [Coding style guide](http://www.tcl.tk/doc/styleGuide.pdf)