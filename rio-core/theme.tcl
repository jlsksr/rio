# rio-core — the theme role table (AGENTS.md D24).
#
# A theme is DATA: a table of semantic ROLES — colours by role, fonts by named
# font — never widget paths, never code. The core owns the role vocabulary and
# the built-in default so the value set is shared (a future TUI maps the same
# colour roles onto a terminal palette); the *applier* that pokes Tk lives in the
# GUI frontend (D1 — fonts/colours are a GUI concern). A theme FILE (D21 format,
# parsed by rio::conf, never executed) overrides roles over a base theme.
#
# The table shape (the third non-flat protocol result; see rio::wire):
#   {colors {<role> <value> ...}
#    fonts  {<NamedFont> {family <s> size <n>} ...}}
#
# Pure data: no Tk here.

namespace eval rio::theme {
	# Tests point this at a fixture dir; empty means "use the real search path".
	variable override_dirs ""
	# Captured at SOURCE time: [info script] is this file here, but empty/wrong
	# once load runs from a dispatch call. The shipped example themes sit beside
	# this file's parent (repo-root themes/).
	variable srcdir [file dirname [file normalize [info script]]]
}

# The built-in default: the plain white-bg / black-fg "90s productivity" look
# (D24), and the full role vocabulary every theme inherits and the GUI applies.
# Fonts are NAMED fonts the GUI references by name, so a size change is live. The
# `syntax.*` roles colour the highlighter token types (D32): they live in the same
# role table (data) so themes harmonise highlighting to their palette, and any
# theme predating D32 inherits this default set rather than showing no colour. The
# `error` and `diff.*` roles colour the chat's error text and edit diffs and the
# compare pane's add/removed bands: they belong to the vocabulary for the same
# reason — a dark theme can retint them instead of being stuck with light pastels
# (a theme that omits them inherits these defaults). `editor.findmatch` tints the
# find bar's match highlight (D36) and `editor.currentline` the caret-line band
# (D60), same treatment.
proc rio::theme::default {} {
	return [dict create \
		colors [dict create \
			editor.bg        white \
			editor.fg        black \
			editor.cursor    black \
			editor.selection #c3d9ff \
			editor.findmatch #ffe9a0 \
			editor.currentline #eef2f7 \
			ui.bg            #dddddd \
			ui.fg            black \
			tab.bar.bg       #bbbbbb \
			tab.active.bg    white \
			tab.inactive.bg  #cfcfcf \
			tab.fg           black \
			gutter.fg        #888888 \
			chat.bg          white \
			chat.fg          black \
			accent           #1a73e8 \
			error            #cc0000 \
			diff.added       #118811 \
			diff.removed     #cc0000 \
			diff.added.bg    #ddffdd \
			diff.removed.bg  #ffdddd \
			syntax.comment   #6a737d \
			syntax.string    #032f62 \
			syntax.number    #005cc5 \
			syntax.keyword   #d73a49 \
			syntax.tag       #22863a \
			syntax.attribute #6f42c1 \
			syntax.entity    #e36209 \
			syntax.meta      #6a737d \
			syntax.operator  #d73a49 \
			syntax.function  #6f42c1 \
			syntax.variable  #e36209 \
			syntax.type      #6f42c1 \
			syntax.constant  #005cc5] \
		fonts [dict create \
			RioEditorFont [dict create family monospace size 12] \
			RioUIFont     [dict create family monospace size 9] \
			RioChatFont   [dict create family monospace size 11]]]
}

# Load a theme by name into a full role table. "" / "default" is the built-in.
# A named theme is read from a file, parsed, and merged over its base (the theme
# named by `base = ...`, or the default).
proc rio::theme::load {name} {
	if {$name eq "" || $name eq "default"} { return [default] }
	set path [_find $name]
	if {$path eq ""} { rio::error::raise bad_request "no such theme: $name" }
	# A theme file is data on disk: a parse failure (or an unreadable file) is the
	# client asking for a theme that can't be honoured, not a core bug — code it
	# bad_request like "no such theme", with the parser's reason for context. conf
	# stays a generic parser that knows nothing of the protocol's error taxonomy.
	if {[catch {from_conf [rio::conf::read_file $path]} part]} {
		rio::error::raise bad_request "theme $name is malformed: $part"
	}
	set base [expr {[dict get $part base] ne "" ? [load [dict get $part base]] : [default]}]
	return [merge $base $part]
}

# Turn a parsed conf dict into a PARTIAL theme {base colors fonts}: the [colors]
# section gives colour-role overrides; each [fonts.<Name>] section gives one
# named font's keys (family/size); a top-level `base = <name>` names the base.
proc rio::theme::from_conf {conf} {
	set colors [expr {[dict exists $conf colors] ? [dict get $conf colors] : {}}]
	set fonts [dict create]
	dict for {section body} $conf {
		if {[string match {fonts.*} $section]} {
			dict set fonts [string range $section 6 end] $body
		}
	}
	set base [expr {[dict exists $conf "" base] ? [dict get $conf "" base] : ""}]
	return [dict create base $base colors $colors fonts $fonts]
}

# Merge a partial override over a base table: override colours replace base
# colours by role; override font keys replace base font keys (so a theme can
# tweak just a size). Returns a full role table.
proc rio::theme::merge {base override} {
	set colors [dict get $base colors]
	if {[dict exists $override colors]} {
		dict for {role val} [dict get $override colors] { dict set colors $role $val }
	}
	set fonts [dict get $base fonts]
	if {[dict exists $override fonts]} {
		dict for {fname keys} [dict get $override fonts] {
			dict for {k v} $keys { dict set fonts $fname $k $v }
		}
	}
	return [dict create colors $colors fonts $fonts]
}

# The dirs searched for `<name>.theme`: the user's XDG themes dir first (D21
# locations), then the examples shipped beside the source.
proc rio::theme::searchdirs {} {
	variable override_dirs
	variable srcdir
	if {$override_dirs ne ""} { return $override_dirs }
	set dirs {}
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		lappend dirs [file join $::env(XDG_CONFIG_HOME) rio themes]
	} elseif {[info exists ::env(HOME)]} {
		lappend dirs [file join $::env(HOME) .config rio themes]
	}
	lappend dirs [file join $srcdir .. themes]
	return $dirs
}

proc rio::theme::_find {name} {
	foreach d [searchdirs] {
		set p [file join $d $name.theme]
		if {[file isfile $p]} { return $p }
	}
	return ""
}

# --- the theme STORE (D39) ----------------------------------------------------
#
# Extension repositories install themes CORE-side (the core reads theme files;
# a remote core reads its own disk, not the frontend's). The store is the
# user's writable themes dir — the FIRST search dir, so an installed theme
# shadows a shipped one of the same name, exactly like a hand-copied file.

# A theme name that is safe to join into a path and a URL (D39's safe-name
# rule). "default" is excluded: it names the built-in, which load never reads
# from disk — a default.theme file would be dead weight pretending otherwise.
proc rio::theme::valid_name {name} {
	if {$name eq "default"} { return 0 }
	return [regexp {^[A-Za-z0-9][A-Za-z0-9._-]*$} $name]
}

# The user's writable themes dir: where put/delete operate.
proc rio::theme::userdir {} {
	return [lindex [searchdirs] 0]
}

# Every loadable theme name: the built-in first, then the *.theme files across
# the search path, each name once (the user dir shadows shipped by load order,
# so a duplicate name is still ONE theme to a chooser).
proc rio::theme::names {} {
	set seen [dict create]
	foreach d [searchdirs] {
		foreach f [glob -nocomplain -directory $d *.theme] {
			dict set seen [file rootname [file tail $f]] 1
		}
	}
	return [concat default [lsort [dict keys $seen]]]
}

# Write a theme file into the user dir. The text is VALIDATED first — parsed
# as conf and shaped as a theme — so the store never holds a file theme.list
# advertises but load then rejects. The `base` it names is deliberately NOT
# resolved here: the base may be installed after the child (install order is
# the user's), and load reports a missing base cleanly when the theme is used.
proc rio::theme::put {name text} {
	if {![valid_name $name]} {
		rio::error::raise bad_request "bad theme name: $name"
	}
	if {[catch {from_conf [rio::conf::parse $text]}]} {
		rio::error::raise bad_request "not a valid theme: $name"
	}
	set dir [userdir]
	if {[catch {
		file mkdir $dir
		set f [open [file join $dir $name.theme] w]
		puts -nonewline $f $text
		close $f
	} err]} {
		rio::error::raise io_error "cannot write theme $name: $err"
	}
}

# Remove a theme from the user dir — and only from there: a shipped example is
# part of the installation, not something a protocol call may delete.
proc rio::theme::delete {name} {
	if {![valid_name $name]} {
		rio::error::raise bad_request "bad theme name: $name"
	}
	set p [file join [userdir] $name.theme]
	if {![file isfile $p]} {
		if {[_find $name] ne ""} {
			rio::error::raise bad_request "theme $name is shipped with rio, not removable"
		}
		rio::error::raise bad_request "no such user theme: $name"
	}
	if {[catch {file delete $p} err]} {
		rio::error::raise io_error "cannot delete theme $name: $err"
	}
}
