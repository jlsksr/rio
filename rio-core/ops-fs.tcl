# rio-core — the fs.* op namespace (AGENTS.md D11, D22).
#
# Thin handlers bridging the protocol to file I/O. file.open reads a file into a
# NEW buffer, recording the detected encoding/BOM/line-ending as buffer metadata
# (D22) so file.save can reproduce the original on-disk form. As with buffer.*,
# the real work lives elsewhere (rio::fs, rio::doc).

# file.open {path} -> {buffer, name, encoding, eol, bom, mixed, linecount}
proc rio::ops::file_open {params} {
	set path [dict get $params path]
	set info [rio::fs::read $path]
	set name [file tail $path]
	set meta [dict create path $path \
		encoding [dict get $info encoding] \
		eol      [dict get $info eol] \
		bom      [dict get $info bom]]
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
	if {$path eq ""} { error "buffer has no associated file; supply a path" }
	rio::fs::write $path [rio::doc::text $id] $meta
	if {$stored ne $path} { rio::doc::setmeta $id path $path }
	return [dict create result [dict create path $path]]
}
rio::dispatch::register file.save rio::ops::file_save
