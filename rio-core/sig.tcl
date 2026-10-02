# rio-core — verifying an OpenSSH detached signature (D118).
#
# A publisher signs a repository's root SHA256SUMS with an SSH key. rio checks
# it with the same tool, so it owns no crypto:
#
#   ssh-keygen -Y sign   -f key -n rio-repository SHA256SUMS      (publisher)
#   ssh-keygen -Y verify -f <allowed_signers> -I <principal> \
#              -n rio-repository -s SHA256SUMS.sig < SHA256SUMS   (here)
#
# - Core-side: the tool must be on the core's host (D30).
# - No ssh-keygen, or one older than OpenSSH 8.0 (no `-Y`): `available 0`.
#   That is not a failed signature; the caller decides what it means
#   (CAVEATS.md, WINDOWS.md §9).
# - The verdict rests on the key and the namespace. The principal only selects
#   the one line of the allowed-signers file, which rio writes itself.
# - A key must be a type and base64 on one line (key_ok). A newline in it
#   would add principals to that file.
# - Exact bytes: data and signature go to the child as temp files in UTF-8.
#   `exec <<` would re-encode them in the system encoding, so rio::exec::run
#   is not used.

namespace eval rio::sig {
	variable _tool     ""   ;# cached path to ssh-keygen ("" = none), see tool
	variable _searched 0
	variable namespace_default rio-repository
}

# Where ssh-keygen is, or "". Only a hit is cached, so installing OpenSSH
# later works without a restart.
proc rio::sig::tool {} {
	variable _tool
	variable _searched
	if {$_searched && $_tool ne ""} { return $_tool }
	set p [lindex [auto_execok ssh-keygen] 0]
	if {$p ne ""} { set _tool $p ; set _searched 1 }
	return $p
}

proc rio::sig::_spit {path data} {
	set f [open $path wb]
	puts -nonewline $f [encoding convertto utf-8 $data]
	close $f
}

proc rio::sig::_slurp {path} {
	set f [open $path rb]
	set d [::read $f]
	close $f
	return [encoding convertfrom utf-8 $d]
}

# Run ssh-keygen with argv, stdin redirected FROM a file, and return
# {exitcode <n> stdout <s> stderr <s>} — or raise, when the spawn itself failed.
proc rio::sig::_run {argv stdin_path} {
	set outf [file tempfile outpath] ; close $outf
	set errf [file tempfile errpath] ; close $errf
	set exitcode 0
	set rc [catch {exec -- {*}$argv < $stdin_path > $outpath 2> $errpath} msg opts]
	if {$rc} {
		set ec [dict get $opts -errorcode]
		switch -- [lindex $ec 0] {
			CHILDSTATUS { set exitcode [lindex $ec 2] }
			CHILDKILLED { set exitcode -1 }
			NONE        { set exitcode 0 }
			default {
				file delete $outpath $errpath
				error $msg
			}
		}
	}
	set out [_slurp $outpath]
	set err [_slurp $errpath]
	file delete $outpath $errpath
	return [dict create exitcode $exitcode stdout $out stderr $err]
}

# Is `key` a public key as a repository publishes it: type and base64, one
# line, nothing else?
proc rio::sig::key_ok {key} {
	if {[regexp {[\n\r]} $key]} { return 0 }
	set parts [regexp -all -inline {\S+} $key]
	if {[llength $parts] != 2} { return 0 }
	if {![regexp {^(ssh|ecdsa|sk-)[A-Za-z0-9@.-]+$} [lindex $parts 0]]} { return 0 }
	return [regexp {^[A-Za-z0-9+/]+=*$} [lindex $parts 1]]
}

# A principal (rio uses the source URL) and a namespace both go into the
# allowed-signers file as fields, so neither may carry whitespace.
proc rio::sig::field_ok {s} {
	return [expr {$s ne "" && ![regexp {\s} $s]}]
}

# The SHA256: fingerprint of a public key, for showing a user which key they are
# trusting — "" when the key is junk or there is no tool to ask.
proc rio::sig::fingerprint {key} {
	set tool [tool]
	if {$tool eq "" || ![key_ok $key]} { return "" }
	set f [file tempfile path] ; close $f
	set fp ""
	catch {
		_spit $path "$key\n"
		# -lf prints "256 SHA256:<base64> <comment> (ED25519)".
		regexp {(SHA256:[A-Za-z0-9+/=]+)} [exec -- $tool -lf $path] -> fp
	}
	file delete $path
	return $fp
}

# Verify `sig` (the armoured SSH signature) over `data` by `key`, in `namespace`.
# Returns, never raising:
#
#   available   0 when nothing could be asked: no ssh-keygen, one too old, or a
#               spawn that failed. `verified` is then 0 and means nothing.
#   verified    1 only on exit 0 AND ssh-keygen's own "Good <namespace> signature".
#   signer      the fingerprint ssh-keygen says verified it (proof, not decoration)
#   fingerprint the fingerprint of the key we passed in, for display
#   reason      why not, in ssh-keygen's words — never "" when verified is 0
proc rio::sig::verify {data sig key principal {ns ""}} {
	variable namespace_default
	if {$ns eq ""} { set ns $namespace_default }
	set out [dict create available 1 verified 0 signer "" fingerprint "" reason ""]
	set tool [tool]
	if {$tool eq ""} {
		return [dict merge $out [dict create available 0 \
			reason "ssh-keygen isn't installed on the core's host, so rio can't check any signature"]]
	}
	if {![key_ok $key]} {
		return [dict merge $out [dict create \
			reason "the repository's key isn't a usable SSH public key (type and base64, one line)"]]
	}
	if {![field_ok $principal] || ![field_ok $ns]} {
		return [dict merge $out [dict create \
			reason "the signature identity and namespace must not contain spaces"]]
	}
	dict set out fingerprint [fingerprint $key]
	set adir [file tempfile apath] ; close $adir
	set sf   [file tempfile spath] ; close $sf
	set df   [file tempfile dpath] ; close $df
	set rc [catch {
		# One principal, one key. `-n` below enforces the namespace, so the file
		# carries no `namespaces=` option.
		_spit $apath "$principal $key\n"
		_spit $spath $sig
		_spit $dpath $data
		_run [list $tool -Y verify -f $apath -I $principal -n $ns -s $spath] $dpath
	} r]
	file delete $apath $spath $dpath
	if {$rc} {
		return [dict merge $out [dict create available 0 \
			reason "couldn't run ssh-keygen on the core's host: $r"]]
	}
	set err [string trim [dict get $r stderr]]
	set sout [string trim [dict get $r stdout]]
	# OpenSSH older than 8.0 has no -Y: a version problem, not a bad signature.
	if {[string match -nocase "*unknown option*" $err] || [string match -nocase "*usage:*sign*" $err]} {
		return [dict merge $out [dict create available 0 \
			reason "the ssh-keygen on the core's host is older than OpenSSH 8.0 and can't verify signatures"]]
	}
	# Both: exit 0 and ssh-keygen's "Good" for this namespace. Neither alone
	# is a verdict.
	if {[dict get $r exitcode] == 0 && [regexp "^Good \"$ns\" signature" $sout]} {
		set fp ""
		regexp {(SHA256:[A-Za-z0-9+/=]+)} $sout -> fp
		return [dict merge $out [dict create verified 1 signer $fp]]
	}
	# A wrong key exits non-zero with nothing on stderr, hence the fallbacks:
	# a refusal always carries a reason.
	set why $err
	if {$why eq ""} { set why $sout }
	if {$why eq ""} { set why "ssh-keygen refused the signature (exit [dict get $r exitcode])" }
	return [dict merge $out [dict create reason $why]]
}
