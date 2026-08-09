# rio — a TOML syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so a `"""…"""` / `'''…'''` multi-line string colours
# as one unit.
#
# It colours: `#` comments (outside strings) as `comment`; table headers `[table]` and
# array-of-tables `[[table]]` (the whole bracketed form) as `type`; a `key =` /
# `dotted.key =` / quoted-key assignment target as `attribute`; basic `"…"` and literal
# `'…'` strings, and their triple-quoted multi-line forms, as `string`; integers (with
# `_` groupings and `0x`/`0o`/`0b` bases), floats, and `inf`/`nan` as `number`;
# `true`/`false` as `constant`; and RFC-3339 dates/times as `constant`. Structural
# punctuation (`= , { } [ ]` outside a header) stays plain.
#
# Scoped: keys INSIDE an inline table (`{ a = 1 }`) or the header-name dots are not
# separately coloured — the common top-level `key =` case is what reads apart. Pure: no
# Tk here — tests headless under tclsh.

namespace eval rio::syntax::toml {}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: ""
# (normal) | mlbasic (inside """) | mlliteral (inside '''). The START state "" is normal.
proc rio::syntax::toml::scan {line state param} {
	set spans {}
	set n [string length $line]
	set i 0

	# --- continue a multi-line string opened on an earlier line ----------------
	if {$state eq "mlbasic" || $state eq "mlliteral"} {
		set close [expr {$state eq "mlbasic" ? {"""} : {'''}}]
		set k [string first $close $line $i]
		if {$k < 0} {
			if {$n > 0} { lappend spans $i $n string }
			return [list $spans $state $param]
		}
		lappend spans $i [expr {$k + 3}] string
		set i [expr {$k + 3}]
		set state ""
		# fall through: the rest of this line is ordinary content
	} else {
		# --- structural line head: a table header, or a key= assignment --------
		if {[regexp -indices {^[ \t]*(\[\[?[^\]]*\]?\])} $line whole hdr]} {
			lappend spans [lindex $hdr 0] [expr {[lindex $hdr 1] + 1}] type
			set i [expr {[lindex $hdr 1] + 1}]
		} elseif {[regexp -indices \
			{^[ \t]*((?:[A-Za-z0-9_.-]+|"[^"]*"|'[^']*')(?:[ \t]*\.[ \t]*(?:[A-Za-z0-9_.-]+|"[^"]*"|'[^']*'))*)[ \t]*=} \
			$line whole key]} {
			lappend spans [lindex $key 0] [expr {[lindex $key 1] + 1}] attribute
			# resume after the '=' (whole match end), so the value region tokenises next
			set i [expr {[lindex $whole 1] + 1}]
		}
	}

	# --- value region: strings, comments, numbers, constants ------------------
	lassign [_tokvalue $line $i $spans] spans state
	return [list $spans $state $param]
}

# Tokenise `line` from column `i` to its end as a TOML value region, appending to
# `spans`. Returns {spans nextstate}: nextstate is mlbasic/mlliteral if a triple-quoted
# string opened here and did not close on this line, else "".
proc rio::syntax::toml::_tokvalue {line i spans} {
	set n [string length $line]
	while {$i < $n} {
		set ch  [string index $line $i]
		set sub [string range $line $i end]
		if {$ch eq "#"} {
			lappend spans $i $n comment ; set i $n
		} elseif {[string range $line $i [expr {$i + 2}]] eq {"""}} {
			set k [string first {"""} $line [expr {$i + 3}]]
			if {$k < 0} { lappend spans $i $n string ; return [list $spans mlbasic] }
			lappend spans $i [expr {$k + 3}] string ; set i [expr {$k + 3}]
		} elseif {[string range $line $i [expr {$i + 2}]] eq {'''}} {
			set k [string first {'''} $line [expr {$i + 3}]]
			if {$k < 0} { lappend spans $i $n string ; return [list $spans mlliteral] }
			lappend spans $i [expr {$k + 3}] string ; set i [expr {$k + 3}]
		} elseif {$ch eq "\""} {
			set j [_strend $line [expr {$i + 1}] \" 1]
			set e [expr {$j < 0 ? $n : $j + 1}]
			lappend spans $i $e string ; set i $e
		} elseif {$ch eq "'"} {
			set j [_strend $line [expr {$i + 1}] ' 0]
			set e [expr {$j < 0 ? $n : $j + 1}]
			lappend spans $i $e string ; set i $e
		} elseif {[regexp -indices {^\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[-+]\d{2}:\d{2})?)?} $sub m] \
				|| [regexp -indices {^\d{2}:\d{2}:\d{2}(\.\d+)?} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] constant ; incr i $len
		} elseif {[regexp -indices {^[-+]?(?:0[xob][0-9A-Fa-f_]+|(?:inf|nan)|(?:0|[1-9][0-9_]*)(?:\.[0-9_]+)?(?:[eE][-+]?[0-9_]+)?)} $sub m] \
				&& [_isnumstart $line $i]} {
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] number ; incr i $len
		} elseif {[regexp -indices {^(?:true|false)\M} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] constant ; incr i $len
		} else {
			incr i
		}
	}
	return [list $spans ""]
}

# A number token must start at a value boundary — not in the middle of a bare word (so
# the `4` in `key4` never lights up). True when the preceding char is absent or not a
# bare-key character.
proc rio::syntax::toml::_isnumstart {line i} {
	if {$i == 0} { return 1 }
	return [expr {![string match {[A-Za-z0-9_-]} [string index $line [expr {$i - 1}]]]}]
}

# The index of the closing quote `q` for a string beginning after column `i`; -1 if it
# does not close on this line. `esc` honours `\` escapes (basic strings) vs. literal.
proc rio::syntax::toml::_strend {line i q esc} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$esc && $ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register TOML {toml} rio::syntax::toml::scan
