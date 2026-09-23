# A loopback https + http server for tls.test (AGENTS.md D109) — run as a CHILD process,
# never sourced: rio::http::get is synchronous, so a server sharing its event loop would
# never get to answer.
#
#   tclsh tls-server.tcl <certdir>
#
# <certdir> holds good.pem/good.key (for "localhost"), wrong.pem/wrong.key (for
# "other.example"), other.pem/other.key (a second, different "localhost") and, when
# openssl could make it, expired.pem/expired.key (a "localhost" that expired in 2020).
# Listens on OS-assigned ports and prints them on one line (an absent certificate: "-"):
#   <https-good> <https-wrong> <http> <https-expired> <https-other>
# then serves until its stdin closes (the test closes the pipe — no kill, so Windows too).
#
# Routes, the same on every port:
#   /count 200, the body is how many requests this server has answered, this one included
#          — how a test proves a certificate probe sent no request (D111)
#   /ok    200, the body names the scheme ("hello over https" / "hello over http")
#   /down  302 to http://localhost:<http>/ok     — https → http, which rio must refuse
#   /up    302 to https://localhost:<https-good>/ok — http → https, which rio follows

# The D54 source guard: Tcl 8.6 decodes this file with the SYSTEM encoding, and tls.test
# runs it as a child process of its own, so it re-reads itself as UTF-8. See AGENTS.md D54.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
package require tls
lassign $argv certdir

proc accept {tls chan addr port} {
	fconfigure $chan -blocking 0 -translation crlf
	fileevent $chan readable [list serve $tls $chan]
}

proc serve {tls chan} {
	if {$tls} {
		if {[catch {tls::handshake $chan} done]} { catch {close $chan} ; return }
		if {!$done} return
	}
	while {[gets $chan line] >= 0} {
		if {[regexp {^GET (\S+)} $line -> path]} { set ::path($chan) $path }
		if {$line ne ""} continue
		fileevent $chan readable {}
		set path [expr {[info exists ::path($chan)] ? $::path($chan) : "/"}]
		unset -nocomplain ::path($chan)
		reply $chan $tls $path
		return
	}
	if {[eof $chan]} { catch {close $chan} }
}

set ::requests 0   ;# every request line served, /count included

proc reply {chan tls path} {
	incr ::requests
	switch -- $path {
		/count {
			set body $::requests
			set head "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: [string length $body]\r\n"
		}
		/ok {
			set body "hello over [expr {$tls ? "https" : "http"}]"
			set head "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: [string length $body]\r\n"
		}
		/down {
			set body ""
			set head "HTTP/1.0 302 Found\r\nLocation: http://localhost:$::ports(http)/ok\r\nContent-Length: 0\r\n"
		}
		/up {
			set body ""
			set head "HTTP/1.0 302 Found\r\nLocation: https://localhost:$::ports(good)/ok\r\nContent-Length: 0\r\n"
		}
		default {
			set body "no such path"
			set head "HTTP/1.0 404 Not Found\r\nContent-Length: [string length $body]\r\n"
		}
	}
	fconfigure $chan -translation binary
	catch {
		puts -nonewline $chan "$head\r\n$body"
		close $chan
	}
}

foreach name {good wrong expired other} {
	# expired.pem needs an openssl that can backdate; without it that port is "-".
	if {![file exists [file join $certdir $name.pem]]} { set ::ports($name) - ; continue }
	set s [tls::socket -server [list accept 1] \
		-certfile [file join $certdir $name.pem] -keyfile [file join $certdir $name.key] 0]
	set ::ports($name) [lindex [fconfigure $s -sockname] 2]
}
set s [socket -server [list accept 0] 0]
set ::ports(http) [lindex [fconfigure $s -sockname] 2]

puts "$::ports(good) $::ports(wrong) $::ports(http) $::ports(expired) $::ports(other)"
flush stdout
fconfigure stdin -blocking 0
fileevent stdin readable { read stdin ; if {[eof stdin]} exit }
after 60000 exit   ;# a runaway test never leaves this behind for long
vwait forever
