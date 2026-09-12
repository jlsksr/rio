# A loopback https + http server for tls.test (AGENTS.md D109) — run as a CHILD process,
# never sourced: rio::http::get is synchronous, so a server sharing its event loop would
# never get to answer.
#
#   tclsh tls-server.tcl <certdir>
#
# <certdir> holds good.pem/good.key (for "localhost") and wrong.pem/wrong.key (for
# "other.example"). Listens on three OS-assigned ports and prints them on one line:
#   <https-good> <https-wrong> <http>
# then serves until its stdin closes (the test closes the pipe — no kill, so Windows too).
#
# Routes, the same on every port:
#   /ok    200, the body names the scheme ("hello over https" / "hello over http")
#   /down  302 to http://localhost:<http>/ok     — https → http, which rio must refuse
#   /up    302 to https://localhost:<https-good>/ok — http → https, which rio follows

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

proc reply {chan tls path} {
	switch -- $path {
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

foreach {name cert} {good good wrong wrong} {
	set s [tls::socket -server [list accept 1] \
		-certfile [file join $certdir $cert.pem] -keyfile [file join $certdir $cert.key] 0]
	set ::ports($name) [lindex [fconfigure $s -sockname] 2]
}
set s [socket -server [list accept 0] 0]
set ::ports(http) [lindex [fconfigure $s -sockname] 2]

puts "$::ports(good) $::ports(wrong) $::ports(http)"
flush stdout
fconfigure stdin -blocking 0
fileevent stdin readable { read stdin ; if {[eof stdin]} exit }
after 60000 exit   ;# a runaway test never leaves this behind for long
vwait forever
