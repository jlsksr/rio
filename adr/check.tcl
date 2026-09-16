#!/usr/bin/env tclsh
#
# The guard for adr/ (ADR-0117: a fact that lives in two places gets a guard, not a
# promise to re-read it). Three pairs are held together here:
#
#   - each record's title, status and date, and the row for it in README.md's index;
#   - the set of records, and the set of rows;
#   - AGENTS.md's D numbers, and the record numbers, which are one series up to D111.
#
# It reads files and nothing else: no Tk, no display, no network.
#
# Run:  tclsh adr/check.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding, so this file's own non-ASCII
# expectations would arrive mojibake and fail against correctly-decoded file content.
# The same guard rio's entry points carry. No-op where the system encoding is UTF-8.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}

set ::adr [file normalize [file dirname [info script]]]
set ::repo [file dirname $::adr]

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} {
		puts "PASS  $label"
	} else {
		puts "FAIL  $label\n        got:  $got\n        want: $want"
		incr ::fails
	}
}

proc slurp {path} {
	set f [open $path r] ; fconfigure $f -encoding utf-8
	set t [read $f] ; close $f
	return $t
}

# A status cites later records as [ADR-0030](0030-slug.md); the index carries the bare
# number. Reduce the record's form to the index's so the two can be compared.
proc status_plain {s} {
	regsub -all {\[ADR-([0-9]{4})\]\([^)]*\)} $s {\1} s
	return $s
}

# Every relative Markdown link target in a text, with any #anchor stripped.
proc md_links {text} {
	set out {}
	foreach {_ target} [regexp -all -inline {\]\(([^)]+)\)} $text] {
		if {[regexp {^[a-z][a-z0-9+.-]*:} $target]} continue
		lappend out [lindex [split $target #] 0]
	}
	return $out
}

# --- read the records ------------------------------------------------------

set ::numbers {}
array set ::rec {}

foreach path [lsort [glob -nocomplain -directory $::adr {[0-9][0-9][0-9][0-9]-*.md}]] {
	set name [file tail $path]
	regexp {^([0-9]{4})-} $name -> num
	set text [slurp $path]
	set head [lindex [split $text \n] 0]
	set htitle "" ; set hnum ""
	regexp {^# ADR-([0-9]{4}): (.+)$} $head -> hnum htitle
	set status "" ; set date "" ; set deciders "" ; set log ""
	regexp -line {^- \*\*Status:\*\* (.+)$} $text -> status
	regexp -line {^- \*\*Date:\*\* (.+)$} $text -> date
	regexp -line {^- \*\*Deciders:\*\* (.+)$} $text -> deciders
	regexp -line {^- \*\*Decision log:\*\* (.+)$} $text -> log
	lappend ::numbers $num
	set ::rec($num,file) $name
	set ::rec($num,hnum) $hnum
	set ::rec($num,title) $htitle
	set ::rec($num,status) $status
	set ::rec($num,date) $date
	set ::rec($num,deciders) $deciders
	set ::rec($num,log) $log
	set ::rec($num,text) $text
}

ok "adr/ holds records" [expr {[llength $::numbers] > 0}] 1

# --- 1. header shape -------------------------------------------------------

set bad {}
foreach n $::numbers {
	if {$::rec($n,hnum) ne $n} { lappend bad $::rec($n,file) }
}
ok "every record's heading number matches its filename" $bad {}

set bad {}
foreach n $::numbers {
	foreach field {title status date deciders log} {
		if {$::rec($n,$field) eq ""} { lappend bad "$::rec($n,file) ($field)" }
	}
}
ok "every record has a title, Status, Date, Deciders and a decision-log line" $bad {}

set bad {}
foreach n $::numbers {
	if {![regexp {^[0-9]{4}-[0-9]{2}-[0-9]{2}$} $::rec($n,date)]} {
		lappend bad "$::rec($n,file) ($::rec($n,date))"
	}
}
ok "every date is YYYY-MM-DD" $bad {}

# --- 2. numbering ----------------------------------------------------------

set dupes {}
set seen {}
foreach n $::numbers {
	if {[lsearch -exact $seen $n] >= 0} { lappend dupes $n }
	lappend seen $n
}
ok "no number is used twice" $dupes {}

set gaps {}
set want 1
foreach n [lsort -unique $::numbers] {
	while {$want < [scan $n %d]} { lappend gaps [format %04d $want] ; incr want }
	incr want
}
ok "the numbers run from 0001 with no gaps" $gaps {}

# --- 3. links resolve ------------------------------------------------------

set readme [slurp [file join $::adr README.md]]

set dead {}
foreach {label text} [list README.md $readme template.md [slurp [file join $::adr template.md]]] {
	foreach target [md_links $text] {
		if {![file exists [file join $::adr $target]]} { lappend dead "$label -> $target" }
	}
}
foreach n $::numbers {
	foreach target [md_links $::rec($n,text)] {
		if {![file exists [file join $::adr $target]]} {
			lappend dead "$::rec($n,file) -> $target"
		}
	}
}
ok "every relative link resolves" $dead {}

# --- 4. every ADR-NNNN named is a record -----------------------------------

set bogus {}
set sources [list [list README.md $readme]]
foreach n $::numbers { lappend sources [list $::rec($n,file) $::rec($n,text)] }
foreach pair $sources {
	lassign $pair label text
	foreach {_ ref} [regexp -all -inline {ADR-([0-9]{4})} $text] {
		if {![info exists ::rec($ref,file)]} { lappend bogus "$label -> ADR-$ref" }
	}
}
ok "every ADR-NNNN named is a record that exists" [lsort -unique $bogus] {}

# --- 5 & 6. the index agrees with the records ------------------------------

array set ::row {}
set rownums {}
foreach {_ num link title status date} \
		[regexp -all -inline -line {^\| \[([0-9]{4})\]\(([^)]+)\) \| (.+?) \| (.+?) \| (.+?) \|$} $readme] {
	lappend rownums $num
	set ::row($num,link) $link
	set ::row($num,title) [string trim $title]
	set ::row($num,status) [string trim $status]
	set ::row($num,date) [string trim $date]
}

set missing {}
foreach n $::numbers {
	if {[lsearch -exact $rownums $n] < 0} { lappend missing $::rec($n,file) }
}
ok "every record has an index row" $missing {}

set orphan {}
foreach n $rownums {
	if {![info exists ::rec($n,file)]} { lappend orphan $n }
}
ok "every index row names a record that exists" $orphan {}

set bad {}
foreach n $rownums {
	if {![info exists ::rec($n,file)]} continue
	if {$::row($n,link) ne $::rec($n,file)} { lappend bad "$n link" }
}
ok "every index row links to its own file" $bad {}

set bad {}
foreach n $rownums {
	if {![info exists ::rec($n,file)]} continue
	if {$::row($n,title) ne $::rec($n,title)} {
		lappend bad "$n: index \"$::row($n,title)\" vs record \"$::rec($n,title)\""
	}
}
ok "every index row's title is the record's own" $bad {}

set bad {}
foreach n $rownums {
	if {![info exists ::rec($n,file)]} continue
	set want [status_plain $::rec($n,status)]
	if {$::row($n,status) ne $want} {
		lappend bad "$n: index \"$::row($n,status)\" vs record \"$want\""
	}
}
ok "every index row's status is the record's own" $bad {}

set bad {}
foreach n $rownums {
	if {![info exists ::rec($n,file)]} continue
	if {$::row($n,date) ne $::rec($n,date)} {
		lappend bad "$n: index $::row($n,date) vs record $::rec($n,date)"
	}
}
ok "every index row's date is the record's own" $bad {}

# --- 7. the D numbers and the record numbers are one series ----------------

set agents [slurp [file join $::repo AGENTS.md]]
set dnums {}
foreach {_ d} [regexp -all -inline -line {^### D([0-9]+) } $agents] { lappend dnums $d }
set dnums [lsort -integer -unique $dnums]

ok "AGENTS.md has D entries" [expr {[llength $dnums] > 0}] 1

# Which record cites which D number, from the decision-log line alone.
array set ::byd {}
foreach n $::numbers {
	foreach {_ d} [regexp -all -inline {D([0-9]+)} $::rec($n,log)] {
		lappend ::byd($d) $n
	}
}

set missing {}
foreach d $dnums {
	if {![info exists ::byd($d)]} { lappend missing "D$d" }
}
ok "every D entry in AGENTS.md has a record" $missing {}

set bogus {}
foreach d [lsort -integer [array names ::byd]] {
	if {[lsearch -exact $dnums $d] < 0} {
		lappend bogus "D$d (cited by [join $::byd($d) {, }])"
	}
}
ok "no record cites a D number AGENTS.md does not have" $bogus {}

# D1-D111 predate the records and are cited by number all over the source; those two
# series must stay aligned or a "D30" in a comment points at the wrong record.
set bad {}
foreach d $dnums {
	if {$d > 111} continue
	if {![info exists ::byd($d)]} continue
	set want [format %04d $d]
	if {[lsearch -exact $::byd($d) $want] < 0} {
		lappend bad "D$d -> [join $::byd($d) {, }] (want $want)"
	}
}
ok "D1-D111 are recorded as ADR-0001-ADR-0111" $bad {}

puts [expr {$::fails ? "FAILED ($::fails)" : "ALL PASS"}]
exit [expr {$::fails ? 1 : 0}]
