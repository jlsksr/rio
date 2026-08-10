# rio — a Windows Batch / cmd syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no
# I/O, no external packages — a per-line scanner (see rio::syntax for the contract). Batch
# is line-oriented (no multi-line strings), so this carries no scan state. Batch is
# case-INSENSITIVE, so keyword lookups lower-case the word first.
#
# It colours: a `REM …` comment and a `::` line comment as `comment`; a `:label` at the
# start of a line as `function` (a goto/call target); `%VAR%`, `%1`…`%9`, `%*`, `%%i`, and
# delayed-expansion `!VAR!` as `variable`; the statement / built-in commands (`if`, `for`,
# `goto`, `set`, `echo`, `call`, …) as `keyword`; the comparison operators (`EQU`, `NEQ`,
# `exist`, `defined`, …) as `operator`; `"…"` strings as `string`; and numbers. A leading
# `@` (as in `@echo off`) is coloured `operator`.

namespace eval rio::syntax::batch {}

# Statement / built-in commands → `keyword` (matched case-insensitively).
set rio::syntax::batch::keywords {
	if else for goto call set setlocal endlocal echo exit shift pause rem
	cd chdir dir copy xcopy del erase md mkdir rd rmdir move ren rename type
	cls pushd popd start title color prompt path assoc ftype find findstr
	sort more attrib mode ver date time break choice cmd where
}
# Operator words → `operator` (comparisons and the `for`/`if` sub-keywords).
set rio::syntax::batch::operators {
	equ neq lss leq gtr geq not exist defined in do errorlevel
}

# scan ONE line (state unused — Batch is line-local). Returns {spans "" ""}.
proc rio::syntax::batch::scan {line state param} {
	variable keywords
	variable operators
	set spans {}
	set n [string length $line]
	set lead [expr {$n - [string length [string trimleft $line " \t"]]}]

	# --- a `::` line comment, or a `:label` --------------------------------------
	if {[string range $line $lead [expr {$lead + 1}]] eq "::"} {
		return [list [list $lead $n comment] "" ""]
	}
	if {$lead < $n && [string index $line $lead] eq ":"} {
		return [list [list $lead $n function] "" ""]
	}

	set i 0
	set cmd 1   ;# at the start of a command? (drives keyword vs plain classification)
	while {$i < $n} {
		set ch [string index $line $i]
		set sub [string range $line $i end]
		set prev [string index $line [expr {$i - 1}]]
		set atword [expr {$i == 0 || [string is space $prev] || $prev eq "(" || $prev eq "&" || $prev eq "|"}]
		if {$ch eq "@" && $i == $lead} {
			lappend spans $i [expr {$i + 1}] operator ; incr i
		} elseif {$ch eq "\""} {
			set j [string first "\"" $line [expr {$i + 1}]]
			set e [expr {$j < 0 ? $n : $j + 1}]
			lappend spans $i $e string ; set i $e ; set cmd 0
		} elseif {$ch eq "%"} {
			set len [_var $sub]
			if {$len > 0} { lappend spans $i [expr {$i + $len}] variable ; incr i $len ; set cmd 0 } else { incr i }
		} elseif {$ch eq "!"} {
			if {[regexp -indices {^![A-Za-z_][A-Za-z0-9_]*!} $sub m]} {
				set len [expr {[lindex $m 1] + 1}]
				lappend spans $i [expr {$i + $len}] variable ; incr i $len ; set cmd 0
			} else { incr i }
		} elseif {$ch eq "&" || $ch eq "|"} {
			incr i ; set cmd 1   ;# a command separator → back to command position
		} elseif {[string match {[0-9]} $ch] && $atword} {
			regexp -indices {^[0-9]+} $sub m
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] number ; incr i $len ; set cmd 0
		} elseif {[regexp -indices {^[A-Za-z_][A-Za-z0-9_]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			set word [string tolower [string range $line $i [expr {$i + $len - 1}]]]
			if {$cmd && $word eq "rem"} {
				lappend spans $i $n comment ; set i $n ; continue   ;# REM — the rest of the line
			} elseif {[lsearch -exact $operators $word] >= 0} {
				lappend spans $i [expr {$i + $len}] operator
			} elseif {$cmd && [lsearch -exact $keywords $word] >= 0} {
				lappend spans $i [expr {$i + $len}] keyword
			}
			set cmd 0
			incr i $len
		} else {
			if {![string is space $ch]} { set cmd 0 }
			incr i
		}
	}
	return [list $spans "" ""]
}

# Length of a %-expansion at the START of `sub` (begins with `%`), or 0 for a bare `%`.
# Handles %NAME%, %1..%9 / %* positional args, and %%i for-loop variables.
proc rio::syntax::batch::_var {sub} {
	if {[regexp -indices {^%[A-Za-z_][A-Za-z0-9_]*%} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	if {[regexp -indices {^%~[a-zA-Z]*[0-9]} $sub m]}         { return [expr {[lindex $m 1] + 1}] }
	if {[regexp -indices {^%[0-9*]} $sub m]}                  { return [expr {[lindex $m 1] + 1}] }
	if {[regexp -indices {^%%[A-Za-z]} $sub m]}              { return [expr {[lindex $m 1] + 1}] }
	return 0
}

rio::syntax::register Batch {bat cmd} rio::syntax::batch::scan
