# rio-core — the theme role table (D24).
#
# A theme is data: colours by role, fonts by named font. Never a widget path,
# never code. The core owns the roles and the default; the frontend applies
# them. A theme file (rio::conf format, never executed) overrides roles of a
# base theme.
#
# The table:
#   {colors {<role> <value> ...}
#    fonts  {<NamedFont> {family <s> size <n>} ...}}
#
# No Tk.

namespace eval rio::theme {
	# Tests point this at a fixture dir; empty means the real search path.
	variable override_dirs ""
	# Set at source time: the shipped themes are in `themes/`, one level up.
	variable srcdir [file dirname [file normalize [info script]]]
}

# The built-in default (D24): white background, black text, and every role
# there is. A theme that omits a role inherits it from here.
#   syntax.*             the highlighter's token types (D32)
#   error, diff.*        chat errors, diffs, the compare pane's bands
#   editor.findmatch     the find bar's matches (D36)
#   editor.currentline   the caret line (D60)
# Fonts are named fonts, so a size change is live.
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
	# A file that does not parse is a bad_request, with the parser's reason.
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
# A repository installs a theme on the core's disk. The store is the user's
# themes dir, the first search dir, so an installed theme shadows a shipped
# one of the same name.

# Is a theme name safe in a path and a URL (D39)? "default" is not: it names
# the built-in, which is never read from disk.
proc rio::theme::valid_name {name} {
	if {$name eq "default"} { return 0 }
	return [regexp {^[A-Za-z0-9][A-Za-z0-9._-]*$} $name]
}

# The user's writable themes dir: where put/delete operate.
proc rio::theme::userdir {} {
	return [lindex [searchdirs] 0]
}

# Every loadable theme name: `default` first, then the *.theme files on the
# search path, each name once.
proc rio::theme::names {} {
	set seen [dict create]
	foreach d [searchdirs] {
		foreach f [glob -nocomplain -directory $d *.theme] {
			dict set seen [file rootname [file tail $f]] 1
		}
	}
	return [concat default [lsort [dict keys $seen]]]
}

# Write a theme file into the user dir. The text is parsed first, so the
# store holds no file that load would reject. Its `base` is not resolved
# here: the base may be installed later.
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

# Remove a theme from the user dir. A shipped theme is not removable.
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
