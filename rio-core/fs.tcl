# rio-core — file I/O with encoding and line-ending preservation (AGENTS.md D22).
#
# Reading a file is lossy if you guess wrong, so this module DETECTS and the
# document carries the result so a later save can REPRODUCE the original form
# rather than silently rewriting it (D22): the encoding, a UTF-8 BOM if present,
# and the LF-vs-CRLF convention. The document model itself only ever sees \n
# (D12); CRLF is stripped on read and restored on write.
#
# Scope, stated honestly:
#   - Encoding detection is: UTF-8 (with or without BOM) if the bytes are
#     well-formed UTF-8 (RFC 3629), else a lossless iso8859-1 fallback that maps
#     every byte 1:1 so an unknown encoding round-trips intact instead of being
#     corrupted. UTF-16/other BOMs are out of scope for now (real source repos
#     are overwhelmingly UTF-8/ASCII); they would decode via the byte-preserving
#     fallback, not silently mangled.
#   - Line endings: LF and CRLF. A bare-CR (classic-Mac) convention is out of
#     scope. New buffers default to LF (D22).
#   - Large-file / lazy-load is out of scope (O3): a file is read whole.
#
# Pure I/O — no Tk, no protocol — so it unit-tests headless.

namespace eval rio::fs {}

# Read a file. Returns a dict:
#   text     — decoded content, EOL normalized to \n for the document model
#   encoding — utf-8 | iso8859-1
#   bom      — "" | utf-8   (a detected/preserved byte-order mark)
#   eol      — lf | crlf    (the dominant convention to restore on save)
#   mixed    — 0 | 1        (both conventions present; dominant chosen, surfaced)
proc rio::fs::read {path} {
	set f [open $path rb]
	set bytes [::read $f]          ;# ::read — rio::fs::read would shadow it here
	close $f

	set bom ""
	if {[string range $bytes 0 2] eq "\xEF\xBB\xBF"} {
		set bom utf-8
		set bytes [string range $bytes 3 end]
	}

	if {[_valid_utf8 $bytes]} {
		set encoding utf-8
		set text [encoding convertfrom utf-8 $bytes]
	} else {
		set encoding iso8859-1
		set text [encoding convertfrom iso8859-1 $bytes]
	}

	# Detect the line-ending convention, then normalize to \n for the model.
	set crlf [regexp -all "\r\n" $text]
	set lf   [expr {[regexp -all "\n" $text] - $crlf}]
	set mixed [expr {$crlf > 0 && $lf > 0}]
	set eol [expr {$crlf > 0 && $crlf >= $lf ? "crlf" : "lf"}]
	set text [string map [list "\r\n" "\n"] $text]

	return [dict create text $text encoding $encoding bom $bom eol $eol mixed $mixed]
}

# Write `text` (\n-separated, from the model) to `path`, restoring the encoding,
# BOM, and line-ending recorded in `meta`. Missing keys default to a new-file
# convention: UTF-8, no BOM, LF (D22) — so a save-as on a scratch buffer works.
proc rio::fs::write {path text meta} {
	set enc [expr {[dict exists $meta encoding] ? [dict get $meta encoding] : "utf-8"}]
	set eol [expr {[dict exists $meta eol]      ? [dict get $meta eol]      : "lf"}]
	set bom [expr {[dict exists $meta bom]      ? [dict get $meta bom]      : ""}]

	if {$eol eq "crlf"} { set text [string map [list "\n" "\r\n"] $text] }
	set bytes [encoding convertto $enc $text]
	if {$bom eq "utf-8"} { set bytes "\xEF\xBB\xBF$bytes" }

	set f [open $path wb]
	puts -nonewline $f $bytes
	close $f
	return
}

# List the entries of directory `dir` (an absolute path). Returns a list of flat
# dicts {name type}, where type is "dir" or "file", in dictionary order (so "a2"
# sorts before "a10" and case is folded — the natural order for a file tree).
# Hidden entries (dotfiles) are included — filtering them is a frontend choice,
# not the data layer's; `.` and `..` are not entries. type follows symlinks
# (a symlink to a directory reads as "dir", so the tree can expand it); anything
# that is not a directory — including a plain file or a broken link — is "file".
# Named listdir, not list: a proc named `list` would shadow the builtin for every
# unqualified [list ...] elsewhere in this namespace (see the ::read note above).
proc rio::fs::listdir {dir} {
	set names {}
	foreach pat {* .*} {
		foreach name [glob -nocomplain -tails -directory $dir -- $pat] {
			if {$name eq "." || $name eq ".."} continue
			lappend names $name
		}
	}
	set entries {}
	foreach name [lsort -dictionary $names] {
		set type [expr {[file isdirectory [file join $dir $name]] ? "dir" : "file"}]
		lappend entries [dict create name $name type $type]
	}
	return $entries
}

# --- UTF-8 well-formedness (RFC 3629 / Unicode Table 3-7) --------------------
#
# True iff every byte sequence is a valid UTF-8 encoding — rejecting overlong
# forms and surrogate code points, so we don't mislabel arbitrary bytes as UTF-8.

proc rio::fs::_valid_utf8 {bytes} {
	binary scan $bytes cu* a      ;# one pass to an unsigned-byte list
	set n [llength $a]
	set i 0
	while {$i < $n} {
		set b [lindex $a $i]
		if {$b < 0x80} { incr i; continue }
		if {$b >= 0xC2 && $b <= 0xDF} {
			if {![_cont $a [expr {$i+1}] 1]} { return 0 } ; incr i 2 ; continue
		}
		if {$b == 0xE0} {
			if {![_in $a [expr {$i+1}] 0xA0 0xBF] || ![_cont $a [expr {$i+2}] 1]} { return 0 }
			incr i 3 ; continue
		}
		if {($b >= 0xE1 && $b <= 0xEC) || $b == 0xEE || $b == 0xEF} {
			if {![_cont $a [expr {$i+1}] 2]} { return 0 } ; incr i 3 ; continue
		}
		if {$b == 0xED} {
			if {![_in $a [expr {$i+1}] 0x80 0x9F] || ![_cont $a [expr {$i+2}] 1]} { return 0 }
			incr i 3 ; continue
		}
		if {$b == 0xF0} {
			if {![_in $a [expr {$i+1}] 0x90 0xBF] || ![_cont $a [expr {$i+2}] 2]} { return 0 }
			incr i 4 ; continue
		}
		if {$b >= 0xF1 && $b <= 0xF3} {
			if {![_cont $a [expr {$i+1}] 3]} { return 0 } ; incr i 4 ; continue
		}
		if {$b == 0xF4} {
			if {![_in $a [expr {$i+1}] 0x80 0x8F] || ![_cont $a [expr {$i+2}] 2]} { return 0 }
			incr i 4 ; continue
		}
		return 0
	}
	return 1
}

# `count` continuation bytes (0x80..0xBF) starting at index `start`.
proc rio::fs::_cont {a start count} {
	set n [llength $a]
	for {set j 0} {$j < $count} {incr j} {
		set k [expr {$start + $j}]
		if {$k >= $n} { return 0 }
		set v [lindex $a $k]
		if {$v < 0x80 || $v > 0xBF} { return 0 }
	}
	return 1
}

# The byte at `idx` exists and lies in [lo, hi].
proc rio::fs::_in {a idx lo hi} {
	if {$idx >= [llength $a]} { return 0 }
	set v [lindex $a $idx]
	return [expr {$v >= $lo && $v <= $hi}]
}
