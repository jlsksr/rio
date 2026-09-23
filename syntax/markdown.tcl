# rio — a Markdown syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no
# external packages — a linear, per-line state machine (see rio::syntax for the
# contract). It carries scan state across lines, so fenced code blocks colour as one
# unit. (This is the highlighter for rio's own README/AGENTS/ROADMAP/CHANGELOG.)
#
# Markdown is line-oriented, so the design is: recognise the LINE-level construct
# first (heading, thematic break, blockquote, list, fenced code), then scan the rest
# for INLINE spans. It colours: ATX headings (`# …`) as `keyword`; thematic breaks
# (`---`, `***`) and code-fence lines (```` ``` ````, `~~~`) as `meta`; blockquote
# `>` markers as `comment`; list markers (`-`/`*`/`+`/`1.`) as `keyword`; inline code
# `` `…` `` as `string`; `**strong**`/`__strong__` as `keyword` and `*em*`/`_em_` as
# `type`; `~~strike~~` as `comment`; `[text](url)` / `![alt](url)` links as `type`
# (text) + `string` (url); and `<autolinks>` as `string`. A fenced code block's BODY
# is left plain (rio does not yet re-highlight it in its own language — a possible
# later refinement); only the fences are marked.

namespace eval rio::syntax::markdown {}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a
# flat {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract).
# States: text | fence (inside a fenced code block; `param` holds the fence char and
# length so only a matching, long-enough fence closes it). The START state "" falls
# through to text.
proc rio::syntax::markdown::scan {line state param} {
	set spans {}
	set n [string length $line]

	if {$state eq "fence"} {
		# Inside a fenced code block: the body is plain; a matching fence closes it.
		if {[regexp {^ {0,3}(`{3,}|~{3,})[ \t]*$} $line -> f] \
				&& [string index $f 0] eq [dict get $param char] \
				&& [string length $f] >= [dict get $param len]} {
			lappend spans 0 $n meta ; return [list $spans text ""]
		}
		return [list {} fence $param]
	}

	# --- line-level constructs (they consume, or set up, the whole line) ---------
	if {[regexp {^ {0,3}(`{3,}|~{3,})} $line -> f]} {
		if {$n > 0} { lappend spans 0 $n meta }
		return [list $spans fence [dict create char [string index $f 0] len [string length $f]]]
	}
	if {[regexp {^ {0,3}#{1,6}([ \t]|$)} $line]} {
		lappend spans 0 $n keyword ; return [list $spans text ""]
	}
	if {[regexp {^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$} $line]} {
		lappend spans 0 $n meta ; return [list $spans text ""]
	}

	set i 0
	# Leading blockquote markers (possibly nested: `> > `).
	while {[regexp -indices "^\[ \t\]\{0,3\}>" [string range $line $i end] m]} {
		set gt [expr {$i + [lindex $m 1]}]
		lappend spans $gt [expr {$gt + 1}] comment
		set i [expr {$gt + 1}]
	}
	# A list marker at the (possibly post-blockquote) line start.
	if {[regexp -indices {^[ \t]*([-*+]|[0-9]{1,9}[.)])[ \t]} [string range $line $i end] m mk]} {
		set a [expr {$i + [lindex $mk 0]}] ; set b [expr {$i + [lindex $mk 1] + 1}]
		lappend spans $a $b keyword
		set i $b
	}

	# --- inline spans ------------------------------------------------------------
	while {$i < $n} {
		set ch [string index $line $i]
		set nx [string index $line [expr {$i + 1}]]
		if {$ch eq "`"} {
			incr i [_code $line $i spans]
		} elseif {$ch eq "*" && $nx eq "*"} {
			incr i [_span $line $i "**" keyword spans]
		} elseif {$ch eq "~" && $nx eq "~"} {
			incr i [_span $line $i "~~" comment spans]
		} elseif {$ch eq "*"} {
			incr i [_span $line $i "*" type spans]
		} elseif {$ch eq "_" && $nx eq "_" && [_bound $line [expr {$i - 1}]]} {
			incr i [_span $line $i "__" keyword spans]
		} elseif {$ch eq "_" && [_bound $line [expr {$i - 1}]]} {
			incr i [_span $line $i "_" type spans]
		} elseif {$ch eq "\[" || ($ch eq "!" && $nx eq "\[")} {
			incr i [_link $line $i spans]
		} elseif {$ch eq "<"} {
			incr i [_autolink $line $i spans]
		} else {
			incr i
		}
	}
	return [list $spans $state $param]
}

# Inline code span `` ` `` … `` ` `` (or ``` `` `` ``` runs). Appends its `string` span
# and returns the length consumed; 1 (leave the backtick plain) if it does not close.
proc rio::syntax::markdown::_code {line i spansvar} {
	upvar 1 $spansvar spans
	regexp -indices {^`+} [string range $line $i end] m
	set run [expr {[lindex $m 1] + 1}]
	set close [string first [string repeat ` $run] $line [expr {$i + $run}]]
	if {$close < 0} { return 1 }
	set e [expr {$close + $run}]
	lappend spans $i $e string
	return [expr {$e - $i}]
}

# An emphasis/strike span delimited by `mark` (`*`, `**`, `_`, `__`, `~~`) at column
# `i`, coloured `type`. CommonMark-ish: the opener must be followed by a non-space and
# the closer preceded by one. Appends the span and returns the length; the mark's own
# length (leave plain) if it does not close on this line.
proc rio::syntax::markdown::_span {line i mark type spansvar} {
	upvar 1 $spansvar spans
	set mlen [string length $mark]
	set first [string index $line [expr {$i + $mlen}]]
	if {$first eq "" || [string is space $first]} { return $mlen }
	set from [expr {$i + $mlen}]
	while {1} {
		set j [string first $mark $line $from]
		if {$j < 0} { return $mlen }
		if {$j > $from && ![string is space [string index $line [expr {$j - 1}]]]} {
			set e [expr {$j + $mlen}]
			lappend spans $i $e $type
			return [expr {$e - $i}]
		}
		set from [expr {$j + $mlen}]
	}
}

# A link/image `[text](url)` / `![alt](url)` at column `i`. Appends a `type` span over
# the bracketed text and a `string` span over the (url); returns the total length, or 1
# (leave the char plain) when the shape does not hold.
proc rio::syntax::markdown::_link {line i spansvar} {
	upvar 1 $spansvar spans
	set br [expr {[string index $line $i] eq "!" ? $i + 1 : $i}]
	set close [string first "\]" $line [expr {$br + 1}]]
	if {$close < 0 || [string index $line [expr {$close + 1}]] ne "("} { return 1 }
	set paren [string first ")" $line [expr {$close + 2}]]
	if {$paren < 0} { return 1 }
	lappend spans $i [expr {$close + 1}] type
	lappend spans [expr {$close + 1}] [expr {$paren + 1}] string
	return [expr {$paren + 1 - $i}]
}

# An autolink `<https://…>` or `<user@host>` at column `i`. Appends a `string` span and
# returns its length; 1 (leave `<` plain — it may be raw HTML) when it doesn't qualify.
proc rio::syntax::markdown::_autolink {line i spansvar} {
	upvar 1 $spansvar spans
	set close [string first ">" $line [expr {$i + 1}]]
	if {$close < 0} { return 1 }
	set body [string range $line [expr {$i + 1}] [expr {$close - 1}]]
	if {[regexp {^[[:alpha:]][[:alnum:]+.-]*://} $body] || [regexp {^[^[:space:]@]+@[^[:space:]@]+$} $body]} {
		lappend spans $i [expr {$close + 1}] string
		return [expr {$close + 1 - $i}]
	}
	return 1
}

# Is the char at column `c` a left boundary for `_` emphasis (start of line, space, or
# punctuation)? Guards against colouring snake_case identifiers.
proc rio::syntax::markdown::_bound {line c} {
	if {$c < 0} { return 1 }
	set ch [string index $line $c]
	return [expr {[string is space $ch] || ![string is alnum $ch]}]
}

rio::syntax::register Markdown {md markdown mkd mdown} rio::syntax::markdown::scan
