# rio-core — the fs.* op namespace (D11, D22).
#
# Thin handlers over rio::fs and rio::doc. file.open reads a file into a new
# buffer and records its encoding, BOM and line ending in the buffer's meta
# (D22), so file.save can reproduce them.

# How big a file file.open reads without asking (D125, D126): about where an
# open starts to take seconds. Not a preference: the frontend asks "open it
# anyway?". 64 MiB exactly, so rio::fs::human_size shows it as "64.0 MB".
variable rio::ops::open_max_bytes 67108864

# file.open {path, ?force?} -> {buffer, name, encoding, eol, bom, mixed, linecount}
#
# Without `force`, a file that is too large or looks binary is declined, not
# read (D125, rio::fs::classify): error too_large or binary_file. The
# frontend asks "open it anyway?" and sends `force`.
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
	# mtime and size go into meta too: buffers.stale compares them (D94).
	set meta [dict create path $path \
		encoding [dict get $info encoding] \
		eol      [dict get $info eol] \
		bom      [dict get $info bom]]
	# Absent if the file vanished after the read: the buffer is then unstamped.
	foreach k {mtime size} {
		if {[dict exists $info $k]} { dict set meta $k [dict get $info $k] }
	}
	set id [rio::doc::new [dict get $info text] $name $meta]
	# The new buffer equals the file: nothing to autosave yet (D132). A recovery
	# copy from an earlier session is reported, not taken; the frontend asks.
	# `recovery` is "" when there is none.
	rio::autosave::note_saved $id
	set rec [rio::autosave::recovery_for $path]
	return [dict create result [dict create \
		buffer    $id \
		recovery       [expr {[dict exists $rec path]  ? [dict get $rec path]  : ""}] \
		recovery_mtime [expr {[dict exists $rec mtime] ? [dict get $rec mtime] : ""}] \
		recovery_newer [expr {[dict exists $rec newer] ? [dict get $rec newer] : 0}] \
		name      $name \
		encoding  [dict get $info encoding] \
		eol       [dict get $info eol] \
		bom       [dict get $info bom] \
		mixed     [dict get $info mixed] \
		linecount [rio::doc::linecount $id]]]
}
rio::dispatch::register file.open rio::ops::file_open

# file.save {?buffer?, ?path?} -> {path}
# Writes the buffer's text with its recorded encoding, BOM and EOL. A `path`
# is a save-as: the buffer follows it from then on.
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
	# Re-stamp, or the buffer would look stale against its own write (D94).
	_restamp $id $path
	# The file holds the buffer's text: drop the recovery copy (D132), and on
	# a save-as the old name's too.
	rio::autosave::note_saved $id
	rio::autosave::discard_path $path
	if {$stored ne $path && $stored ne ""} { rio::autosave::discard_path $stored }
	return [dict create result [dict create path $path]]
}

# Record what is on disk now as the version buffer $id has seen (D94).
proc rio::ops::_restamp {id path} {
	set st [rio::fs::stamp $path]
	foreach k {mtime size} {
		if {[dict exists $st $k]} { rio::doc::setmeta $id $k [dict get $st $k] }
	}
	return $st
}
rio::dispatch::register file.save rio::ops::file_save

# fs.list {?path?} -> {path <abs dir>, entries:[{name,type}]}
# Lists one directory. `path` resolves against the project root: omitted is
# the root, a relative path is joined onto it, an absolute one is taken as is.
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
# file.open without a buffer: the decoded text and nothing else. The agent's
# read tools use it (D26). `path` resolves like fs.list.
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
# Write text to a project path; missing parents are created. The agent's only
# disk write, reached only through the approval gate (D26). The user's Save
# is file.save.
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
	# Announce the write, so a file pane can repaint (D47).
	set ev [dict create event fs.changed params [dict create path $abs]]
	return [dict create result [dict create \
		path $abs chars [string length [dict get $params text]]] \
		events [list $ev]]
}
rio::dispatch::register fs.write rio::ops::fs_write

# File management (D48): create, rename, delete. Each resolves against the
# project root, maps an I/O failure to io_error and emits fs.changed (D47).
# Names and confirmations are the frontend's.

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

# fs.rename {path, to} -> {from, to} ; move, never overwriting. Emits two
# fs.changed, source and destination, so both directories repaint.
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
