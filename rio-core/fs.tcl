# rio-core — file I/O that preserves encoding and line endings (D22).
#
# read detects encoding, BOM and LF/CRLF; write restores them. The document
# model only ever sees \n (D12).
#
# Not handled: UTF-16, bare-CR line endings, lazy loading (a file is read whole).
# Bytes that are not UTF-8 go through iso8859-1, which round-trips any byte.
#
# Pure I/O: no Tk, no protocol.

namespace eval rio::fs {}

# Read a file. Returns a dict:
#   text     — decoded content, EOL normalized to \n
#   encoding — utf-8 | iso8859-1
#   bom      — "" | utf-8
#   eol      — lf | crlf    (the dominant one, restored on save)
#   mixed    — 0 | 1        (both conventions present)
#   mtime, size — the file's disk identity (D94), stat'd AFTER the read: a
#              write landing mid-read then counts as unseen, so rio asks.
proc rio::fs::read {path} {
	set f [open $path rb]
	set bytes [::read $f]          ;# ::read — rio::fs::read would shadow it here
	close $f
	set st [stamp $path]

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

	# Normalize to \n and count the CRLFs in the same pass: the map drops one
	# character per CRLF, so the length lost is the count (D126). Only a file
	# with CRLF pays for counting the bare LFs.
	# A wrong `eol` corrupts a file on save: fs.test, `fs-eol-differential`.
	set n0 [string length $text]
	set text [string map [list "\r\n" "\n"] $text]
	set crlf [expr {$n0 - [string length $text]}]
	if {$crlf == 0} {
		set mixed 0
		set eol lf
	} else {
		set lf [expr {[regexp -all "\n" $text] - $crlf}]
		set mixed [expr {$lf > 0}]
		set eol [expr {$crlf >= $lf ? "crlf" : "lf"}]
	}

	return [dict merge [dict create \
		text $text encoding $encoding bom $bom eol $eol mixed $mixed] $st]
}

# A file's disk identity (D94): {mtime <epoch seconds> size <bytes>}.
# Both, because a same-second rewrite changes only the size and a same-length
# edit only the mtime. A missing or unreadable path gives {}: "never stamped".
proc rio::fs::stamp {path} {
	if {[catch {file mtime $path} mt]} { return {} }
	if {[catch {file size $path} sz]}  { return {} }
	return [dict create mtime $mt size $sz]
}

# Judge a file before reading it whole (D125): one stat, then at most `probe`
# bytes. A whole read of a huge file stalls the single-threaded core.
# Returns {verdict ok|too_large|binary, size <bytes>}.
#
#   too_large — bigger than `max_bytes`. The caller sets the limit; 0 means none.
#   binary    — a NUL byte within the first `probe` bytes (git's rule).
#
# A path that cannot be stat'd or opened is `ok`: the read that follows raises
# the real error.
proc rio::fs::classify {path max_bytes {probe 8192}} {
	if {[catch {file size $path} sz]} { return [dict create verdict ok size 0] }
	if {$max_bytes > 0 && $sz > $max_bytes} {
		return [dict create verdict too_large size $sz]
	}
	if {[catch {open $path rb} f]} { return [dict create verdict ok size $sz] }
	set head [::read $f $probe]   ;# ::read — rio::fs::read would shadow it here
	close $f
	if {[string first "\x00" $head] >= 0} {
		return [dict create verdict binary size $sz]
	}
	return [dict create verdict ok size $sz]
}

# `bytes` as a person says it: "913 KB", "8.4 MB", "1.2 GB". In the core so
# every frontend words classify's verdict the same way.
proc rio::fs::human_size {bytes} {
	if {$bytes < 1024}       { return "$bytes bytes" }
	if {$bytes < 1048576}    { return "[expr {round($bytes / 1024.0)}] KB" }
	if {$bytes < 1073741824} { return "[format %.1f [expr {$bytes / 1048576.0}]] MB" }
	return "[format %.1f [expr {$bytes / 1073741824.0}]] GB"
}

# Write `text` (\n-separated) to `path` with the encoding, BOM and line ending
# in `meta`. Missing keys mean a new file: UTF-8, no BOM, LF (D22).
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

# List directory `dir` (absolute). Returns {name type} dicts, type "dir" or
# "file", in dictionary order ("a2" before "a10", case folded).
# Dotfiles are included; hiding them is the frontend's choice. A symlink to a
# directory is "dir"; anything else, a broken link too, is "file".
# Named listdir: a proc `list` would shadow the builtin in this namespace.
proc rio::fs::listdir {dir} {
	set names {}
	foreach pat {* .*} {
		foreach name [glob -nocomplain -tails -directory $dir -- $pat] {
			if {$name eq "." || $name eq ".."} continue
			lappend names $name
		}
	}
	# -unique: on Windows `glob *` matches dotfiles too, so the patterns overlap.
	set entries {}
	foreach name [lsort -dictionary -unique $names] {
		set type [expr {[file isdirectory [file join $dir $name]] ? "dir" : "file"}]
		lappend entries [dict create name $name type $type]
	}
	return $entries
}

# Create an empty file (type "file") or a directory (type "dir") at `path`
# (absolute). Refuses an existing path. Parents are created as needed.
proc rio::fs::create {path type} {
	if {[file exists $path]} { error "already exists: $path" }
	switch -- $type {
		dir  { file mkdir $path }
		file {
			file mkdir [file dirname $path]
			close [open $path w]
		}
		default { error "unknown create type: $type" }
	}
	return
}

# Move `from` to `to` (both absolute). Refuses an existing destination, so a
# rename never overwrites. The destination's parents are created.
proc rio::fs::rename {from to} {
	if {[file exists $to]} { error "destination exists: $to" }
	file mkdir [file dirname $to]
	file rename -- $from $to
	return
}

# Delete `path` (absolute); a directory goes with its subtree. The GUI
# confirms first. A path already gone is an error.
proc rio::fs::delete {path} {
	if {![file exists $path]} { error "no such path: $path" }
	file delete -force -- $path
	return
}

# --- UTF-8 well-formedness (RFC 3629) ----------------------------------------
#
# True iff `bytes` is valid UTF-8. Decided by round-trip (D126): decode,
# re-encode, compare. An overlong, truncated or stray sequence comes back
# different. That is a C loop, and it tests what D22 needs: a save that
# reproduces the bytes.
#
# A surrogate (\xED\xA0\x80, CESU-8) would round-trip, so it is excluded
# first. `string first` is the cheap gate before the regexp.

proc rio::fs::_valid_utf8 {bytes} {
	if {[string first "\xED" $bytes] >= 0 && [regexp {\xED[\xA0-\xBF]} $bytes]} {
		return 0
	}
	return [expr {[encoding convertto utf-8 [encoding convertfrom utf-8 $bytes]] eq $bytes}]
}
