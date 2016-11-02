# Tcl package index file, version 1.1
# This file is generated by the "pkg_mkIndex" command
# and sourced either when an application starts up or
# by a "package unknown" script.  It invokes the
# "package ifneeded" command to set up package-related
# information so that packages will be loaded automatically
# in response to "package require" commands.  When this
# script is sourced, the variable $dir must contain the
# full path name of this file's directory.

package ifneeded discord 0.6.0 "
    source [file join $dir gateway.tcl] ;
    source [file join $dir callback.tcl] ;
    source [file join $dir disrest.tcl] ;
    source [file join $dir json_specs.tcl] ;
    source [file join $dir disrest_channel.tcl] ;
    source [file join $dir disrest_guild.tcl] ;
    source [file join $dir disrest_invite.tcl] ;
    source [file join $dir disrest_user.tcl] ;
    source [file join $dir disrest_voice.tcl] ;
    source [file join $dir disrest_webhook.tcl] ;
    source [file join $dir discord_wrapper.tcl] ;
    source [file join $dir permissions.tcl] ;
    source [file join $dir snowflake.tcl] ;
    source [file join $dir message_formatting.tcl] ;
    source [file join $dir discord.tcl] ;
"
