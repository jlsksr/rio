# rio — a POSIX shell / Bash syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no
# I/O, no external packages — a linear, per-line state machine (see rio::syntax for
# the contract). It carries its scan state across lines, so quoted strings that span
# lines colour correctly. (This is the highlighter for rio's own *.sh deploy scripts.)
#
# Like the Tcl highlighter, a bareword's meaning is positional, so the design tracks
# COMMAND POSITION (start of a command). It colours: `#` comments (only at word start,
# so `$#` and `foo#bar` are safe) as `comment`; `'…'`, `"…"`, `$'…'` strings and
# `` `…` `` command substitution as `string`, all multi-line; `$var`, `${…}`, and the
# special parameters (`$1 $@ $# $? $$ $! $* $0`) as `variable`; a `NAME=` assignment
# target as `variable`; reserved words (if/then/for/…) and shell builtins as `keyword`,
# and any OTHER command-position word (the command being run) as `function`; `-x` /
# `--long` options as `attribute`; and numbers. A `$( … )` / `$(( … ))` substitution is
# NOT swallowed — the `$` is left plain and the body is scanned as ordinary shell, so
# the inner command colours too.

namespace eval rio::syntax::shell {}

# Reserved words → `keyword`.
set rio::syntax::shell::keywords {
	if then else elif fi for while until do done case esac in
	function select time coproc
}
# Builtins → `keyword` (distinct from external command names, which get `function`).
set rio::syntax::shell::builtins {
	echo printf read cd pwd pushd popd dirs
	export local readonly declare typeset set unset shift getopts
	return exit break continue eval exec trap wait
	test source alias unalias let true false type command builtin
	kill jobs bg fg umask ulimit hash times enable
}
# Reserved words after which a COMMAND follows (so the next word colours as one).
set rio::syntax::shell::cmdafter {then do else if elif while until}
# Chars that put us back in command position when they precede a word.
set rio::syntax::shell::seps ";&|(){"

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a
# flat {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract).
# States: text | str (inside a multi-line quoted string / backtick). The START state
# "" falls through to the text arm. Command position is a per-line local.
proc rio::syntax::shell::scan {line state param} {
	variable keywords
	variable builtins
	variable cmdafter
	variable seps
	set spans {}
	set n [string length $line]
	set i 0
	set cmd 1
	while {$i < $n} {
		if {$state eq "str"} {
			set q [dict get $param q]
			set esc [dict get $param esc]
			set s0 $i ; set done 0
			while {$i < $n} {
				set c [string index $line $i]
				if {$esc && $c eq "\\"} { incr i 2 ; continue }
				if {$c eq $q} { incr i ; set done 1 ; break }
				incr i
			}
			set e [expr {$i > $n ? $n : $i}]
			if {$e > $s0} { lappend spans $s0 $e string }
			if {$done} { set state text ; set cmd 0 }
			continue
		}
		set ch [string index $line $i]
		set sub [string range $line $i end]
		set prevc [string index $line [expr {$i - 1}]]
		set atword [expr {$i == 0 || [string is space $prevc] || [string first $prevc $seps] >= 0}]
		if {$ch eq "#" && $atword} {
			lappend spans $i $n comment ; set i $n
		} elseif {$ch eq "'"} {
			lappend spans $i [expr {$i + 1}] string ; incr i
			set state str ; set param [dict create q ' esc 0]
		} elseif {$ch eq "\""} {
			lappend spans $i [expr {$i + 1}] string ; incr i
			set state str ; set param [dict create q \" esc 1]
		} elseif {$ch eq "`"} {
			lappend spans $i [expr {$i + 1}] string ; incr i
			set state str ; set param [dict create q ` esc 1]
		} elseif {$ch eq "\$" && [string index $line [expr {$i + 1}]] eq "'"} {
			lappend spans $i [expr {$i + 2}] string ; incr i 2
			set state str ; set param [dict create q ' esc 1]
		} elseif {$ch eq "\$"} {
			set len [_var $sub]
			if {$len > 0} {
				lappend spans $i [expr {$i + $len}] variable ; incr i $len ; set cmd 0
			} else {
				incr i   ;# $( … ) / $(( … )) / a literal $: leave the $ plain
			}
		} elseif {[string first $ch $seps] >= 0} {
			incr i ; set cmd 1
		} elseif {$ch eq "\}" || $ch eq ")"} {
			incr i ; set cmd 0
		} elseif {$ch eq "\\"} {
			incr i 2
		} elseif {$atword && [regexp -indices {^--?[[:alpha:]][[:alnum:]_-]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] attribute ; incr i $len ; set cmd 0
		} elseif {[string match {[0-9]} $ch]} {
			regexp -indices {^[0-9]+} $sub m
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] number ; incr i $len ; set cmd 0
		} elseif {[regexp -indices {^[[:alpha:]_][[:alnum:]_]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			set word [string range $line $i [expr {$i + $len - 1}]]
			set nx [string index $line [expr {$i + $len}]]
			set nx2 [string index $line [expr {$i + $len + 1}]]
			if {($nx eq "=" && $nx2 ne "=") || ($nx eq "+" && $nx2 eq "=")} {
				lappend spans $i [expr {$i + $len}] variable   ;# NAME= assignment target
				set cmd 0
			} elseif {[lsearch -exact $keywords $word] >= 0} {
				lappend spans $i [expr {$i + $len}] keyword
				set cmd [expr {[lsearch -exact $cmdafter $word] >= 0}]
			} elseif {$cmd && [lsearch -exact $builtins $word] >= 0} {
				lappend spans $i [expr {$i + $len}] keyword ; set cmd 0
			} elseif {$cmd} {
				lappend spans $i [expr {$i + $len}] function ; set cmd 0
			} else {
				set cmd 0
			}
			incr i $len
		} else {
			if {![string is space $ch]} { set cmd 0 }
			incr i
		}
	}
	return [list $spans $state $param]
}

# Length of a shell parameter expansion at the START of `sub` (begins with `$`), or 0
# for `$(`/`$((` (command/arithmetic substitution — scanned as code, not swallowed) and
# a literal `$`. Handles ${…}, $name, and the special parameters.
proc rio::syntax::shell::_var {sub} {
	if {[regexp -indices {^\$\{[^\}]*\}} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	if {[string index $sub 1] eq "("} { return 0 }
	if {[regexp -indices {^\$[[:alpha:]_][[:alnum:]_]*} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	if {[regexp -indices {^\$[-@#?$!*0-9]} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	return 0
}

rio::syntax::register Shell {sh bash zsh ksh ash} rio::syntax::shell::scan
