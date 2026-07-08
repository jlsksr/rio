# rio — a Perl syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no
# external packages — a linear, per-line state machine (see rio::syntax for the
# contract). It carries its scan state across lines, so POD blocks, multi-line
# strings, and multi-line quote-like operators (m//, s///, qw(), …) colour correctly.
#
# Perl's grammar is famously not cleanly tokenisable, so this aims for a tasteful,
# low-risk subset — colour the things that are unambiguous and leave the rest plain
# rather than guess wrong:
#   comments (#…, but not the $# array-index sigil) and POD (=pod … =cut) as `comment`
#   sigil variables ($scalar @array %hash &sub, incl. $_, @_, $1, $!, ${…}, $#a) as `variable`
#   numbers (hex/oct/bin/float, _ separators) as `number`
#   declaration/control/named-operator words as `keyword`, common built-ins as `function`
#   package/class names (Foo::Bar) and a `sub`/`package` NAME as `type`/`function`
#   a bareword call `name(` as `function`
#   '…' "…" `…` strings, and the quote-like ops q qq qw qr qx m s tr y (the operator
#     word as `keyword`, the delimited body as `string`), with same-char (/…/) and
#     bracketed ((), [], {}, <>) delimiters, one- and two-part, and multi-line carry
# Deliberately NOT handled (honest gaps, so nothing is mis-coloured): here-docs
# (<<"EOF") and a bare /regex/ without a leading m — the `/` is indistinguishable
# from division without a real parser, so it reads as plain text. `__END__`/`__DATA__`
# ends highlighting for the rest of the file.

namespace eval rio::syntax::perl {}

# Declarations, control flow, and named operators → `keyword`.
set rio::syntax::perl::keywords {
	my our local state sub package use no require
	if elsif else unless while until for foreach do given when default
	return last next redo goto continue
	and or not xor eq ne lt gt le ge cmp x
	undef wantarray ref bless __PACKAGE__ __FILE__ __LINE__ __SUB__
}
# Common built-in functions → `function` (distinct hue from the control keywords).
set rio::syntax::perl::builtins {
	print printf say sprintf warn die
	push pop shift unshift splice
	keys values each exists delete
	map grep sort reverse join split
	chomp chop chr ord lc uc lcfirst ucfirst length substr index rindex
	open close read sysread syswrite binmode eof
	scalar defined
}
# The quote-like operator words and how many delimited sections each takes.
set rio::syntax::perl::quote1 {q qq qw qr qx m}    ;# one section:  q(…)  m/…/
set rio::syntax::perl::quote2 {s tr y}             ;# two sections: s/…/…/  tr/…/…/
# Chars that may NOT open a quote-like delimiter (fat-comma/list punctuation and the
# closing brackets — a `}`/`]` literal can't live in a braced proc body, so it lives
# here as a plain string that `_isdelim` searches).
set rio::syntax::perl::nondelim "=,;)]}>"

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a
# flat {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract).
# States: text | pod (=…=cut) | qopen (waiting to read a section's opening delimiter)
# | q (inside a quote-like/string section) | end (past __END__/__DATA__). The START
# state "" falls through to the text arm.
proc rio::syntax::perl::scan {line state param} {
	variable keywords
	variable builtins
	variable quote1
	variable quote2
	set spans {}
	set n [string length $line]
	set i 0

	# Whole-line states first (POD, __END__ tail) — they consume the entire line.
	if {$state eq "end"} { return [list {} end ""] }
	if {$state eq "pod"} {
		if {$n > 0} { lappend spans 0 $n comment }
		if {[string match "=cut*" $line]} { return [list $spans text ""] }
		return [list $spans pod ""]
	}
	if {($state eq "" || $state eq "text") && [regexp {^=[[:alpha:]]} $line]} {
		lappend spans 0 $n comment
		# =cut with no open POD is just a one-line directive; else we're now in POD.
		if {[string match "=cut*" $line]} { return [list $spans text ""] }
		return [list $spans pod ""]
	}

	set pend ""   ;# after `sub`/`package`, the next NAME gets function/type
	while {$i < $n} {
		switch -- $state {
			qopen {
				# Skip whitespace, then read the opening delimiter of the next section.
				while {$i < $n && [string is space [string index $line $i]]} { incr i }
				if {$i >= $n} break   ;# delimiter is on a later line
				set ch [string index $line $i]
				set open "" ; set close $ch
				switch -- $ch {
					"(" { set open ( ; set close ) }
					"\[" { set open \[ ; set close \] }
					"\{" { set open \{ ; set close \} }
					"<" { set open < ; set close > }
				}
				lappend spans $i [expr {$i + 1}] string ; incr i
				dict set param open $open ; dict set param close $close
				dict set param nest 1 ; set state q
			}
			q {
				set open  [dict get $param open]
				set close [dict get $param close]
				set s0 $i ; set done 0
				if {$open eq ""} {
					while {$i < $n} {
						set c [string index $line $i]
						if {$c eq "\\"} { incr i 2 ; continue }
						if {$c eq $close} { incr i ; set done 1 ; break }
						incr i
					}
				} else {
					set nest [dict get $param nest]
					while {$i < $n} {
						set c [string index $line $i]
						if {$c eq "\\"} { incr i 2 ; continue }
						if {$c eq $open}  { incr nest ; incr i ; continue }
						if {$c eq $close} { incr nest -1 ; incr i ; if {$nest == 0} { set done 1 ; break } ; continue }
						incr i
					}
					dict set param nest $nest
				}
				set e [expr {$i > $n ? $n : $i}]
				if {$e > $s0} { lappend spans $s0 $e string }
				if {$done} {
					set parts [expr {[dict get $param parts] - 1}]
					if {$parts <= 0} {
						set state text
					} elseif {$open eq ""} {
						dict set param parts $parts   ;# same-char: this delim opens section 2
					} else {
						dict set param parts $parts ; set state qopen
					}
				}
			}
			default {  ;# text
				set ch [string index $line $i]
				set sub [string range $line $i end]
				if {$ch eq "#"} {
					lappend spans $i $n comment ; set i $n
				} elseif {($ch eq "\"" || $ch eq "'" || $ch eq "`")} {
					set pend ""
					lappend spans $i [expr {$i + 1}] string ; incr i
					set param [dict create parts 1 open "" close $ch nest 0] ; set state q
				} elseif {$ch in {$ @ % &}} {
					set pend ""
					set len [_sigil $sub $ch]
					if {$len > 0} {
						lappend spans $i [expr {$i + $len}] variable ; incr i $len
					} else {
						incr i   ;# % modulo, & bit-and, bare $: an operator, left plain
					}
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[bB][01_]+|0[0-7_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?)} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]_][[:alnum:]_]*(?:::[[:alnum:]_]+)*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					set after [string index $line [expr {$i + $len}]]
					if {$pend ne ""} {
						lappend spans $i [expr {$i + $len}] [expr {$pend eq "sub" ? "function" : "type"}]
						set pend ""
					} elseif {$word eq "__END__" || $word eq "__DATA__"} {
						lappend spans $i [expr {$i + $len}] keyword ; set state end ; set i $n ; continue
					} elseif {[lsearch -exact $quote1 $word] >= 0 && [_isdelim $after]} {
						lappend spans $i [expr {$i + $len}] keyword
						set param [dict create parts 1] ; set state qopen
					} elseif {[lsearch -exact $quote2 $word] >= 0 && [_isdelim $after]} {
						lappend spans $i [expr {$i + $len}] keyword
						set param [dict create parts 2] ; set state qopen
					} elseif {[string match {*::*} $word]} {
						lappend spans $i [expr {$i + $len}] type
					} elseif {[lsearch -exact $keywords $word] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
						if {$word eq "sub" || $word eq "package"} { set pend $word }
					} elseif {[lsearch -exact $builtins $word] >= 0} {
						lappend spans $i [expr {$i + $len}] function
					} elseif {$after eq "("} {
						lappend spans $i [expr {$i + $len}] function
					}
					incr i $len
				} else {
					if {![string is space $ch]} { set pend "" }
					incr i   ;# operators, punctuation, whitespace: plain
				}
			}
		}
	}
	return [list $spans $state $param]
}

# Length of a sigil variable at the START of `sub` (which begins with sigil `ch`), or
# 0 when the sigil is really an operator (`%`/`&` not followed by a name, a bare `$`).
proc rio::syntax::perl::_sigil {sub ch} {
	# $#array or $#{...} — the array-last-index sigil (handled before plain #comment).
	if {$ch eq "\$" && [regexp -indices {^\$#\{?[[:alnum:]_:]*} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	# ${ name } / @{ name } / %{ name } / &{ name } — a simple block deref.
	if {[regexp -indices {^[$@%&]\{\s*\^?[[:alnum:]_:]+\s*\}} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	# $name @name %name &name, with optional :: package qualification.
	if {[regexp -indices {^[$@%&](?:::)?[[:alpha:]_][[:alnum:]_]*(?:::[[:alnum:]_]+)*} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	# $1 $2 … (capture / positional match variables).
	if {$ch eq "\$" && [regexp -indices {^\$[0-9]+} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	# $^W and friends (control-char specials).
	if {$ch eq "\$" && [regexp -indices {^\$\^[[:alpha:]]} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	# $ / @ punctuation specials: $! $@ $/ $\ $& $` $' $, $; $. $_ @_ …
	if {($ch eq "\$" || $ch eq "@") && [regexp -indices {^[$@][]!@/&.,;:?~<>|*`'+^\\_$-]} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	return 0
}

# Can `c` open a quote-like delimiter right after an operator word? Any single non-
# word, non-space char except the fat-comma/list punctuation and the closing brackets
# — those would false-positive on `s => 1`, `m, n`, `y}` and the like.
proc rio::syntax::perl::_isdelim {c} {
	variable nondelim
	if {$c eq "" || [string is space $c] || [string is alnum $c]} { return 0 }
	return [expr {[string first $c $nondelim] < 0}]
}

rio::syntax::register Perl {pl pm t pod psgi} rio::syntax::perl::scan
