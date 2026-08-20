#!/usr/bin/env wish
#
# Headless test for sessions & preferences (AGENTS.md D31). Two halves, split by
# owner (see the "Sessions & preferences" block in rio-gui.tcl):
#
#   * PREFERENCES — theme/wrap/dock/chat — are GUI-owned, in a plain JSON file under
#     $XDG_CONFIG_HOME/rio. We drive the appliers and check the file, then reload.
#   * WORKSPACE — the open files + active tab — are CORE-owned (workspace.* ops),
#     keyed by project root under $XDG_DATA_HOME/rio. We exercise the full round-trip
#     against the DEFAULT spawned local core, then simulate a fresh launch and restore.
#
# Both XDG dirs are pointed at throwaway paths BEFORE the GUI boots, so the real
# ~/.config and ~/.local are never touched (the spawned core inherits our env, so its
# workspace store lands in the temp dir too). Needs a DISPLAY (Tk).
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/session.tcl

set ::env(RIO_GUI_HEADLESS) 1
set ::S [file join [file dirname [file tempfile]] riosess-[pid]]
file delete -force $::S
set ::env(XDG_CONFIG_HOME) [file join $::S config]
set ::env(XDG_DATA_HOME)   [file join $::S data]
set argv {}                          ;# no --connect ⇒ default: spawn a local core
source [file join [file dirname [info script]] .. rio-gui.tcl]

proc report_error {msg {code ""}} { set ::last_error $msg }

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} { puts "PASS  $label" } else {
		puts "FAIL  $label\n        got:  $got\n        want: $want" ; incr ::fails
	}
}
proc spit {path s} { set f [open $path w] ; puts -nonewline $f $s ; close $f }
proc slurp {path} { set f [open $path r] ; set s [::read $f] ; close $f ; return $s }
# The file paths of the currently-open tabs, in tab order.
proc open_paths {} {
	set out {}
	foreach id [gorder $::focus] { lappend out [bufget $id path] }
	return $out
}
# The buffer id whose path matches, or "" — tabs are keyed by id, not path.
proc row_id {path} {
	foreach id [gorder $::focus] { if {[bufget $id path] eq $path} { return $id } }
	return ""
}
# Ids of the file-backed tabs (skip the untitled scratch, path "").
proc open_file_ids {} {
	set out {}
	foreach id [gorder $::focus] { if {[bufget $id path] ne ""} { lappend out $id } }
	return $out
}

# --- a throwaway project tree on the core's (== our) filesystem --------------
set T [file normalize [file join $::S proj]]
file mkdir $T
spit [file join $T a.txt] "aaa\n"
spit [file join $T b.txt] "bbb\n"

# =============================================================================
# PREFERENCES
# =============================================================================
# Boot ran with rio_started=0, so the appliers that fired during startup did NOT
# persist: no prefs file exists yet (the boot-guard, proven by its absence).
ok "prefs: none written during boot" [file exists [prefs_path]] 0

# An applier persists: toggling wrap writes the file with the new value.
set ::wrap_lines 1
apply_wrap
ok "prefs: applier wrote the file" [file exists [prefs_path]] 1
ok "prefs: wrap recorded" [dict get [json::json2dict [slurp [prefs_path]]] wrap] 1

# Full round-trip. Scalars (theme, wrap, wrap_indent) persist directly; the dock
# arrangement rides as the `layout` object — the flat dock_side/dock_pane/chat_shown
# keys were retired (decision 3), so it's the object, not those mirrors, that round-trips.
# Set a distinctive state (dock on the RIGHT, git active, Search open), save, wipe, reload.
set ::theme_name solarized-dark
set ::wrap_lines 1
set ::wrap_indent 1
dock_set_side right                ;# files+git -> the right site
rio::layout::put right active git  ;# git the active tab
rio::layout::put right size 400    ;# a distinctive dock width (sizes persist, boot-safe)
apply_layout                       ;# derive the mirrors + persist
prefs_save
# clobber the live state IN MEMORY (no apply_layout — that would prefs_save over the
# file we just wrote), then load it back from disk and re-derive.
set ::theme_name default ; set ::wrap_lines 0 ; set ::wrap_indent 0
set ::layout [rio::layout::default]
ok "prefs: pre-reload is default" [rio::layout::dockside] left
prefs_load ; apply_layout
ok "prefs: theme reloaded"       $::theme_name solarized-dark
ok "prefs: wrap reloaded"        $::wrap_lines  1
ok "prefs: wrap_indent reloaded" $::wrap_indent 1
ok "prefs: dock side reloaded"   $::dock_side   right
ok "prefs: dock pane reloaded"   $::dock_pane   git
ok "prefs: dock size reloaded"   [rio::layout::get right size] 400

# A corrupt prefs file is ignored, not fatal: load leaves the current vars intact.
spit [prefs_path] "@@ not json @@"
set ::dock_side left
prefs_load
ok "prefs: corrupt file tolerated" $::dock_side left

# The boot guard: with rio_started=0, prefs_save is a no-op.
file delete [prefs_path]
set ::rio_started 0
set ::dock_side right
prefs_save
ok "prefs: guarded off during boot" [file exists [prefs_path]] 0
set ::rio_started 1

# =============================================================================
# WORKSPACE (per project, through the spawned core)
# =============================================================================
# No project open yet ⇒ nothing to resume.
ok "ws: empty before a project" [dict get [rio_call workspace.get {}] result open] {}

open_folder $T
# A project is open but only the empty scratch buffer exists (no path): saving now
# records nothing — untitled/unsaved tabs are omitted.
session_save
ok "ws: scratch omitted" [dict get [rio_call workspace.get {}] result open] {}

# Open two files; each do_open records the session through the core.
do_open [file join $T a.txt]
do_open [file join $T b.txt]
set ga [dict get [rio_call workspace.get {}] result]
ok "ws: both files saved" [dict get $ga open] [list [file join $T a.txt] [file join $T b.txt]]
ok "ws: active saved"     [dict get $ga active] [file join $T b.txt]

# Closing a file updates the saved set.
activate [row_id [file join $T b.txt]]
do_close
ok "ws: close updated the set" \
	[dict get [rio_call workspace.get {}] result open] [list [file join $T a.txt]]

# Reopen b.txt so the saved session has two files again for the restore test.
do_open [file join $T b.txt]

# Simulate a fresh launch: close the file tabs with saves suppressed (rio_started=0),
# so the persisted session still reflects {a,b} — exactly what a real restart sees.
# (Closing the last file mints a fresh scratch, so we close file-backed tabs only.)
set ::rio_started 0
foreach id [open_file_ids] { activate $id ; do_close }
set ::rio_started 1
ok "ws: torn down to a scratch" [open_paths] {{}}

session_restore
ok "ws: restore reopened both" [open_paths] [list [file join $T a.txt] [file join $T b.txt]]
ok "ws: restore focused active" [bufget $::cur path] [file join $T b.txt]

# --- cleanup -----------------------------------------------------------------
file delete -force $::S

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
