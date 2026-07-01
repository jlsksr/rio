# rio — an (X)HTML syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O,
# no external packages — a linear, per-line state machine (see rio::syntax for the
# contract). It carries its scan state across lines, so multi-line comments, script
# and style bodies, and quoted attribute values all colour correctly.
#
# It colours: comments (<!-- -->), the doctype and processing instructions (<!…>,
# <?…?>) as `meta`, element names and their angle brackets as `tag`, attribute
# names as `attribute`, quoted attribute values as `string`, and &entities; — and
# it treats the body of <script>/<style> as raw text (an inline `<` in JavaScript
# doesn't spawn a phantom tag). Text content between tags is left un-highlighted.

namespace eval rio::syntax::html {}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam},
# where spans is a flat {c0 c1 type ...} of half-open COLUMN ranges within the line
# (the rio::syntax contract). States: text | comment | meta | tag | str | raw. The
# START state "" falls through to the `default` (text) arm, so line 1 needs no
# special-casing. `param` carries per-state data (tag element, quote char, raw
# element).
proc rio::syntax::html::scan {line state param} {
	set spans {}
	set n [string length $line]
	set i 0
	while {$i < $n} {
		switch -- $state {
			comment {
				set j [string first "-->" $line $i]
				if {$j < 0} {
					lappend spans $i $n comment ; set i $n
				} else {
					lappend spans $i [expr {$j + 3}] comment
					set i [expr {$j + 3}] ; set state text
				}
			}
			meta {
				set j [string first ">" $line $i]
				if {$j < 0} {
					lappend spans $i $n meta ; set i $n
				} else {
					lappend spans $i [expr {$j + 1}] meta
					set i [expr {$j + 1}] ; set state text
				}
			}
			str {
				set q [dict get $param quote]
				set j [string first $q $line $i]
				if {$j < 0} {
					lappend spans $i $n string ; set i $n
				} else {
					lappend spans $i [expr {$j + 1}] string
					set i [expr {$j + 1}]
					set state tag ; set param [dict get $param tag]
				}
			}
			raw {
				# Skip the raw body until the matching close tag; hand the </tag>
				# back to the text scanner so it colours as ordinary markup.
				set j [_ifind $line "</[dict get $param elt]" $i]
				if {$j < 0} { set i $n } else { set i $j ; set state text }
			}
			tag {
				set ch [string index $line $i]
				if {$ch eq ">"} {
					lappend spans $i [expr {$i + 1}] tag
					set nm [dict get $param name]
					if {![dict get $param close] && ($nm eq "script" || $nm eq "style")} {
						set state raw ; set param [dict create elt $nm]
					} else {
						set state text
					}
					incr i
				} elseif {$ch eq "/" && [string index $line [expr {$i + 1}]] eq ">"} {
					lappend spans $i [expr {$i + 2}] tag ; incr i 2 ; set state text
				} elseif {$ch eq "/"} {
					lappend spans $i [expr {$i + 1}] tag ; incr i
				} elseif {$ch eq "\"" || $ch eq "'"} {
					set j [string first $ch $line [expr {$i + 1}]]
					if {$j < 0} {
						lappend spans $i $n string
						set state str
						set param [dict create quote $ch tag $param] ; set i $n
					} else {
						lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}]
					}
				} elseif {[regexp -indices {^[[:alpha:]_:][-[:alnum:]_:.]*} \
						[string range $line $i end] m]} {
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] attribute ; incr i $len
				} else {
					incr i   ;# whitespace, '=', unquoted-value char: leave plain
				}
			}
			default {  ;# text
				set lt  [string first "<" $line $i]
				set amp [string first "&" $line $i]
				if {$lt  < 0} { set lt  $n }
				if {$amp < 0} { set amp $n }
				if {$lt >= $n && $amp >= $n} { set i $n ; continue }
				if {$amp < $lt} {
					set rest [string range $line $amp end]
					if {[regexp -indices {^&#?[[:alnum:]]+;} $rest m]} {
						set len [expr {[lindex $m 1] + 1}]
						lappend spans $amp [expr {$amp + $len}] entity ; set i [expr {$amp + $len}]
					} else {
						set i [expr {$amp + 1}]   ;# a bare '&' is plain text
					}
					continue
				}
				# lt is the next markup delimiter.
				if {[string range $line $lt [expr {$lt + 3}]] eq "<!--"} {
					set state comment ; set i $lt
				} elseif {[string range $line $lt [expr {$lt + 1}]] eq "<!"
						|| [string range $line $lt [expr {$lt + 1}]] eq "<?"} {
					set state meta ; set i $lt
				} elseif {[string range $line $lt [expr {$lt + 1}]] eq "</"
						&& [regexp {^</([[:alpha:]][-[:alnum:]:]*)} \
							[string range $line $lt end] whole name]} {
					set len [string length $whole]
					lappend spans $lt [expr {$lt + $len}] tag ; set i [expr {$lt + $len}]
					set state tag ; set param [dict create name [string tolower $name] close 1]
				} elseif {[regexp {^<([[:alpha:]][-[:alnum:]:]*)} \
						[string range $line $lt end] whole name]} {
					set len [string length $whole]
					lappend spans $lt [expr {$lt + $len}] tag ; set i [expr {$lt + $len}]
					set state tag ; set param [dict create name [string tolower $name] close 0]
				} else {
					set i [expr {$lt + 1}]   ;# a bare '<' (e.g. "a < b") is plain text
				}
			}
		}
	}
	return [list $spans $state $param]
}

# Case-insensitive [string first] (ASCII): lowercasing both sides is position-
# preserving, so the returned offset indexes the ORIGINAL line.
proc rio::syntax::html::_ifind {haystack needle start} {
	return [string first [string tolower $needle] [string tolower $haystack] $start]
}

rio::syntax::register html {html htm xhtml xht} rio::syntax::html::scan
