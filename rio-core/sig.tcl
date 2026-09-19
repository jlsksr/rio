# rio-core — verifying an OpenSSH detached signature (AGENTS.md D118).
#
# The primitive behind signed extension repositories: a publisher signs one root
# SHA256SUMS with an ed25519 SSH key, as git does, and rio checks it by running
# the same tool the publisher used —
#
#   ssh-keygen -Y sign   -f key -n rio-repository SHA256SUMS      (publisher)
#   ssh-keygen -Y verify -f <allowed_signers> -I <principal> \
#              -n rio-repository -s SHA256SUMS.sig < SHA256SUMS   (here)
#
# Why the tool and not Tcl: rio would otherwise own Ed25519 and SHA-512, which is
# the heavier and less POSIX road (decided with jka 2026-09-16, revised from an
# earlier pure-Tcl sketch). OpenSSH is on every host rio targets. It lives CORE-side
# for the same reason tcltls does (D30): the core's host is where the tool must be,
# and a GUI-only box stays Tk-and-nothing-else.
#
# WITHOUT ssh-keygen NOTHING CAN BE VERIFIED, and this says so as its own answer
# (`available 0`) rather than as a failed signature — the caller's policy decides
# what that means, and the two must never be confused.
#
# `-Y verify` arrived in OpenSSH 8.0 (2019). Older ones — Windows 10 1809 shipped
# 7.7 — report an unknown option, which is reported as the version problem it is
# (CAVEATS.md, WINDOWS.md §9), not as a bad signature.
#
# THE PRINCIPAL IS A LOOKUP KEY, NOT A CLAIM. `-I` selects a line in the
# allowed-signers file, and rio writes that file itself, with one line, from the key
# it already trusts — so the principal contributes nothing to the verdict (verified
# 2026-09-19: the same signature verifies under any principal we care to write).
# What the verdict rests on is the KEY and the NAMESPACE: a signature made for git
# (`-n git`) or for ssh authentication fails here, and a signature by any other key
# fails here.
#
# EXACT BYTES, EVERYWHERE. A signature covers bytes, so nothing in this file may
# re-encode anything by accident: the data and the signature are written to temp
# files as raw UTF-8 and handed to the child as file redirections. `exec << $string`
# would encode with the SYSTEM encoding — cp1252 on Windows — and quietly produce a
# different message than the one that was signed. That is also why this does not use
# rio::exec::run, which is a `<< stdin` interface by design; the plumbing below is
# its pattern (argv, never a shell; temp files; the exit code out of -errorcode).

namespace eval rio::sig {
	variable _tool     ""   ;# cached path to ssh-keygen ("" = none), see tool
	variable _searched 0
	variable namespace_default rio-repository
}

# Where ssh-keygen is, or "" — looked up once. A core that starts before OpenSSH is
# installed and is then told to verify would keep saying no, which is why this is
# only cached after a HIT: the miss stays cheap to re-ask (auto_execok is a PATH
# walk, not a spawn) and the answer can improve without a restart.
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

# A public key as a repository publishes it: TYPE and base64, one line, nothing
# else. Anything else is refused BEFORE it reaches a file — an embedded newline
# would otherwise smuggle extra principals into the allowed-signers file we write,
# and that file is the whole of the trust decision.
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
		# One principal, one key, and the namespace bound to it: the file IS the
		# trust decision, so it says exactly what rio decided and nothing more.
		_spit $apath "$principal namespaces=\"$ns\" $key\n"
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
	# OpenSSH older than 8.0 has no -Y at all. That is a version problem, not a
	# signature problem, and must never be reported as one.
	if {[string match -nocase "*unknown option*" $err] || [string match -nocase "*usage:*sign*" $err]} {
		return [dict merge $out [dict create available 0 \
			reason "the ssh-keygen on the core's host is older than OpenSSH 8.0 and can't verify signatures"]]
	}
	if {[dict get $r exitcode] == 0 && [regexp "^Good \"$ns\" signature" $sout]} {
		set fp ""
		regexp {(SHA256:[A-Za-z0-9+/=]+)} $sout -> fp
		return [dict merge $out [dict create verified 1 signer $fp]]
	}
	# A wrong key exits non-zero with NOTHING on stderr (verified 2026-09-19), so
	# the fallbacks matter: a refusal always carries a reason.
	set why $err
	if {$why eq ""} { set why $sout }
	if {$why eq ""} { set why "ssh-keygen refused the signature (exit [dict get $r exitcode])" }
	return [dict merge $out [dict create reason $why]]
}
