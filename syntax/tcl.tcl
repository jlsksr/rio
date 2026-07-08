# rio — a Tcl/Tk syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no
# external packages — a linear, per-line state machine (see rio::syntax for the
# contract). It carries its scan state across lines, so double-quoted strings that
# span lines colour correctly. (This is the highlighter for rio's own source.)
#
# Tcl's two famous gotchas drive the design:
#   * `#` is a comment ONLY in command position (start of a command) — mid-command it
#     is an ordinary character. We track command position and only start a comment
#     there, so `puts "x" # y` does not lose its tail to a phantom comment.
#   * braces `{ … }` are grouping/quoting, not a string — their body is usually CODE
#     (a proc body, an `if` script). So braces are left as plain punctuation and the
#     scanner keeps tokenising inside them; a proc body highlights like any other code.
#
# It colours: `#` comments as `comment`; `$var`, `${var}`, `$arr(i)`, `$ns::var` as
# `variable`; `"…"` strings (multi-line) as `string`; numbers as `number`; core Tcl/Tk
# command words — but only in command position — as `keyword`, with `else`/`elseif`
# always coloured (they read as arguments to `if`); a `proc` NAME as `function`; and
# `-option` flags as `attribute`. Command substitution `[ … ]` re-enters command
# position, so `[llength $x]` colours `llength`. Barewords that are not known commands
# (proc calls, argument words) are left plain — Tcl can't tell them apart without
# running, so we don't guess. `$var`/`[cmd]` interpolation inside a "…" string is not
# separately coloured (the whole string is one span) — a possible later refinement.

namespace eval rio::syntax::tcl {}

# Core commands → `keyword`, coloured only in command position (so `set list 5` leaves
# the *variable* `list` plain). A curated core + the common Tk layout/binding verbs.
set rio::syntax::tcl::commands {
	set unset proc return break continue
	if while for foreach switch
	eval uplevel upvar global variable namespace my self next
	catch try finally throw error
	expr incr append lappend lset lreplace linsert lassign lmap lrepeat lreverse
	list lindex llength lrange lsearch lsort dict array string format scan
	regexp regsub split join subst concat
	source package require load info interp
	after vwait update trace rename apply tailcall coroutine yield yieldto
	open close read gets puts flush eof seek tell chan fblocked fcopy
	exec cd pwd file glob fconfigure fileevent socket
	clock encoding exit binary time
	pack grid place bind winfo wm event focus destroy bell grab tkwait
}
# Control words that appear as *arguments* (to `if`) yet read as keywords → always.
set rio::syntax::tcl::always {else elseif}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a
# flat {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract).
# States: text | str (inside a multi-line "…" string). The START state "" falls
# through to the text arm. Command position and the `proc`-name pending flag are
# per-line locals, not carried state.
proc rio::syntax::tcl::scan {line state param} {
	variable commands
	variable always
	set spans {}
	set n [string length $line]
	set i 0
	set cmd 1     ;# at command position (start of a command)?
	set pend ""   ;# after `proc`, the next word is the proc name
	while {$i < $n} {
		if {$state eq "str"} {
			# Consume to the closing quote, honouring backslash escapes; carry if open.
			set s0 $i ; set done 0
			while {$i < $n} {
				set c [string index $line $i]
				if {$c eq "\\"} { incr i 2 ; continue }
				if {$c eq "\""} { incr i ; set done 1 ; break }
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
		set atstart [expr {$i == 0 || [string is space $prevc] \
			|| $prevc eq "\{" || $prevc eq "\[" || $prevc eq ";"}]
		if {$ch eq "#" && $cmd} {
			lappend spans $i $n comment ; set i $n
		} elseif {$ch eq "\""} {
			lappend spans $i [expr {$i + 1}] string ; incr i ; set state str
		} elseif {$ch eq "\$"} {
			set len [_var $sub]
			if {$len > 0} {
				lappend spans $i [expr {$i + $len}] variable ; incr i $len ; set cmd 0 ; set pend ""
			} else {
				incr i ; set cmd 0   ;# a literal `$`
			}
		} elseif {$ch eq "\{"} {
			incr i ; set cmd 1 ; set pend ""
		} elseif {$ch eq "\["} {
			incr i ; set cmd 1 ; set pend ""
		} elseif {$ch eq "\}" || $ch eq "\]"} {
			incr i ; set cmd 0
		} elseif {$ch eq ";"} {
			incr i ; set cmd 1 ; set pend ""
		} elseif {$ch eq "\\"} {
			incr i 2 ; set cmd 0   ;# escaped char (or line-continuation at EOL)
		} elseif {$ch eq "-" && $atstart && [regexp -indices {^-[[:alpha:]][[:alnum:]_-]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] attribute ; incr i $len ; set cmd 0
		} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
			regexp -indices {^(?:0[xX][[:xdigit:]]+|0[bB][01]+|0[oO][0-7]+|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)} $sub m
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] number ; incr i $len ; set cmd 0 ; set pend ""
		} elseif {[regexp -indices {^[[:alpha:]_][[:alnum:]_]*(?:::[[:alnum:]_]+)*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			set word [string range $line $i [expr {$i + $len - 1}]]
			if {$pend ne ""} {
				lappend spans $i [expr {$i + $len}] function ; set pend ""
			} elseif {[lsearch -exact $always $word] >= 0} {
				lappend spans $i [expr {$i + $len}] keyword
			} elseif {$cmd && [lsearch -exact $commands $word] >= 0} {
				lappend spans $i [expr {$i + $len}] keyword
				if {$word eq "proc"} { set pend proc }
			}
			incr i $len ; set cmd 0
		} else {
			if {![string is space $ch]} { set cmd 0 ; set pend "" }
			incr i
		}
	}
	return [list $spans $state $param]
}

# Length of a Tcl variable reference at the START of `sub` (which begins with `$`), or
# 0 for a literal `$` (a `$` not followed by a name or a `{…}`). Handles ${name},
# $ns::name, and an $arr(index) subscript.
proc rio::syntax::tcl::_var {sub} {
	if {[regexp -indices {^\$\{[^\}]*\}} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	if {[regexp -indices {^\$(?:::)?[[:alnum:]_]+(?:::[[:alnum:]_]+)*(?:\([^\)]*\))?} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	return 0
}

rio::syntax::register Tcl {tcl tm test itcl tk} rio::syntax::tcl::scan
