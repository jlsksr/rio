# rio — a YAML syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so a `|` / `>` block scalar colours its indented body
# as one `string` unit.
#
# It colours: `#` comments (at line start or after whitespace, so a `#` inside a value or
# string stays literal) as `comment`; a mapping `key:` (colon followed by space or
# end-of-line, plain or quoted) as `attribute`; `'…'` and `"…"` scalars as `string`;
# `&anchor` / `*alias` as `variable` and `!tag` / `!!type` as `type`; the document
# markers `---` / `...` as `meta`; the booleans/null vocabulary (`true`/`false`/`yes`/
# `no`/`on`/`off`/`null`/`~`, any case) as `constant`; and numbers. A `|` or `>` block
# indicator opens a block scalar whose more-indented body colours as `string`.
#
# Scoped: a plain scalar's individual words are still lit if they look like a
# constant/number (`key: true story` lights `true`) — the common one-value-per-key case
# reads right; and a quoted scalar that spans lines is not carried (rare). Pure: no Tk
# here — tests headless under tclsh.

namespace eval rio::syntax::yaml {}

# The boolean / null vocabulary (matched as whole words, case-insensitively).
set rio::syntax::yaml::constants {
	true false yes no on off null ~ y n
}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: ""
# (normal) | block (inside a |/> block scalar; `param` is the indent of the block's key
# line — a body line must be indented MORE, else the block ends). START "" is normal.
proc rio::syntax::yaml::scan {line state param} {
	set spans {}
	set n [string length $line]

	# --- continue a block scalar ----------------------------------------------
	if {$state eq "block"} {
		if {[regexp {^[ \t]*$} $line]} { return [list {} block $param] }  ;# blank stays in
		set ind [expr {[string length $line] - [string length [string trimleft $line { }]]}]
		if {$ind > $param} {
			if {$n > 0} { lappend spans 0 $n string }
			return [list $spans block $param]
		}
		set state ""   ;# dedented: the block ended — fall through and scan normally
	}

	set lead [expr {[string length $line] - [string length [string trimleft $line { }]]}]
	set i $lead

	# --- document markers ------------------------------------------------------
	if {[regexp {^(---|\.\.\.)([ \t]|$)} [string range $line $i end]]} {
		lappend spans $i [expr {$i + 3}] meta ; incr i 3
	}

	# --- leading block-sequence markers "- " (possibly several, nested) --------
	while {[string range $line $i [expr {$i + 1}]] eq "- "} { incr i 2 }

	# --- a mapping key: `scalar:` (colon then space or EOL) --------------------
	set rem [string range $line $i end]
	if {[regexp -indices {^((?:"[^"]*"|'[^']*'|[^:#]+?))[ \t]*(:)(?:[ \t]|$)} $rem km g1 g2]} {
		lappend spans [expr {$i + [lindex $g1 0]}] [expr {$i + [lindex $g1 1] + 1}] attribute
		set i [expr {$i + [lindex $g2 1] + 1}]   ;# resume just after the colon
	}

	# --- the value / scalar region --------------------------------------------
	lassign [_tokvalue $line $i $lead $spans] spans state param
	return [list $spans $state $param]
}

# Tokenise `line` from column `i` to end as a YAML value region, appending to `spans`.
# `lead` is the line's indent (the threshold a block scalar body must beat). Returns
# {spans nextstate nextparam}: "block"/`lead` if a |/> block scalar opened here, else "".
proc rio::syntax::yaml::_tokvalue {line i lead spans} {
	variable constants
	set n [string length $line]
	while {$i < $n} {
		set ch   [string index $line $i]
		set sub  [string range $line $i end]
		set prev [string index $line [expr {$i - 1}]]
		set atbound [expr {$i == $lead || [string is space $prev] \
			|| [string first $prev "-\[\{,:"] >= 0}]
		if {$ch eq "#" && ($i == 0 || [string is space $prev])} {
			lappend spans $i $n comment ; set i $n
		} elseif {$ch eq "'" || $ch eq "\""} {
			set j [_strend $line [expr {$i + 1}] $ch [expr {$ch eq "\""}]]
			set e [expr {$j < 0 ? $n : $j + 1}]
			lappend spans $i $e string ; set i $e
		} elseif {($ch eq "&" || $ch eq "*") && [regexp -indices {^[&*][^ \t,\]\}]+} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] variable ; incr i $len
		} elseif {$ch eq "!" && [regexp -indices {^![^ \t]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] type ; incr i $len
		} elseif {($ch eq "|" || $ch eq ">") && [regexp {^[|>][+-]?[0-9]?[ \t]*(#.*)?$} $sub]} {
			# A block-scalar indicator that ends the line: the indented body follows.
			return [list $spans block $lead]
		} elseif {$atbound && [regexp -indices {^[[:alpha:]~][[:alnum:]_]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			set word [string range $line $i [expr {$i + $len - 1}]]
			set nx [string index $line [expr {$i + $len}]]
			if {[lsearch -exact -nocase $constants $word] >= 0 \
					&& ($nx eq "" || [string is space $nx] || [string first $nx ",\]\}"] >= 0)} {
				lappend spans $i [expr {$i + $len}] constant
			}
			incr i $len
		} elseif {$atbound && [regexp -indices {^[-+]?[0-9][0-9_]*(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			set nx [string index $line [expr {$i + $len}]]
			if {$nx eq "" || [string is space $nx] || [string first $nx ",\]\}"] >= 0} {
				lappend spans $i [expr {$i + $len}] number
			}
			incr i $len
		} else {
			incr i
		}
	}
	return [list $spans "" ""]
}

# The index of the closing quote `q` for a string beginning after column `i`; -1 if it
# does not close on this line. `esc` honours `\` escapes (double-quoted) vs. literal.
proc rio::syntax::yaml::_strend {line i q esc} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$esc && $ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register YAML {yaml yml} rio::syntax::yaml::scan
