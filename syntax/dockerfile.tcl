# rio — a Dockerfile syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no
# external packages — a per-line scanner (see rio::syntax for the contract). Dockerfiles
# are line-oriented (instructions continue with a trailing `\`, but colouring is
# line-local), so this carries no scan state. Registered by whole basename (`Dockerfile`,
# so `Dockerfile.prod` matches via the rootname fallback, D46) and by the `.dockerfile`
# extension (for `web.dockerfile`-style names).
#
# It colours: `#` comments as `comment` (a leading `# syntax=…` / `# escape=…` parser
# directive as `meta`); the instruction that opens a line (`FROM`, `RUN`, `COPY`, …,
# case-insensitive) as `keyword`, plus the `AS` of a `FROM … AS name` and the `ONBUILD`
# prefix's following instruction; `"…"` / `'…'` strings as `string`; `$VAR` / `${VAR}`
# expansions as `variable`; and numbers as `number`.

namespace eval rio::syntax::dockerfile {}

# The instruction set → `keyword` (first word of a line; matched case-insensitively).
set rio::syntax::dockerfile::instructions {
	from run cmd label maintainer expose env add copy entrypoint volume user
	workdir arg onbuild stopsignal healthcheck shell
}

# scan ONE line (state unused — Dockerfiles are line-local). Returns {spans "" ""}.
proc rio::syntax::dockerfile::scan {line state param} {
	variable instructions
	set spans {}
	set n [string length $line]
	set lead [expr {$n - [string length [string trimleft $line " \t"]]}]

	# --- a whole-line comment (or a parser directive) ------------------------------
	if {$lead < $n && [string index $line $lead] eq "#"} {
		set type comment
		if {[regexp -nocase {^#[ \t]*(syntax|escape|check)[ \t]*=} $line]} { set type meta }
		return [list [list $lead $n $type] "" ""]
	}

	# --- the leading instruction (and ONBUILD's wrapped instruction) ---------------
	set i $lead
	if {[regexp -indices {^[ \t]*([A-Za-z]+)} $line _ w]} {
		lassign $w a b
		set word [string tolower [string range $line $a $b]]
		if {[lsearch -exact $instructions $word] >= 0} {
			lappend spans $a [expr {$b + 1}] keyword ; set i [expr {$b + 1}]
			if {$word eq "onbuild" && [regexp -indices {^[ \t]*([A-Za-z]+)} [string range $line $i end] _ w2]} {
				lassign $w2 a2 b2
				set w2word [string tolower [string range $line [expr {$i + $a2}] [expr {$i + $b2}]]]
				if {[lsearch -exact $instructions $w2word] >= 0} {
					lappend spans [expr {$i + $a2}] [expr {$i + $b2 + 1}] keyword
					set i [expr {$i + $b2 + 1}]
				}
			}
		}
	}

	# --- the rest of the line: strings, expansions, the AS keyword, numbers --------
	while {$i < $n} {
		set ch [string index $line $i]
		set sub [string range $line $i end]
		set prev [string index $line [expr {$i - 1}]]
		set atword [expr {$i == 0 || [string is space $prev]}]
		if {$ch eq "#" && $atword} {
			lappend spans $i $n comment ; set i $n
		} elseif {$ch eq "\"" || $ch eq "'"} {
			set j [_strend $line $ch [expr {$i + 1}]]
			set e [expr {$j < 0 ? $n : $j + 1}]
			lappend spans $i $e string ; set i $e
		} elseif {$ch eq "\$"} {
			if {[regexp -indices {^\$\{[^\}]*\}} $sub m] || [regexp -indices {^\$[A-Za-z_][A-Za-z0-9_]*} $sub m]} {
				set len [expr {[lindex $m 1] + 1}]
				lappend spans $i [expr {$i + $len}] variable ; incr i $len
			} else { incr i }
		} elseif {$atword && [regexp -indices {^[Aa][Ss]\y} $sub m]} {
			lappend spans $i [expr {$i + 2}] keyword ; incr i 2
		} elseif {$atword && [string match {[0-9]} $ch]} {
			regexp -indices {^[0-9]+} $sub m
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] number ; incr i $len
		} else {
			incr i
		}
	}
	return [list $spans "" ""]
}

# The index of the closing quote `q` for a string beginning at column i; -1 if it does not
# close on this line. Honours `\` escapes.
proc rio::syntax::dockerfile::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Dockerfile {dockerfile} rio::syntax::dockerfile::scan
rio::syntax::register_filename Dockerfile {Dockerfile Containerfile} \
	rio::syntax::dockerfile::scan
