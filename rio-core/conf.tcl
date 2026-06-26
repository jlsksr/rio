# rio-core — the flat config/theme file format (AGENTS.md D21, D24).
#
# One parser for the plain "[section] / key = value" data format that both config
# (D21) and themes (D24) use: `#` comments, blank lines, UTF-8. The whole point
# is that it is *parsed, never executed* — rio never `source`s an untrusted file
# as Tcl (D21's footgun-removal). The result is a nested dict
# {section -> {key -> value}}; keys and values are trimmed strings. Lines before
# the first [section] land under the "" (top-level) section.
#
# Pure: no Tk, no protocol — tests headless.

namespace eval rio::conf {}

# Parse config/theme TEXT into {section {key value ...} ...}. A line that is
# neither blank, a `#` comment, a [section] header, nor `key = value` is an
# error (with its line number) — quiet typo-swallowing is worse than a clear stop.
proc rio::conf::parse {text} {
	set out [dict create]
	set section ""
	set n 0
	foreach line [split $text "\n"] {
		incr n
		set t [string trim $line]
		if {$t eq "" || [string index $t 0] eq "#"} continue
		if {[regexp {^\[(.+)\]$} $t -> name]} {
			set section [string trim $name]
			if {![dict exists $out $section]} { dict set out $section [dict create] }
			continue
		}
		set eq [string first "=" $t]
		if {$eq < 0} {
			error "config line $n: expected key = value, \[section\], or # comment"
		}
		set key [string trim [string range $t 0 [expr {$eq - 1}]]]
		set val [string trim [string range $t [expr {$eq + 1}] end]]
		if {$key eq ""} { error "config line $n: empty key" }
		dict set out $section $key $val
	}
	return $out
}

# Read and parse a UTF-8 file. Thin convenience over parse (uses ::read so a
# rio::conf::read would not shadow the builtin, matching rio::fs).
proc rio::conf::read_file {path} {
	set f [open $path r]
	fconfigure $f -encoding utf-8
	set text [::read $f]
	close $f
	return [parse $text]
}
