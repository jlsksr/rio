# rio-core — the fs.* op namespace (AGENTS.md D11, D22).
#
# Thin handlers bridging the protocol to file I/O. file.open reads a file into a
# NEW buffer, recording the detected encoding/BOM/line-ending as buffer metadata
# (D22) so file.save can reproduce the original on-disk form. As with buffer.*,
# the real work lives elsewhere (rio::fs, rio::doc).

# How big a file file.open will read without being asked twice (D125). A judgement
# about a PERSON'S patience, not a technical ceiling: rio's own largest source file is
# half a megabyte, so this is generous for anything you meant to edit, while a log, a
# core dump or a database lands well the other side of it. Deliberately NOT the same
# number as project.tcl's search budget — a search skipping a file costs you nothing,
# an editor refusing one costs you the file — and deliberately not a preference: the
# answer to "I did mean it" is the question the frontend asks, not a setting to find.
#
# 64 MiB exactly, not a round 64000000, so that the number here and the number rio says
# out loud are the same one: rio::fs::human_size counts in binary units under the
# customary MB label (what Windows and most file managers show), and 64000000 bytes
# would have announced itself as "61.0 MB" while the manual called the limit 64 MB.
#
# It was 8 MiB until D126, and the eight was never about patience — it was the cost of
# three whole-file passes rio did not need to make. Removing them (a C-level UTF-8
# verdict, highlighting only the visible window, and pulling the document over the
# channel in chunks so the inbound JSON parser stays linear) took an 8 MB open from
# ~13 s to ~1.6 s and made the curve linear, so the budget could follow the measurement
# up. 64 MiB is where it lands: ~13 s, which is about what 8 MB used to cost and is
# firmly back in "worth asking about" territory.
variable rio::ops::open_max_bytes 67108864

# file.open {path, ?force?} -> {buffer, name, encoding, eol, bom, mixed, linecount}
#
# Unless `force` is true, a file that is too large or looks binary is DECLINED rather
# than read (D125) — see rio::fs::classify. The frontend turns that into "open it
# anyway?" and asks again with force; a frontend that doesn't know the codes shows the
# message, which is the same sentence. `force` is additive, so an older client simply
# gets the guard.
proc rio::ops::file_open {params} {
	variable open_max_bytes
	if {![dict exists $params path]} {
		rio::error::raise bad_request "file.open requires a path"
	}
	set path [dict get $params path]
	if {!([dict exists $params force] && [dict get $params force])} {
		set verdict [rio::fs::classify $path $open_max_bytes]
		set human [rio::fs::human_size [dict get $verdict size]]
		switch -- [dict get $verdict verdict] {
			too_large {
				rio::error::raise too_large "[file tail $path] is $human — large\
					enough that opening it may make rio slow to respond."
			}
			binary {
				rio::error::raise binary_file "[file tail $path] looks like a binary\
					file rather than text ($human)."
			}
		}
	}
	if {[catch {rio::fs::read $path} info]} {
		rio::error::raise io_error $info
	}
	set name [file tail $path]
	# mtime/size ride in meta beside the encoding facts: the same "what was on disk when
	# we last looked" record, and what buffers.stale compares a fresh stat against (D94).
	set meta [dict create path $path \
		encoding [dict get $info encoding] \
		eol      [dict get $info eol] \
		bom      [dict get $info bom]]
	# Absent when the file went away between the read and the stat — the buffer then
	# reads as "never stamped", which is the honest answer and not an error.
	foreach k {mtime size} {
		if {[dict exists $info $k]} { dict set meta $k [dict get $info $k] }
	}
	set id [rio::doc::new [dict get $info text] $name $meta]
	return [dict create result [dict create \
		buffer    $id \
		name      $name \
		encoding  [dict get $info encoding] \
		eol       [dict get $info eol] \
		bom       [dict get $info bom] \
		mixed     [dict get $info mixed] \
		linecount [rio::doc::linecount $id]]]
}
rio::dispatch::register file.open rio::ops::file_open

# file.save {?buffer?, ?path?} -> {path}
# Writes the buffer's current text, preserving its recorded encoding/BOM/EOL.
# An explicit `path` is a save-as: the file is written there and the buffer's
# stored path is updated so subsequent saves follow.
proc rio::ops::file_save {params} {
	set id [_bufid $params]
	set meta [rio::doc::meta $id]
	set stored [expr {[dict exists $meta path] ? [dict get $meta path] : ""}]
	set path [expr {[dict exists $params path] ? [dict get $params path] : $stored}]
	if {$path eq ""} {
		rio::error::raise no_path "buffer has no associated file; supply a path"
	}
	if {[catch {rio::fs::write $path [rio::doc::text $id] $meta} err]} {
		rio::error::raise io_error $err
	}
	if {$stored ne $path} { rio::doc::setmeta $id path $path }
	# Re-stamp: the buffer has just BECOME what is on disk, so this is the version it has
	# seen. Without it every save would leave the buffer looking stale against its own
	# write, and the next check would ask about a change the user made themselves (D94).
	_restamp $id $path
	return [dict create result [dict create path $path]]
}

# Record what is on disk right now as the version buffer $id has seen (D94). Called
# wherever the buffer and the file are known to agree: after a save, after a reload.
proc rio::ops::_restamp {id path} {
	set st [rio::fs::stamp $path]
	foreach k {mtime size} {
		if {[dict exists $st $k]} { rio::doc::setmeta $id $k [dict get $st $k] }
	}
	return $st
}
rio::dispatch::register file.save rio::ops::file_save

# fs.list {?path?} -> {path <abs dir>, entries:[{name,type}]}
# Lists one directory for the file tree. `path` resolves against the project root
# (D11 project.*): omitted means the root itself; a relative path is joined onto
# it; an absolute path is taken as-is. So with a project open, the GUI lists the
# root with no params and expands a subtree by passing its relative path.
proc rio::ops::fs_list {params} {
	set path [expr {[dict exists $params path] ? [dict get $params path] : ""}]
	set dir [rio::project::resolve $path]
	if {![file isdirectory $dir]} {
		rio::error::raise io_error "not a directory: $dir"
	}
	if {[catch {rio::fs::listdir $dir} entries]} {
		rio::error::raise io_error $entries
	}
	return [dict create result [dict create path $dir entries $entries]]
}
rio::dispatch::register fs.list rio::ops::fs_list

# fs.read {path} -> {path, text, encoding, eol, bom, mixed, linecount}
# Read-only sibling of file.open: returns a file's decoded text (the same
# encoding/BOM/EOL detection of D22) WITHOUT minting a buffer — no tab, no
# document-model state. Reading is the inspection primitive the agent's read-only
# tools build on (D26), where opening a buffer per file would be a side effect.
# `path` resolves against the project root exactly like fs.list.
proc rio::ops::fs_read {params} {
	if {![dict exists $params path]} {
		rio::error::raise bad_request "fs.read requires a path"
	}
	set abs [rio::project::resolve [dict get $params path]]
	if {![file isfile $abs]} {
		rio::error::raise io_error "not a file: $abs"
	}
	if {[catch {rio::fs::read $abs} info]} {
		rio::error::raise io_error $info
	}
	set text [dict get $info text]
	set linecount [expr {$text eq "" ? 0 :
		[regexp -all "\n" $text] + ([string index $text end] ne "\n")}]
	return [dict create result [dict create \
		path      $abs \
		text      $text \
		encoding  [dict get $info encoding] \
		eol       [dict get $info eol] \
		bom       [dict get $info bom] \
		mixed     [dict get $info mixed] \
		linecount $linecount]]
}
rio::dispatch::register fs.read rio::ops::fs_read

# fs.write {path, text, ?encoding?, ?eol?, ?bom?} -> {path, chars}
# Write text to a project path, creating any missing parent directories. The
# write-sibling of fs.read and the agent's only disk-write primitive (reached
# solely through the approval gate, D26 slice 5); the user's own Save still goes
# through file.save. `path` resolves against the project root like fs.read.
proc rio::ops::fs_write {params} {
	foreach k {path text} {
		if {![dict exists $params $k]} {
			rio::error::raise bad_request "fs.write requires $k"
		}
	}
	set abs [rio::project::resolve [dict get $params path]]
	set meta {}
	foreach k {encoding eol bom} {
		if {[dict exists $params $k]} { dict set meta $k [dict get $params $k] }
	}
	if {[catch {
		file mkdir [file dirname $abs]
		rio::fs::write $abs [dict get $params text] $meta
	} err]} {
		rio::error::raise io_error $err
	}
	# Announce the disk write so frontends can refresh a file tree that isn't backed
	# by an open buffer (buffer.changed covers the open-buffer case). This is what
	# lets the GUI's file pane show an agent-created file without a manual reload.
	set ev [dict create event fs.changed params [dict create path $abs]]
	return [dict create result [dict create \
		path $abs chars [string length [dict get $params text]]] \
		events [list $ev]]
}
rio::dispatch::register fs.write rio::ops::fs_write

# The file-management write ops (D48): create / rename / delete a path, core-side so
# they work over a remote core exactly like git.add. Each mirrors fs.write's shape —
# resolve against the project root, wrap the I/O in a catch surfaced as io_error, and
# emit fs.changed so the GUI's file pane (D47) repaints without a manual reload. The
# GUI supplies the New/Rename names (a modal prompt) and the Delete confirmation; the
# core just does the work and announces it.

# fs.create {path, ?type file|dir?} -> {path} ; make an empty file (default) or a dir.
proc rio::ops::fs_create {params} {
	if {![dict exists $params path]} {
		rio::error::raise bad_request "fs.create requires a path"
	}
	set type [expr {[dict exists $params type] ? [dict get $params type] : "file"}]
	if {$type ni {file dir}} {
		rio::error::raise bad_request "fs.create type must be file or dir"
	}
	set abs [rio::project::resolve [dict get $params path]]
	if {[catch {rio::fs::create $abs $type} err]} {
		rio::error::raise io_error $err
	}
	set ev [dict create event fs.changed params [dict create path $abs]]
	return [dict create result [dict create path $abs] events [list $ev]]
}
rio::dispatch::register fs.create rio::ops::fs_create

# fs.rename {path, to} -> {from, to} ; move/rename, refusing to overwrite. Emits TWO
# fs.changed events — one for the source, one for the destination — so a move across
# directories repaints both ends (on_fs_changed keys the repaint on each path's dir).
proc rio::ops::fs_rename {params} {
	foreach k {path to} {
		if {![dict exists $params $k]} {
			rio::error::raise bad_request "fs.rename requires $k"
		}
	}
	set from [rio::project::resolve [dict get $params path]]
	set to   [rio::project::resolve [dict get $params to]]
	if {[catch {rio::fs::rename $from $to} err]} {
		rio::error::raise io_error $err
	}
	set evs [list \
		[dict create event fs.changed params [dict create path $from]] \
		[dict create event fs.changed params [dict create path $to]]]
	return [dict create result [dict create from $from to $to] events $evs]
}
rio::dispatch::register fs.rename rio::ops::fs_rename

# fs.delete {path} -> {path} ; delete a file or a whole directory tree (recursive).
proc rio::ops::fs_delete {params} {
	if {![dict exists $params path]} {
		rio::error::raise bad_request "fs.delete requires a path"
	}
	set abs [rio::project::resolve [dict get $params path]]
	if {[catch {rio::fs::delete $abs} err]} {
		rio::error::raise io_error $err
	}
	set ev [dict create event fs.changed params [dict create path $abs]]
	return [dict create result [dict create path $abs] events [list $ev]]
}
rio::dispatch::register fs.delete rio::ops::fs_delete
