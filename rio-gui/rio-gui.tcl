#!/usr/bin/env wish
#
# rio-gui — the Tk frontend (AGENTS.md D1). A *thin view* (D3): it never edits
# its own text widget. Keystrokes become buffer.replace requests; the widget only
# changes when the core echoes a buffer.changed event back. Open/save go through
# the fs.* ops, undo/redo through edit.*, and buffers (tabs) through buffer.new /
# buffer.close. The frontend is ALWAYS a client to a core at the far end of a
# channel (D30): by default it spawns a private core as a child and talks over its
# stdio pipe; --connect attaches to a listening core over a socket. There is no
# in-process path — local and remote are the same code — so the only way text
# appears on screen is the core's own change event, arriving over the channel.
#
# Multi-buffer: the core owns the buffers (D3); the frontend keeps the per-buffer
# *view* state — tab order, which one is active, and each buffer's cursor/viewport
# (frontend-local per D22). One text widget shows the active buffer; switching
# tabs swaps its contents and restores that buffer's cursor.
#
# The view stays dumb robustly by RENAMING the real text-widget command and
# proxying it: Tk's class bindings still call `.t insert`/`.t delete`, the proxy
# turns those into protocol requests and suppresses the local edit. The character
# arrives as a proper Tcl argument, so every key — brackets, quotes, backslashes,
# braces — is handled identically, and paste/cut come along for free.
#
# Run:  wish rio-gui.tcl [file ...]

# The hard dependencies, through the gate that reports a missing one as a sentence
# rather than a stack trace (D116) — on Windows an uncaught one is a modal dialog
# nobody can read past. Tk goes through the plain `require`: if Tk is what's missing
# there is nothing to draw a dialog with, so stderr is all there is. json (tcllib)
# then goes through `gui_require`, which also puts it in a message box — under wish
# on Windows stderr has no console to land in.
source [file join [file dirname [info script]] .. rio-core deps.tcl]
rio::deps::require Tk
rio::deps::gui_require json

# OS file-drop (D86): plain Tk cannot receive a drop from the OS file manager — that
# capability lives only in the external tkdnd extension. Load it OPTIONALLY: where it is
# installed, dragging a file onto the window opens it (drop targets registered further
# down); where it is absent, rio-gui runs exactly as before, just without drag-to-open, so
# the hard dependency bar stays Tk + json. (The "pure Tk, no tkdnd" note for INTERNAL tab
# dragging still holds — that gesture needs no extension; OS file-drop is the one that does.)
set ::have_tkdnd [expr {![catch {package require tkdnd}]}]

# ---------------------------------------------------------------------------
# Transport (AGENTS.md D30): the GUI is ALWAYS a client to a core at the far end of
# a channel — it never embeds the core. Two channel kinds, one client code path:
#   default        spawn a private core as a child and talk over its stdio pipe.
#                  Local: its filesystem is ours, and its agent runs as us (D30).
#                  No listening socket ⇒ nothing on a shared host to connect to.
#   --connect h:p  attach to a listening core over TCP — the optional daemon mode
#                  (D29). Its filesystem may be elsewhere (e.g. SSH-forwarded), so
#                  file access goes through typed server-side paths (::core_remote).
# A test may pre-set ::connect_to (a host:port) to attach to an in-process server.
# Only the wire encoder is sourced here (Tk-free); the core lives in its own process.
# ---------------------------------------------------------------------------
# rio's sources are UTF-8, but Tcl 8.6 decodes a script with the SYSTEM encoding —
# cp1252 on a Western Windows install — so every non-ASCII literal, and with it the
# whole D27 glyph vocabulary, arrives mojibake ("rio - untitled" renders as
# "rio â€" untitled"). Setting the system encoding fixes every file sourced BELOW,
# but this file's own literals were decoded before line 1 ran, so re-read it once.
# The guard is the first executable statement: nothing has run yet, so re-sourcing
# repeats nothing. No-op where the system encoding is already UTF-8 (Linux, the
# BSDs, and Tcl 9 everywhere).
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}

set ::rio_dir [file dirname [info script]]
set ::rio_self [file normalize [info script]]   ;# this script, for spawning a new window
source [file join $::rio_dir .. rio-core wire.tcl]
source [file join $::rio_dir .. rio-core conf.tcl]  ;# repository manifests are conf DATA (D21/D39)
source [file join $::rio_dir .. rio-core version.tcl] ;# rio::version — ONE literal, shared (D123)

set ::core_endpoint "" ;# host:port when attached to a daemon (remote); "" when local (D30)
set ::last_connect  "" ;# last host:port typed into "Connect to Remote Core…" (dialog seed)

# --version, before anything opens a window or spawns a core: a packager and a bug
# report both want the number without launching a GUI. The core answers the same flag
# (server.tcl), and both print the one literal above.
if {[lsearch -exact $argv --version] >= 0} {
	puts "rio $rio::version"
	exit 0
}

if {![info exists ::connect_to]} { set ::connect_to "" }
set ci [lsearch -exact $argv --connect]
if {$ci >= 0} {
	set ::connect_to [lindex $argv [expr {$ci + 1}]]
	set argv [lreplace $argv $ci [expr {$ci + 1}]]   ;# don't treat it as a file arg
}
if {$::connect_to eq "" && [info exists ::env(RIO_CONNECT)]} {
	set ::connect_to $::env(RIO_CONNECT)
}

set ::reply_seq 0
if {$::connect_to ne ""} {
	# Attach to a listening core (daemon mode). Its filesystem may not be ours.
	set ::core_remote 1
	lassign [split $::connect_to :] host port
	if {$host eq "" || ![string is integer -strict $port]} {
		puts stderr "rio-gui: --connect expects host:port, got '$::connect_to'"
		exit 2
	}
	# A failed connect must not dump a Tcl stack trace: usually the core isn't running,
	# or — for a remote daemon, loopback-bound (D29) — there's no SSH tunnel yet.
	if {[catch {socket $host $port} ::core_chan]} {
		puts stderr "rio-gui: cannot reach a rio core at $::connect_to ($::core_chan)."
		puts stderr "  • Is a core listening there?     tclsh rio-core/server.tcl $port"
		puts stderr "  • If it's remote, tunnel first:  ssh -L $port:127.0.0.1:$port <server>"
		exit 1
	}
	set ::core_endpoint $::connect_to
	set ::last_connect  $::connect_to
} else {
	# Default: spawn a private local core and talk over its stdio (D30). We run under
	# wish, so find a Tk-free tclsh — in PATH, else one beside our own interpreter.
	set ::core_remote 0
	set _tclsh [lindex [auto_execok tclsh] 0]
	if {$_tclsh eq ""} {
		set _me [info nameofexecutable]
		set _g [file join [file dirname $_me] [string map {wish tclsh} [file tail $_me]]]
		set _tclsh [expr {[file executable $_g] ? $_g : "tclsh"}]
	}
	set ::core_cmd [list $_tclsh [file join $::rio_dir .. rio-core server.tcl] --stdio]
	if {[catch {open |$::core_cmd r+} ::core_chan]} {
		puts stderr "rio-gui: could not start a local core ($::core_chan)."
		exit 1
	}
}
fconfigure $::core_chan -buffering line -blocking 0 -translation lf -encoding utf-8
fileevent $::core_chan readable core_reader

# Per-buffer view state. The core holds the text; we hold the rest. `cursor`/`yview`
# are per-buffer (a buffer lives in exactly one editor group in v1, D33), while tab
# order and the active buffer are per-GROUP — see ::grp below.
set ::buffers {} ;# id -> {path <s> meta <dict> modified <0|1> cursor <idx> yview <frac>}

# Editor groups (AGENTS.md D33). The center holds one or two editor groups side by
# side; each is an independent text widget with its own tab strip, active buffer,
# and highlight cache. In v1 a buffer belongs to exactly one group. Phase 2 runs a
# SINGLE group (group 0), so the behaviour is identical to the pre-split editor;
# phase 3 adds the second group and the split layout.
#   ::grp   id -> a dict of the group's state:
#     w       real text-widget command (the renamed Tk widget, edits bypass the proxy)
#     path    the Tk widget path (the proxy) — for winfo/focus/bind
#     frame   the group's container frame (.eg<id>)
#     tabs    the group's tab-strip frame (.eg<id>.tabs)
#     cur     active buffer id in this group
#     order   buffer ids in this group, in tab order
#     hl_*    the per-group incremental-highlight cache (was the ::hl_* globals, D32)
set ::grp    {} ;# group id -> group-state dict (above)
set ::groups {} ;# group ids, left-to-right
set ::focus  "" ;# the focused group id (::cur mirrors its active buffer)
set ::cur    "" ;# active buffer of the FOCUSED group — a mirror, kept by activate/focus_group

# The side dock hosts ONE of the panes at a time (files | git) and sits on one
# side of the editor (left | right). Both are user choices (View menu), not
# dictated; left + files is the default.
set ::dock_side left   ;# left | right — which edge the dock occupies
set ::dock_pane files  ;# files | git  — which pane is currently shown
set ::wrap_lines 0     ;# 0 = no wrap (horizontal scrollbar) | 1 = word wrap
set ::wrap_indent 0    ;# with wrap on: 0 = only line 1 indented | 1 = align wrapped lines
set ::line_numbers 1   ;# 1 = show a line-number gutter down each editor group (View menu)
set ::highlight_current_line 1 ;# 1 = tint the logical line the caret sits on (View menu; per group)
set ::relative_line_numbers 0 ;# 1 = gutter shows each line's distance from the caret line (hybrid: absolute on the caret line); a modifier on ::line_numbers (View menu)
set ::show_hidden 0    ;# 1 = show dotfile / hidden entries in the Files pane (View menu; default hides, like ls)
set ::col_on 0         ;# column/block editing (Ctrl+Shift+drag) enabled? (D40)
set ::col_active 0     ;# a column selection is currently live
set ::col_w ""         ;# the editor PROXY path the column selection lives on
set ::col_anchor ""    ;# the fixed end, a Tk index "line.col"
set ::col_caret ""     ;# the moving end, a Tk index "line.col"
set ::col_bars {}      ;# placed thin caret-bar frames (zero-width column, one/line)
set ::col_blink ""     ;# after-id of the caret blink loop ("" when not blinking)
set ::col_blink_on 1   ;# blink phase: bars shown (1) or hidden (0)
set ::col_insw ""      ;# saved widget -insertwidth while the native bar is hidden
set ::chat_shown 1     ;# agent chat pane visible? (a site-visibility mirror; apply_chat_visibility)
# Per-pane "shown" mirrors for the View-menu toggle checkbuttons: 1 when the pane's
# site is visible AND the pane is its active tab. apply_layout keeps them in sync.
set ::shown_files 0 ; set ::shown_git 0 ; set ::shown_chat 0 ; set ::shown_search 0
set ::edit_mode windows   ;# active editing mode (D38/D41): windows ships; emacs/vi & other drop-ins install as extensions
set ::editmode_active ""  ;# the mode currently attached to the RioMode tag ("" before boot)
set ::editmode_status ""  ;# the mode's status-bar segment ("-- INSERT --" in vi; "" otherwise)
set ::theme_name default ;# active colour theme — a persisted preference; do_theme records it (D31)
set ::last_project ""    ;# last folder opened on a LOCAL core — persisted, reopened on next launch (D88)
set ::theme_choice default ;# what the Preferences button shows: tracks theme_name, snaps back on a failed switch (D39)
# Tab-strip overflow (D57). When a group has more tabs than fit its width, `scroll`
# (the default) keeps them on ONE line and shows ◂ ▸ arrows to page the visible window;
# `multi` wraps them onto as many rows as needed. A persisted View preference; the Tabs
# menu (always reachable, whatever the width) lists every open buffer regardless.
set ::tab_layout scroll   ;# scroll | multi — see tabstrip_layout
set ::tabstrip_w [dict create] ;# per-group last laid-out strip width, to skip no-op <Configure>s
# Editor-font override (D56). The document view's font is a NAMED font (RioEditorFont)
# the theme supplies; these are the user's persisted override ON TOP of it — "" / 0
# means "follow the theme". editor_theme_* records the theme's own values so a reset
# (or a theme switch) has something to fall back to. See apply_editor_font.
set ::editor_font_family ""  ;# user family override, "" = use the theme's
set ::editor_font_size   0   ;# user size override, 0 = use the theme's
set ::editor_theme_family monospace ;# the active theme's editor family (apply_theme records it)
set ::editor_theme_size   12        ;# the active theme's editor size
set ::chat_turn_open 0 ;# mid-stream: an assistant block is open, deltas appending
set ::pending_turn ""  ;# turn id of a proposed edit awaiting Approve/Reject (D26 s5)
# The agent "working" indicator (D82): while a turn is in flight the .chat.status.busy label
# animates a cycling retro-productivity phrase with a "Please wait…" dot cadence, so a
# multi-second wait on the LLM never looks frozen. Pure Tk (an `after` loop) — no deps.
set ::chat_busy       0    ;# a turn is being worked (animation running)
set ::chat_busy_after ""   ;# the pending `after` id, so it can be cancelled
set ::chat_busy_frame 0    ;# tick counter: drives the dots and the phrase change
set ::chat_busy_word  ""   ;# the phrase currently shown
# Loading phrases in the spirit of 90s/2000s productivity software — data, edit at will.
set ::chat_busy_words {
	"Reticulating splines" "Defragmenting drive" "Recalculating cells" "Compacting database"
	"Rebuilding index" "Checking spelling" "Consulting the Office Assistant" "Merging mail"
	"Collating pages" "Formatting document" "Optimizing memory" "Cross-referencing"
	"Autosaving" "Synergizing deliverables" "Tabulating results" "Calibrating"
	"Negotiating baud rate" "Buffering" "Encoding" "Paginating" "Word-wrapping"
	"Generating WordArt" "Sorting records" "Indexing" "Scanning for viruses" "Twiddling bits"
	"Warming up the CRT" "Rendering clip art"
}
set ::agent_auto_accept 0 ;# skip the approval gate for proposed edits (Settings)
set ::agent_plan_mode 0   ;# plan mode: the agent may read and plan, not change (D101)
set ::agent_mode_ui review ;# plan|review|auto — the two flags above as the three states the
                           ;# UI offers; DERIVED by agent_mode_sync, never a truth of its own (D102)
set ::compare_shown 0     ;# compare/diff view active? (.cmp shown instead of .ed; D28)
set ::agent_compare_complex 1 ;# open complex agent edits in the compare view (Settings; D28)
set ::tls_unchecked 0     ;# the core's choice: https on a tcltls without host-name checks (D114)
set ::tls_checks_hostname 1 ;# does the core's tcltls check names? (tls.settings; picks the hint)
set ::tls_version ""      ;# the core's tcltls version, "" when it has none
set ::agent_selection_menu 1 ;# offer "Change with Agent…" in the editor's context menu (prefs.json; D113)
set ::compare_threshold 8 ;# diff lines above which an agent edit counts as "complex"
set ::cmp_syncing 0       ;# guard against re-entrant scroll sync between the compare panes
set ::rio_started 0       ;# false during boot: view-state/workspace writes wait until startup finishes (D31)
# The per-group highlight cache (D32) now lives in ::grp under these keys, one set per
# editor group (see new_group_state): hl_scan, hl_lang, hl_pending, hl_enter, hl_dirty,
# hl_lastchanged, hl_scanned, hl_lo, hl_hi, hl_vpending. Same meanings as the old ::hl_*
# globals, keyed per widget.
set ::hl_margin 50   ;# lines highlighted beyond each edge of the viewport (D126)
set ::hl_chunk 1000  ;# lines a single scan pass may walk before yielding to the event loop

# ---------------------------------------------------------------------------
# Tool-panel registry (AGENTS.md D35, incremental path step (a)). The four tool
# panes rio ships — files, git, the agent chat, and the Search results strip — are
# *declared as data* here rather than hand-wired at their call sites: same idiom as
# the core's highlighter/mode/rich-list registries. Each panel is {title, site,
# body, refresh}: `site` is its preferred dock site (left|right|bottom — the eventual
# D35 sites; the actual, user-movable placement becomes the persisted `layout` object
# in step (b), not modelled here), `body` its body-widget path, `refresh` the proc
# that repaints it ("" for the event-driven chat). The registry is the queryable
# state seed (decision #6): smoke asserts a panel's identity/site without a mapped
# window. Placement is untouched at this step — this only names the four panes and
# routes their refresh through one dispatch; the sites/tab-strips/drag come in
# steps (b)/(c). Files and git are two distinct panels that share one side site.
# ---------------------------------------------------------------------------
namespace eval rio::panel {
	variable order {}       ;# registered ids, in registration order
	variable meta           ;# id -> {title site body refresh}
	array set meta {}
}
# Declare a panel. Idempotent (re-registering the same id is a no-op) so a reloaded
# GUI in one interp doesn't duplicate. `spec` fills in over the defaults.
proc rio::panel::register {id spec} {
	variable order ; variable meta
	if {[info exists meta($id)]} return
	lappend order $id
	set meta($id) [dict merge {title {} site {} body {} refresh {}} $spec]
}
proc rio::panel::ids {}         { variable order ; return $order }
proc rio::panel::exists {id}    { variable meta ; info exists meta($id) }
proc rio::panel::get {id}       { variable meta ; return $meta($id) }
proc rio::panel::field {id key} { variable meta ; dict get $meta($id) $key }
# Repaint one panel through its declared refresh hook (a no-op when it has none, or
# when the id is unknown). The single dispatch the pane call sites route through.
proc rio::panel::refresh {id} {
	variable meta
	if {![info exists meta($id)]} return
	set hook [dict get $meta($id) refresh]
	if {$hook ne ""} { uplevel #0 $hook }
}

# ---------------------------------------------------------------------------
# The dock layout (AGENTS.md D35, incremental path step (b)). One persisted
# `layout` object (::layout) is the single source of truth for all non-document
# placement: three sites (left|right|bottom), each with an ordered `panels` list,
# an `active` panel, `visible`, and `size` (width for the side sites, height for
# the bottom). apply_layout DERIVES the pack from this state (decision #6 — state
# is authoritative, pack is derived); the old ::dock_side / ::dock_pane /
# ::chat_shown / ::search_shown globals live on only as read *mirrors* that
# apply_layout keeps in sync, because the View-menu radio/checkbuttons bind them
# as -variable and several call sites (on_fs_changed, refresh_dock) read them.
# v1 invariants: files+git move together and are the only pair selected via a
# site's `active`; chat is the right site's tenant; the Search strip is the
# bottom site's, booting hidden (on-demand). Sizes are newly persisted.
# ---------------------------------------------------------------------------
namespace eval rio::layout {}

# The seed layout — also the normalize/migrate base. Side widths (220 dock,
# 340 chat), bottom height (160 search).
# The first-run layout a brand-new user sees (no prefs yet): only the Files tab is
# shown, on the left; Git lives there too but starts HIDDEN (no tab), and the Agent
# (right) and Search (bottom) start hidden as well — so a fresh rio is just the editor
# and the file tree. `hidden` lists the panels with no tab; `visible` is derived from
# it (a site shows iff it has a non-hidden pane). Everything past this is the user's
# own choice and persists (prefs.json).
proc rio::layout::default {} {
	return [dict create sites [dict create \
		left   [dict create panels {files git} hidden {git}    active files  visible 1 size 220] \
		right  [dict create panels {chat}      hidden {chat}   active chat   visible 0 size 340] \
		bottom [dict create panels {search}    hidden {search} active search visible 0 size 160]]]
}
proc rio::layout::get {site key}   { dict get $::layout sites $site $key }
proc rio::layout::put {site key v} { dict set ::layout sites $site $key $v }
# Which site holds panel `id` (its first membership), or "" if none.
proc rio::layout::site_of {id} {
	dict for {s d} [dict get $::layout sites] {
		if {$id in [dict get $d panels]} { return $s }
	}
	return ""
}
# The side (left|right) the files/git dock sits on.
proc rio::layout::dockside {} { return [site_of files] }
# A copy of `list` with any of `ids` removed (order preserved).
proc rio::layout::_without {list ids} {
	set out {} ; foreach x $list { if {$x ni $ids} { lappend out $x } }
	return $out
}
# A site's `hidden` list (panels present but with NO tab), defaulting to empty.
proc rio::layout::hidden_of {site} {
	if {[dict exists $::layout sites $site hidden]} { return [dict get $::layout sites $site hidden] }
	return {}
}
# The panels currently SHOWN in `site` (a tab each) — membership minus hidden, order kept.
proc rio::layout::shown_panels {site} {
	return [_without [get $site panels] [hidden_of $site]]
}
# Give panel `id` a tab in `site` (remove it from hidden) / take its tab away (add it).
proc rio::layout::unhide {site id} { put $site hidden [_without [hidden_of $site] [list $id]] }
proc rio::layout::hide   {site id} {
	set h [hidden_of $site]
	if {$id ni $h} { lappend h $id }
	put $site hidden $h
}
# Is panel `id` shown — i.e. does it have a tab (is it loaded), regardless of which
# tab is foreground? "Hide" a pane means no tab at all, so the View-menu checkmark
# tracks tab presence, not the active/foreground selection.
proc rio::layout::shown {id} {
	set s [site_of $id]
	if {$s eq ""} { return 0 }
	return [expr {$id ni [hidden_of $s]}]
}

# Build a layout from the pre-step-(b) flat keys, over the default: dock_pane ->
# the dock site's active; chat_shown -> whether the Agent has a tab; dock_side ->
# which side holds files/git. dock_side=right unifies the dock into the right site
# alongside chat (decision 1a). The pre-layout model showed a tab for EVERY dock
# member (git was a background tab, not hidden), so an upgraded dock shows both files
# and git — distinct from the new first-run default, which hides git. Search stays
# on-demand (hidden). Sizes take defaults (were ephemeral before).
proc rio::layout::migrate {prefs} {
	set L [default]
	set side [expr {[dict exists $prefs dock_side] && [dict get $prefs dock_side] eq "right" ? "right" : "left"}]
	set pane [expr {[dict exists $prefs dock_pane] && [dict get $prefs dock_pane] eq "git" ? "git" : "files"}]
	set chat [expr {[dict exists $prefs chat_shown] && ![dict get $prefs chat_shown] ? 0 : 1}]
	dict set L sites left   hidden {}          ;# both files and git shown (old behaviour)
	dict set L sites bottom hidden {search}    ;# Search on-demand
	if {$side eq "right"} {
		dict set L sites left  panels {}
		dict set L sites left  active ""
		dict set L sites right panels {files git chat}
	}
	dict set L sites $side active $pane                       ;# the dock's files|git choice
	dict set L sites right hidden [expr {$chat ? {} : {chat}}] ;# Agent tab per chat_shown
	return $L
}

# Repair a persisted or migrated layout into a well-formed one: fill missing keys
# from the default, drop unknown sites, ensure each registered panel appears in
# exactly one site (unclaimed panels land in their registry-preferred site), clamp
# `hidden` to real members, DERIVE `visible` from what's shown (a site is on-screen
# iff it has a non-hidden pane), and keep `active` a SHOWN member. Old persisted
# layouts predate `hidden`; for a site without it we recover it from the stored
# `visible` (a collapsed dock — visible 0 — becomes all-hidden, else all-shown).
# Used at runtime after a relocation; the boot-only "Search starts hidden" is in boot.
proc rio::layout::normalize {L} {
	set out [default]
	set had_hidden {}   ;# sites whose source dict supplied an explicit `hidden`
	if {[dict exists $L sites]} {
		dict for {s d} [dict get $L sites] {
			if {$s ni {left right bottom}} continue
			foreach k {panels active visible size hidden} {
				if {[dict exists $d $k]} { dict set out sites $s $k [dict get $d $k] }
			}
			if {[dict exists $d hidden]} { lappend had_hidden $s }
		}
	}
	# Membership: each registered panel in exactly one site (first claim wins);
	# unclaimed panels return to their registry-preferred site.
	set seen {}
	dict for {s d} [dict get $out sites] {
		set keep {}
		foreach p [dict get $d panels] {
			if {[rio::panel::exists $p] && $p ni $seen} { lappend keep $p ; lappend seen $p }
		}
		dict set out sites $s panels $keep
	}
	foreach p [rio::panel::ids] {
		if {$p ni $seen} {
			set pref [rio::panel::field $p site]
			dict set out sites $pref panels [concat [dict get $out sites $pref panels] [list $p]]
			lappend seen $p
		}
	}
	dict for {s d} [dict get $out sites] {
		set ps [dict get $out sites $s panels]
		# Recover `hidden` for an old layout that lacks it: visible 0 -> the dock was
		# collapsed (all panels hidden), visible 1/absent -> all shown.
		if {$s ni $had_hidden} {
			set vis [expr {[dict exists $d visible] ? [dict get $d visible] : 1}]
			dict set out sites $s hidden [expr {$vis ? {} : $ps}]
		}
		# Clamp hidden to current members (read from $out, not the global ::layout).
		set cur_hidden [expr {[dict exists $out sites $s hidden] ? [dict get $out sites $s hidden] : {}}]
		set hid {} ; foreach p $cur_hidden { if {$p in $ps} { lappend hid $p } }
		dict set out sites $s hidden $hid
		# Derive visible from what's shown; keep active a shown pane.
		set show [_without $ps $hid]
		dict set out sites $s visible [expr {[llength $show] ? 1 : 0}]
		if {[dict get $out sites $s active] ni $show} {
			dict set out sites $s active [expr {[llength $show] ? [lindex $show 0] : ""}]
		}
	}
	return $out
}
# normalize + the boot-time policy: the Search strip is an on-demand surface, so the
# bottom site starts hidden *when Search is its only tenant*. But once the user has
# docked other panels there (e.g. dragged Git down), honour the persisted visibility
# — otherwise those panels would be stranded in a site nothing reopens. Used only at
# prefs_load; runtime relocations use normalize so a panel moved to the bottom shows.
proc rio::layout::boot {L} {
	set out [normalize $L]
	if {[dict get $out sites bottom panels] eq "search"} {
		dict set out sites bottom hidden {search}
	}
	return [normalize $out]
}
# Encode ::layout as a JSON object fragment for prefs.json. `panels`/`hidden` are
# string arrays, `visible` a JSON boolean (derived, kept for compat), `size` a bare
# integer; the shape mirrors what normalize accepts on read (json2dict yields nested
# dicts/lists). `hidden` is the authoritative per-pane tab-presence state.
proc rio::layout::json {} {
	set sites {}
	dict for {s d} [dict get $::layout sites] {
		set obj [format {{"panels":%s,"hidden":%s,"active":%s,"visible":%s,"size":%d}} \
			[rio::wire::strarr [dict get $d panels]] \
			[rio::wire::strarr [hidden_of $s]] \
			[rio::wire::str [dict get $d active]] \
			[expr {[dict get $d visible] ? "true" : "false"}] \
			[expr {int([dict get $d size])}]]
		lappend sites "[rio::wire::str $s]:$obj"
	}
	return "{\"sites\":{[join $sites ,]}}"
}
set ::layout [rio::layout::default]   ;# real value is set by prefs_load (migrate/adopt)

proc bufget {id key} { dict get $::buffers $id $key }
proc bufset {id key val} { dict set ::buffers $id $key $val }

# ---------------------------------------------------------------------------
# Editor-group accessors (AGENTS.md D33). A group is a dict in ::grp; these keep the
# editor procs terse — most take a group id defaulting to the focused one, resolve
# its widget/cache through here, and never touch ::grp directly.
# ---------------------------------------------------------------------------
proc fg {}         { return $::focus }                 ;# the focused group id
proc gget {g k}    { dict get $::grp $g $k }
proc gset {g k v}  { dict set ::grp $g $k $v }
proc gw {g}        { dict get $::grp $g w }            ;# real widget command (bypasses the proxy)
proc gcur {g}      { dict get $::grp $g cur }          ;# active buffer id in group g
proc gorder {g}    { dict get $::grp $g order }        ;# tab order in group g
proc fgw {}        { gw $::focus }                     ;# the focused group's real widget

# Which group currently shows buffer `id`, or "" if none (v1: at most one group).
proc group_of {id} {
	foreach g $::groups { if {[lsearch -exact [gorder $g] $id] >= 0} { return $g } }
	return ""
}

# A fresh group-state dict: no buffer yet, an empty tab order, a clean highlight cache.
# `w`/`path`/`frame`/`tabs` are filled in by make_editor_group once the widgets exist.
proc new_group_state {} {
	return [dict create w "" path "" frame "" tabs "" cur "" order {} taboff 0 \
		hl_scan "" hl_lang "" hl_pending 0 hl_enter {} \
		hl_dirty 0 hl_lastchanged 0 hl_scanned 0 \
		hl_lo 0 hl_hi 0 hl_vpending 0]
}

# ---------------------------------------------------------------------------
# The single seam to the core (AGENTS.md D2/D30). One op call, one response; any
# events the op produced arrive asynchronously on the channel and are fed to
# dispatch_event. The core is always at the far end of ::core_chan (a pipe to a
# spawned core, or a daemon socket) — there is no in-process path, so local and
# remote are the same code.
# ---------------------------------------------------------------------------
proc rio_call {op params {timeout_ms 0}} {
	return [core_call $op $params $timeout_ms]
}

# Apply one core event to the view. Every event the core broadcasts arrives here
# over the channel (D30) — including the agent's live stream (D26): an agent turn
# is now ordinary broadcast traffic, so agent.* events route to the chat transcript
# and a turn's approved-edit buffer.changed lands in the same buffer.changed case.
# buffer.changed redraws whichever editor group is showing the changed buffer (D33):
# an edit — a keystroke echo or an agent edit — lands in the group displaying that
# buffer, even if it is not the focused one. A buffer no group shows (closed, or
# never opened here) is ignored safely; it reloads from the core when next activated.
proc dispatch_event {ev} {
	set name [dict get $ev event]
	if {[string match agent.* $name]} { chat_event $ev ; return }
	switch -- $name {
		buffer.changed {
			set p [dict get $ev params]
			set g [group_of [dict get $p buffer]]
			if {$g ne ""} { apply_change $g $p }
		}
		project.opened { on_project_opened [dict get $ev params] }
		fs.changed     { on_fs_changed [dict get $ev params] }
	}
}

# A file appeared or changed on disk outside the editor's own save — an agent fs.write
# (D26), which is not backed by an open buffer so no buffer.changed fires (D47). Repaint
# the dock so the new file, and any git-status shift, shows without a manual reload. The
# files pane is a tree from the project root (D87), so it repaints when the change lands in
# a directory currently on screen (the root or an unfolded dir — nav_dir_visible); the git
# pane's status is project-wide, so it always repaints.
# The user's own Save needs nothing here: it refreshes locally via do_save and goes
# through file.save, which emits no fs.changed — so there is no double repaint.
# One op can announce many changed paths in one go — a discard-all rewrites every changed
# file (D94), a rename announces both ends. A repaint is itself a nested core call, so
# repainting per event would cost one round trip PER PATH — the very N-round-trip price D93
# went to git to avoid. So collect the paths and repaint ONCE, a beat later.
# A *timer*, not `after idle`: core_reader takes one line per readable event, and Tcl runs
# idle handlers between two of those, so an idle callback splits a burst instead of
# coalescing it (measured: 2 repaints for 3 paths). The delay has to clear the gap a socket
# can put between two lines of the SAME burst — a delayed ACK inserts ~40ms, which is what
# a 25ms window kept tripping over — while staying under the eye's notice.
set ::fs_changed_paths {}   ;# paths announced since the last repaint
set ::fs_changed_after  ""  ;# pending repaint timer; "" while none is armed
set ::fs_changed_delay  60  ;# ms; > a socket's ~40ms delayed-ACK gap, < a noticeable lag
set ::stale_checking    0   ;# a stale check is running (its modals run the event loop)
set ::stale_retry       ""  ;# a deferred stale check, waiting for the channel to go quiet
proc on_fs_changed {p} {
	if {![dict exists $p path]} return
	lappend ::fs_changed_paths [dict get $p path]
	if {$::fs_changed_after eq ""} {
		set ::fs_changed_after [after $::fs_changed_delay fs_changed_settle]
	}
}
proc fs_changed_settle {} {
	# Never land in the middle of another op's round trip: a repaint is itself a core call,
	# and nesting one inside another's vwait buys nothing — the op in flight may well
	# change what we would paint. Re-arm and land between ops. (check_stale_buffers below
	# defers for its own, sharper reason.)
	if {[array size ::pending]} {
		set ::fs_changed_after [after $::fs_changed_delay fs_changed_settle]
		return
	}
	set paths $::fs_changed_paths
	set ::fs_changed_paths {}
	set ::fs_changed_after ""
	# An open tab may be looking at one of those paths (D94). Asked once for the whole
	# burst, and before the repaint, so a reload's own buffer.changed events are applied
	# while the pane work is still ahead of us rather than interleaved with it.
	check_stale_buffers
	if {$::dock_pane eq "git"} {
		refresh_git
		return
	}
	if {$::nav_root eq ""} return
	# Compare the core's paths as strings: both sides came FROM the core, already
	# normalized there, so a client-side [file normalize] adds nothing — and on a
	# Windows client against a POSIX core it rewrites "/home/jka" to "C:/home/jka".
	# It matched only because both operands were mangled identically.
	foreach path $paths {
		if {[nav_dir_visible [file dirname $path]]} { populate_nav ; return }
	}
}

# An op call over the channel: write {id, op, params} as one JSON line (the same
# escaping the server replies with, rio::wire), then run the event loop until the
# reply with our id lands. Ids are unique per call, so a keystroke typed while we
# wait — itself a nested rio_call — resolves on its own id without disturbing this one.
proc core_call {op params {timeout_ms 0}} {
	set id r[incr ::reply_seq]
	set ::pending($id) [clock milliseconds] ;# when it was sent — watch_tick ages it (D37)
	if {[catch {
		puts $::core_chan "{\"id\":[rio::wire::str $id],\"op\":[rio::wire::str $op],\"params\":[rio::wire::obj $params]}"
		flush $::core_chan
	}]} {
		unset -nocomplain ::pending($id)
		core_lost
		return [dict create id $id ok false \
			error [dict create code disconnected message "no connection to the core"]]
	}
	# A half-open link (a stale `ssh -L` forward: the socket is up, but nothing answers
	# and no EOF ever arrives) would leave this vwait blocked forever. An optional
	# deadline lets the caller bound the first exchange: on expiry we synthesise a
	# `timeout` reply so the vwait returns and the caller can report it, not hang.
	set timer ""
	if {$timeout_ms > 0} {
		set timer [after $timeout_ms [list set ::reply($id) [dict create id $id ok false \
			error [dict create code timeout message "the core did not respond in time"]]]]
	}
	vwait ::reply($id)
	if {$timer ne ""} { after cancel $timer }
	unset -nocomplain ::pending($id)
	set resp $::reply($id)
	unset ::reply($id)
	return $resp
}

# The channel reader: each line is either an event — dispatched to the view at once —
# or a reply, handed to the rio_call waiting on its id. Junk lines are ignored; EOF
# means the core went away (a crashed child, or a dropped daemon).
proc core_reader {} {
	if {[catch {gets $::core_chan line} n]} { core_lost ; return }
	if {$n < 0} { if {[eof $::core_chan]} { core_lost } ; return }
	set ::last_rx [clock milliseconds] ;# any received line proves the link alive (D37)
	if {[string trim $line] eq ""} return
	if {[catch {json::json2dict $line} msg]} return
	if {[dict exists $msg event]} {
		dispatch_event $msg
	} elseif {[dict exists $msg id]} {
		# Only wake a call still waiting: a reply arriving after its call already
		# timed out (see core_call) is dropped, not left as a stale ::reply entry.
		set id [dict get $msg id]
		if {[info exists ::pending($id)]} { set ::reply($id) $msg }
	}
}

# The channel closed (`eof`) — or the watchdog below declared it dead (`stale`).
# Report it once, stop reading, and wake any call blocked on a reply (with a
# disconnected error) so the GUI never hangs. The editor stays up so nothing in
# view is lost; further ops fail fast through core_call.
proc core_lost {{why eof}} {
	if {![info exists ::core_chan]} return
	watch_stop
	catch {fileevent $::core_chan readable {}}
	catch {close $::core_chan}
	unset -nocomplain ::core_chan
	foreach id [array names ::pending] {
		set ::reply($id) [dict create id $id ok false \
			error [dict create code disconnected message "lost the connection to the core"]]
	}
	if {$why eq "stale"} {
		report_error "The link to the core at $::core_endpoint went stale — the socket is open but nothing answers (usually a dropped SSH tunnel).\n\nRe-establish the tunnel, then reconnect via File ▸ Connect to Remote Core…" disconnected
	} else {
		report_error "Lost the connection to the core (it exited or the link dropped)." disconnected
	}
}

# ---------------------------------------------------------------------------
# Stale-link watchdog (AGENTS.md D37). A half-open socket — the classic stale
# `ssh -L` forward — accepts writes and never EOFs, so without this the GUI only
# learns the link is dead when TCP gives up, minutes later. hello_core already
# bounds the FIRST exchange for exactly that reason; this extends the same idea
# to the whole session, purely at the protocol layer (`after` timers + one cheap
# op — no socket options, no keepalive). Armed only for a socket-attached core:
# a spawned child is a pipe, and a pipe delivers EOF the moment the core dies.
# Every watch_interval it checks, in order:
#   1. a reply pending longer than reply_overdue — no op legitimately waits that
#      long (streaming ops ack at once and stream as events), so the link is dead;
#   2. nothing pending and nothing received for a full interval — probe with a
#      bounded session.hello; only a `timeout` counts (a write failure already
#      went through core_lost inside core_call).
# The thresholds are globals so the headless suite can shrink them. reply_overdue
# is generous on purpose: the core is single-threaded and a big reply on a slow
# tunnel counts its transfer time.
set ::watch_interval 10000 ;# ms between checks
set ::reply_overdue  25000 ;# a reply pending longer than this means a dead link
set ::ping_timeout    8000 ;# bound on the idle probe (same as hello_core's greeting)
set ::watch_timer ""       ;# pending `after` id; "" while disarmed
set ::last_rx 0            ;# [clock milliseconds] of the last line core_reader saw

proc watch_start {} {
	watch_stop
	set ::last_rx [clock milliseconds]
	set ::watch_timer [after $::watch_interval watch_tick]
}
proc watch_stop {} {
	if {$::watch_timer ne ""} { after cancel $::watch_timer ; set ::watch_timer "" }
}
proc watch_tick {} {
	set ::watch_timer ""
	if {![info exists ::core_chan]} return
	set now [clock milliseconds]
	foreach id [array names ::pending] {
		if {$now - $::pending($id) > $::reply_overdue} { core_lost stale ; return }
	}
	if {[array size ::pending] == 0 && $now - $::last_rx >= $::watch_interval} {
		set resp [core_call session.hello {} $::ping_timeout]
		if {![dict get $resp ok] && [dict get $resp error code] eq "timeout"} {
			core_lost stale ; return
		}
	}
	if {[info exists ::core_chan]} {
		set ::watch_timer [after $::watch_interval watch_tick]
	}
}

# Surface a core error to the user (the {code, message} taxonomy, AGENTS.md O2).
# One seam, so every failed op shows a dialog instead of crashing a caller that
# assumed success — and the headless smoke can override it to capture errors
# without a modal blocking the run.
proc report_error {message {code ""}} {
	tk_messageBox -icon error -type ok -title rio \
		-message [expr {$code eq "" ? $message : "$message  ($code)"}]
}

# Run an op that is expected to succeed and return its result, or "" after
# surfacing the error. For the internal "can't fail in normal use" calls (new,
# undo/redo): a vanished buffer or a bug becomes a dialog, not a missing-`result`
# crash. do_open/do_save inspect `ok` themselves — they have real recovery. (None
# of these ops returns an empty result on success, so "" is an unambiguous fail.)
proc rio_result {op params} {
	set resp [rio_call $op $params]
	if {[dict get $resp ok]} { return [dict get $resp result] }
	set e [dict get $resp error]
	report_error [dict get $e message] [dict get $e code]
	return ""
}

# The wire protocol version this GUI speaks (AGENTS.md O2: the integer
# session.hello reports; it bumps on a breaking change). Checked against every
# core we attach to — a spawned child can't realistically mismatch (same repo),
# but a daemon reached over --connect or an in-place reconnect (D30) can be any
# age, and a version skew otherwise surfaces as ops quietly misparsing.
set ::rio_protocol  2
set ::core_protocol ""   ;# what the attached core reported (for the title of a bug report)

# The RELEASE version of the attached core (its session.hello `version`, D123). Distinct
# from $rio::version, which is THIS checkout's: a spawned core is always the same tree,
# but one reached over --connect can be any build, and then the two differ and About says
# so. "" for a core too old to report it — the D19 rule, so absence is a fallback, never
# an error.
set ::core_version ""

# The root of the CORE's filesystem, from its session.hello (re-read on reconnect).
# The GUI must not compute this: it browses the core's disk (D30), and the core may be
# a different platform — "/" is right for a POSIX core and unlistable on a Windows one.
# "/" is only the pre-greeting default and the fallback for a core too old to say.
set ::core_fsroot "/"

# Greet the core (session.hello) and warn once if it speaks a different protocol.
# Runs as the FIRST op on a live channel — at startup and after an in-place reconnect
# — so it doubles as the liveness gate: socket(2) to a stale `ssh -L` forward succeeds
# with nothing behind it, and an unbounded op would then hang on a blank window. We
# bound the greeting (8 s); if the core never answers we say why instead of freezing.
# `fatal` (startup) exits after the message — there's nothing to fall back to; reconnect
# leaves the old session up. Returns 1 if the core greeted us, 0 otherwise.
proc hello_core {{fatal 0}} {
	set resp [rio_call session.hello {} 8000]
	if {![dict get $resp ok]} {
		set code [dict get $resp error code]
		if {$::core_remote} {
			set msg [expr {$code eq "timeout" \
				? "Connected to $::core_endpoint, but no rio core answered.\n\nThe socket opened — most likely a stale SSH tunnel, or no core is running behind it. Check that the tunnel is still up (ssh -L …) and a core is listening on the server." \
				: "The core didn't answer session.hello: [dict get $resp error message]"}]
		} else {
			# A SPAWNED core that never greets did not survive its own start-up — it
			# exited (an `eof`, so `disconnected`) or wedged before the handshake. The
			# generic "lost the connection" told the user nothing they could act on,
			# and the child's stderr goes to a console that `wish` on Windows does not
			# have. So hand them the command: run it themselves and the core's own
			# complaint — a missing package, most often — is right there. (Capturing
			# the child's stderr into the dialog was weighed and refused: it would put
			# a temp file and its lifecycle on the spawn path that runs every start.)
			set msg "rio could not start its core.\n\nThe core exited or stopped\
				responding while starting up. To see why, run it by hand:\n\n \
				[join $::core_cmd { }]\n\nA missing dependency is the usual cause —\
				see INSTALL.md §1."
		}
		if {$fatal} { catch {wm withdraw .} ; report_error $msg $code ; exit 1 }
		report_error $msg $code
		return 0
	}
	set ::core_protocol [dict get $resp result protocol]
	# Additive since protocol 2, so a core that predates it simply omits the key and we
	# keep the POSIX default rather than treating its absence as an error.
	if {[dict exists $resp result fsroot] && [dict get $resp result fsroot] ne ""} {
		set ::core_fsroot [dict get $resp result fsroot]
	}
	# The core's release version (D123), additive on the same terms — a core that predates
	# it omits the key and About simply has nothing extra to say. Re-read on every greeting,
	# so a reconnect to a DIFFERENT core replaces it rather than keeping a stale claim.
	set ::core_version [expr {[dict exists $resp result version] \
		? [dict get $resp result version] : ""}]
	if {$::core_protocol ne $::rio_protocol} {
		report_error "This core speaks wire protocol $::core_protocol, but this GUI expects $::rio_protocol — mixed versions may misbehave. Update the older side." protocol_mismatch
	}
	return 1
}

# Apply a change to group `g`'s widget through the REAL widget command (bypassing the
# proxy). .t replace takes line.col indices directly — the payoff of D12 sharing the Tk
# text-widget index format: the view layer is nearly free. `see insert` only follows
# the caret in the focused group (the caret in a background group isn't the user's).
proc apply_change {g p} {
	set t [gw $g]
	$t replace [dict get $p start] [dict get $p end] [dict get $p text]
	if {$g eq $::focus} { $t see insert }
	gutter_mark $g ;# the line count may have changed — repaint the numbers (an edit that
	               ;# adds/removes lines without moving the view won't trip -yscrollcommand)
	hl_edit $g $p ;# the text changed — re-tokenise from the edit, incrementally (coalesced; D32)
	if {$::wrap_indent} {   ;# re-size the wrap indent for just the lines this edit touched
		set sl [lindex [split [dict get $p start] .] 0]
		set added [expr {[llength [split [dict get $p text] "\n"]] - 1}]
		wrapind_apply $t $sl [expr {$sl + $added}]
	}
	# An open find bar's matches just went stale — recount/repaint, coalesced
	# like the highlight pass so a run of keystrokes costs one update (D36).
	if {$::find_shown && !$::find_pending} {
		set ::find_pending 1
		after idle find_update
	}
}

# Load the active buffer's canonical text into the widget (on switch / open).
# Load group `g`'s active buffer text into its widget (bypassing the proxy) and
# repaint. Runs on open / tab switch within the group.
proc load_buffer {g} {
	set t [gw $g]
	set resp [rio_call buffer.text [dict create buffer [gcur $g]]]
	$t delete 1.0 end
	if {[dict get $resp ok]} {
		$t insert 1.0 [dict get $resp result text]
	} else {
		set e [dict get $resp error]
		report_error [dict get $e message] [dict get $e code]
	}
	hl_select $g   ;# the file type may have changed with the buffer (D32)
	hl_reset $g    ;# repaint the visible window now and start the line-state cache (on switch/open)
	wrapind_group $g   ;# size the wrapped-line indents to this buffer's leading whitespace
	gutter_mark $g ;# the swapped-in buffer has its own line count — repaint the numbers
	               ;# (a same-height swap won't trip -yscrollcommand, so the old ones would linger)
}

# A buffer's whole text via the protocol (buffer.text), so the frontend never reads
# the core's document model directly — the one path that works the same in-process
# and remote (AGENTS.md D29). "" on failure (a vanished buffer): callers only use
# this to test emptiness or seed a compare, where "" is a safe miss.
proc buf_text {id} {
	set resp [rio_call buffer.text [dict create buffer $id]]
	if {[dict get $resp ok]} { return [dict get $resp result text] }
	return ""
}

# ---------------------------------------------------------------------------
# Buffer / tab bookkeeping.
# ---------------------------------------------------------------------------
# Register a newly-opened buffer into group `g` (default: the focused group), at the
# end of its tab order. The core owns the text; ::buffers holds the per-buffer view
# facts, ::grp the group's tab order.
proc register_buffer {id path meta {g ""}} {
	if {$g eq ""} { set g $::focus }
	# gone_ack: "the user said to keep this buffer though the file is gone" (D94). It lives
	# here rather than in the core because a deleted file cannot be re-stamped core-side —
	# there is nothing to stat — and because it is exactly the kind of view-local answer
	# `modified` already is (D22). lang: the language picked by hand (D112) — "" detects
	# by file name, "plain" turns highlighting off, else a registered language name.
	dict set ::buffers $id \
		[dict create path $path meta $meta modified 0 cursor 1.0 yview 0.0 gone_ack 0 lang ""]
	gset $g order [linsert [gorder $g] end $id]
}

# Make `id` active and focus its group: stash the outgoing buffer's cursor/viewport,
# swap that group's widget to `id`, restore its cursor/viewport, and mark the group
# focused (::cur mirrors it). `g` defaults to whichever group already holds `id`
# (clicking a tab), falling back to the focused group.
proc activate {id {g ""}} {
	if {$g eq ""} {
		set g [group_of $id]
		if {$g eq ""} { set g $::focus }
	}
	set t [gw $g]
	set out [gcur $g]
	if {$out ne "" && [dict exists $::buffers $out]} {
		bufset $out cursor [$t index insert]
		bufset $out yview  [lindex [$t yview] 0]
	}
	gset $g cur $id
	load_buffer $g
	catch {$t mark set insert [bufget $id cursor]}
	catch {$t yview moveto    [bufget $id yview]}
	set ::focus $g
	set ::cur $id
	$t see insert
	focus [gget $g path]
	refresh_all
	if {$::find_shown} find_update   ;# the bar tracks the focused buffer (D36)
}

proc close_buffer {id} {
	rio_call buffer.close [dict create buffer $id]
	set g [group_of $id]
	set ::buffers [dict remove $::buffers $id]
	if {$g ne ""} { gset $g order [lsearch -all -inline -not -exact [gorder $g] $id] }
}

# Drop a leftover empty, unsaved, untitled scratch buffer (so opening a file from
# a fresh launch reuses the slot instead of leaving a blank tab behind). Refresh
# the chrome if we dropped anything: close_buffer mutates a group's order but doesn't
# redraw, so a pruned tab would otherwise linger on screen, orphaned. Scans every
# buffer (across groups) — a scratch may sit in either.
proc prune_scratch {keep} {
	set pruned 0
	foreach id [dict keys $::buffers] {
		if {$id eq $keep} continue
		if {[bufget $id path] eq "" && ![bufget $id modified] && [buf_text $id] eq ""} {
			close_buffer $id
			set pruned 1
		}
	}
	if {$pruned} refresh_all
}

# ---------------------------------------------------------------------------
# Actions. The do_* procs take explicit arguments (no dialogs) so they are
# scriptable and testable; the *_dialog wrappers add the file choosers.
# ---------------------------------------------------------------------------
proc do_new {} {
	set res [rio_result buffer.new {}]
	if {$res eq ""} return
	set id [dict get $res buffer]
	register_buffer $id "" {}
	activate $id
}

# Adopt whatever buffers the core already has — its startup default in-process, or
# the server's open buffers in remote mode — via buffer.list, activating the first
# (AGENTS.md D29). Replaces reaching into $::rio::ops::default, which exists only in
# the embedded core. If the core reports none, mint one so there is always a tab.
proc adopt_initial_buffers {} {
	set resp [rio_call buffer.list {}]
	set buffers [expr {[dict get $resp ok] ? [dict get $resp result buffers] : {}}]
	if {![llength $buffers]} { do_new ; return }
	foreach b $buffers {
		register_buffer [dict get $b buffer] [dict get $b path] {}
	}
	activate [dict get [lindex $buffers 0] buffer]
}

# `force` re-asks for a file the core declined as too large or binary (D125) — it is
# how the "Open it anyway?" answer travels, and is never passed by a caller directly.
proc do_open {path {force 0}} {
	# Already open in some group? Just switch to its tab (activate focuses its group).
	foreach id [dict keys $::buffers] {
		if {$path ne "" && [bufget $id path] eq $path} { activate $id ; return 1 }
	}
	set req [dict create path $path]
	if {$force} { dict set req force 1 }
	set resp [rio_call file.open $req]
	if {![dict get $resp ok]} {
		set code [dict get $resp error code]
		set msg  [dict get $resp error message]
		# too_large and binary_file are not failures but QUESTIONS (D125): the core
		# declined to read a file that would make rio crawl, and this is the asking.
		# The core's message states the fact; the frontend owns the question.
		if {!$force && ($code eq "too_large" || $code eq "binary_file")} {
			if {[tk_messageBox -icon warning -type yesno -default no -title rio \
				-message "$msg\n\nOpen it anyway?"] eq "yes"} {
				return [do_open $path 1]
			}
			return 0
		}
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not open $path:\n$msg"
		return 0
	}
	set res [dict get $resp result]
	set id  [dict get $res buffer]
	register_buffer $id $path \
		[dict create encoding [dict get $res encoding] eol [dict get $res eol]]
	# Opened against rio's advice: the highlighter is the other half of what makes a
	# huge buffer crawl, so such a buffer starts as Plain Text — D112's own `lang`
	# value, so *View ▸ Language…* turns it back on if the file proves fine.
	if {$force} { bufset $id lang plain }
	activate $id
	prune_scratch $id
	if {[dict get $res mixed]} {
		tk_messageBox -icon info -type ok -title rio \
			-message "Mixed line endings; the file will be saved as [dict get $res eol]."
	}
	session_save   ;# the open-file set changed — record it for resume (D31)
	return 1
}

# A file (or several, or a folder) dropped onto the window from the OS file manager (D86).
# tkdnd hands DND_Files as a ready-made Tcl list of local paths; we reuse the very same
# dir-vs-file dispatch the argv startup loop uses, then raise the window so the freshly
# opened buffer is in view. Only ever reached with a LOCAL core: drop targets register
# solely when !$::core_remote (a dropped path is local to this machine, which a remote core
# could not resolve), so the handler needs no remote guard of its own. The raise is skipped
# under the test harness — deiconify would un-withdraw the headless window.
proc dnd_open_files {paths} {
	foreach f $paths {
		if {[file isdirectory $f]} { open_folder $f } else { do_open $f }
	}
	if {[llength $paths] && ![info exists ::env(RIO_GUI_HEADLESS)]} {
		wm deiconify . ; raise . ; focus -force .
	}
}

# ---------------------------------------------------------------------------
# The file pane (AGENTS.md: the file-tree pane; D9 a later reflow concern). A
# lazy tree over the core's project root (D87): it lists ONE directory per fs.list
# call, and unfolds a directory in place on demand rather than the core walking a
# whole repo. The core owns "which folder is open" (project.*); this pane is a dumb
# view of it — opening a folder goes through project.open and the pane repaints
# from the project.opened event (D3), the same event-driven path as buffer edits.
# ::nav_root is the open project root (absolute); ::nav_expanded is the set (a dict
# used as a set) of absolute dir paths currently unfolded. The pane is an rl_* rich-list
# whose per-row payload is {type abspath}, so a click knows what it hit.
# ---------------------------------------------------------------------------
proc open_folder {path} {
	set resp [rio_call project.open [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error "Could not open folder $path:\n[dict get $resp error message]" \
			[dict get $resp error code]
		return 0
	}
	return 1   ;# the pane repaints via the project.opened event (on_project_opened)
}

proc on_project_opened {p} {
	set ::nav_root [dict get $p root]
	set ::nav_expanded [dict create]   ;# a fresh project shows the collapsed root (D87)
	# Remember this folder so the next launch reopens it (D88). Local cores only: a remote
	# root is a path on the SERVER, meaningless to reopen against a local core (and it must
	# not clobber the remembered local project). prefs_save self-gates on ::rio_started, so
	# this no-ops during the boot reopen and persists once the user opens a folder live.
	if {!$::core_remote} { set ::last_project $::nav_root ; prefs_save }
	refresh_dock
}

# Repaint whichever dock pane is showing (the other repaints when next shown). rio
# does no file-watching, so the panes' state is refreshed at the moments rio knows
# something might have changed — opening a folder, saving a file, an fs.changed from the
# core (D47), or regaining OS focus (app_focus_event) — rather than live.
proc refresh_dock {} {
	rio::panel::refresh $::dock_pane
}

# Re-sync the dock when rio regains OS input focus. The fs.changed auto-refresh (D47)
# only fires for writes rio's own core makes; this catches changes rio *didn't* make — a
# file created in a terminal, a `git pull`, a build artifact — at the moment the user
# alt-tabs back. One refresh_dock per app-return, not a poll, so it stays cheap.
#
# Tk delivers FocusIn/FocusOut on the toplevel for internal widget-to-widget moves too,
# so we debounce onto an idle callback and then consult `focus -displayof` — empty exactly
# when another application holds focus. A within-app move leaves it non-empty, so only a
# genuine app-level return flips the flag and refreshes.
set ::app_focused 1        ;# assume focused at launch
set ::focus_settle ""      ;# pending idle callback that reads the settled focus state
proc app_focus_event {} {
	if {$::focus_settle ne ""} { after cancel $::focus_settle }
	set ::focus_settle [after idle app_focus_settle]
}
proc app_focus_settle {} {
	set ::focus_settle ""
	note_app_focus [expr {[focus -displayof .] ne ""}]
}
# The testable core: act on a settled focus state. A false→true edge (the app regained
# focus) re-syncs the dock; within-app churn and focus loss only record the flag. Guarded
# on a live core so a refresh never runs while disconnected.
proc note_app_focus {has} {
	if {$has} {
		if {!$::app_focused && [info exists ::core_chan]} {
			refresh_dock
			check_stale_buffers
		}
		set ::app_focused 1
	} else {
		set ::app_focused 0
	}
}

# ---------------------------------------------------------------------------
# Stale buffers: the file changed under an open tab (AGENTS.md D94).
#
# Two triggers, and between them they cover both kinds of change. fs.changed is the write
# rio's own core made — an agent's fs.write, a discard, a rename; regaining OS focus is
# everything rio did NOT do — a `git pull`, a build, an editor in another window. Same as
# the file pane's two triggers (D47), and for the same reason: rio does not watch the
# filesystem, so these are the two moments it can honestly re-ask.
#
# The DETECTION is core-side (buffers.stale): over a remote core the file is on the
# server, so a GUI-side [file mtime] would answer about the wrong machine (D29). The GUI
# decides only what to DO about it, because that turns on `modified` — view-local state
# the core does not have (D22).
#
# Three outcomes, one rule behind the wording: the default button is whichever choice
# loses nothing.
#   clean, still there  -> reload silently. There is nothing to lose and nothing to ask.
#   modified, changed   -> ASK. Reloading would throw away unsaved edits, so No is the
#                          default, and No re-stamps ("I have seen this") so the same
#                          conflict is not raised again on every focus return.
#   gone from disk      -> ASK, Notepad++'s question: keep it in the editor? Yes is the
#                          default (it is the only copy left) and marks the buffer
#                          modified, so a later Save recreates the file.
proc check_stale_buffers {} {
	# A modal runs the event loop, so a second trigger can arrive while one is up.
	if {$::stale_checking} return
	# And never ask in the middle of another op's round trip. Both triggers can land
	# there — a settled fs.changed burst, or an idle focus callback firing inside a
	# vwait — and the op still in flight may be the very thing that settles these
	# buffers: fs_apply_delete closes the tabs of the file it just deleted, right after
	# the op returns. Asking first would report rio's own deliberate change as a surprise
	# ("deleted on disk, keep it?" about a file the user just chose to delete). One
	# pending retry at a time, so repeated triggers don't stack up callbacks.
	if {[array size ::pending]} {
		if {$::stale_retry eq ""} {
			set ::stale_retry [after $::fs_changed_delay \
				{set ::stale_retry "" ; check_stale_buffers}]
		}
		return
	}
	set ::stale_checking 1
	if {[catch {_check_stale_buffers} err opts]} {
		set ::stale_checking 0
		return -options $opts $err
	}
	set ::stale_checking 0
}
proc _check_stale_buffers {} {
	set resp [rio_call buffers.stale {}]
	if {![dict get $resp ok]} return
	set reload {} ; set conflict {} ; set gone {}
	foreach s [dict get $resp result stale] {
		set id [dict get $s buffer]
		if {![dict exists $::buffers $id]} continue   ;# not a buffer this GUI shows
		if {[dict get $s gone]} {
			if {![bufget $id gone_ack]} { lappend gone $id }
		} elseif {[bufget $id modified]} {
			lappend conflict $id
		} else {
			lappend reload $id
		}
	}
	if {[llength $reload]}   { stale_reload $reload }
	if {[llength $conflict]} { stale_conflict $conflict }
	foreach id $gone { stale_deleted $id }
}

# Take the new text for these buffers — one op for the whole set, because a discard-all
# or a `git pull` stales many tabs at once and a round trip per tab over a socket is the
# cost D93 went to git to avoid. The TEXT needs no work here: the core emits one
# buffer.changed per buffer and dispatch_event already applies that to whichever group
# shows it — and the events land before this reply, so by the time we set the flags the
# text is already on screen.
proc stale_reload {ids} {
	set resp [rio_call buffers.reload [dict create buffers $ids]]
	if {![dict get $resp ok]} return
	foreach r [dict get $resp result reloaded] {
		set id [dict get $r buffer]
		if {![dict exists $::buffers $id]} continue
		bufset $id modified 0
		bufset $id gone_ack 0
		bufset $id meta [dict merge [bufget $id meta] \
			[dict create encoding [dict get $r encoding] eol [dict get $r eol]]]
	}
	refresh_all
}

# The unsaved-edits conflict. ONE dialog for the whole set: discard-all can stale every
# open tab, and twelve modals in a row is not an answer to anything.
proc stale_conflict {ids} {
	set names {}
	foreach id $ids { lappend names "    [tab_name $id]" }
	if {[llength $ids] == 1} {
		set q "“[tab_name [lindex $ids 0]]” has changed on disk, and you have unsaved edits here.\n\nReload it from disk? Your unsaved edits will be lost."
	} else {
		set q "[llength $ids] open files have changed on disk, and you have unsaved edits in them:\n\n[join $names \n]\n\nReload them from disk? Your unsaved edits will be lost."
	}
	if {[stale_ask $q] eq "yes"} {
		stale_reload $ids
	} else {
		# "I have seen this version" — so the same change is not raised again every time
		# rio regains focus. A LATER change stales it again, which is right: that is a
		# version they have not seen.
		rio_call buffers.stamp [dict create buffers $ids]
	}
}

# The file is gone. jka's call, and Notepad++'s shape: ask rather than decide. Keeping it
# marks the buffer modified — the text now exists only here, so Save must offer to write
# it back, which is exactly how the file gets recreated.
proc stale_deleted {id} {
	set q "“[tab_name $id]” has been deleted on disk.\n\nKeep it open in the editor? Saving it later will recreate the file."
	if {[stale_ask_deleted $q] eq "yes"} {
		bufset $id gone_ack 1
		mark_buffer_modified $id 1
	} else {
		bufset $id modified 0     ;# the D48 force-close idiom: no "save before closing?"
		close_tab $id
	}
}

# The two prompts, each in its own one-line proc so a headless test can stub them — the
# idiom split.tcl already uses for maybe_discard. They differ only in their default
# button, and that difference is the whole rule: default to the choice that loses nothing.
proc stale_ask {q} {
	return [tk_messageBox -icon warning -type yesno -default no \
		-title "rio — changed on disk" -message $q]
}
proc stale_ask_deleted {q} {
	return [tk_messageBox -icon warning -type yesno -default yes \
		-title "rio — deleted on disk" -message $q]
}

# mark_modified works on the CURRENT buffer; a stale check speaks about any of them.
proc mark_buffer_modified {id m} {
	if {![dict exists $::buffers $id]} return
	if {$id eq $::cur} { mark_modified $m ; return }
	bufset $id modified $m
	refresh_tabs
}

# ---------------------------------------------------------------------------
# rl_* — a reusable rich-list: a read-only text widget drawn one row per line,
# with full-width hover and selection bands and mouse/keyboard navigation. Both
# the files pane and the git pane (D42/D43) are instances of it — the well chrome,
# the bands, and the nav feel are identical; only the row text and what a row
# *means* differ. State is kept per body widget (arrays keyed by the widget path)
# so the two lists don't share it. Each row carries a `selectable` flag (placeholder
# rows like "(clean)" are not) and an opaque `payload` the owning pane interprets.
#
# The caller renders row text itself (its own glyphs/tags) — the component only
# needs one inserted line per rl_row, in order, so line N maps to row N-1. Two
# callbacks wire behaviour: onselect fires when the selection changes (click or
# arrow), onactivate on double-click / Return; either may be empty. The bands use
# the shared `selrow`/`hoverrow` tags, configured per body in apply_theme.
# ---------------------------------------------------------------------------
proc rl_init {b onselect onactivate oncontext} {
	set ::rl_onselect($b)   $onselect
	set ::rl_onactivate($b) $onactivate
	set ::rl_oncontext($b)  $oncontext
	rl_reset $b
	bind $b <Button-1>        "focus %W ; rl_click %W %x %y ; break"
	bind $b <Double-Button-1> "rl_click %W %x %y ; rl_activate %W ; break"
	bind $b <Return>          "rl_activate %W ; break"
	bind $b <Up>              "rl_move %W -1 ; break"
	bind $b <Down>            "rl_move %W 1 ; break"
	bind $b <Motion>          "rl_hover_at %W %x %y"
	bind $b <Leave>           "rl_set_hover %W -1"
	bind $b <Button-3>        "rl_context %W %x %y %X %Y ; break"
	# A read-only list selects one row at a time (Button-1 / Return / arrows). It has
	# no use for the Text widget's own text selection, and -state disabled does not
	# suppress it: a drag, a shift-click or a line/word multi-click still sweeps a
	# stray multi-line highlight over the row model (reported in the files pane).
	# Neutralise every gesture that would begin or extend a text selection — mouse and
	# keyboard — while leaving scrolling and our own navigation untouched.
	foreach seq {<B1-Motion> <Double-B1-Motion> <Triple-B1-Motion> <Shift-B1-Motion>
	             <Shift-Button-1> <Triple-Button-1> <Shift-Up> <Shift-Down>} {
		bind $b $seq break
	}
}
proc rl_reset {b} {
	set ::rl_rows($b)  {}
	set ::rl_sel($b)   -1
	set ::rl_hover($b) -1
}
# Begin a repaint: enable, clear text and state. Caller then inserts rows and ends.
proc rl_begin {b} {
	$b configure -state normal
	$b delete 1.0 end
	rl_reset $b
}
# Record one row. The caller has already inserted exactly one line of text for it.
proc rl_row {b selectable payload} {
	lappend ::rl_rows($b) [list $selectable $payload]
}
proc rl_end {b} { $b configure -state disabled }

proc rl_selectable {b i} {
	if {$i < 0 || $i >= [llength $::rl_rows($b)]} { return 0 }
	return [lindex [lindex $::rl_rows($b) $i] 0]
}
proc rl_payload {b i} { return [lindex [lindex $::rl_rows($b) $i] 1] }

# Paint the hover and selection bands. Tagging through the trailing newline (+1c)
# makes a band span the full pane width, not just the text. selrow sits above
# hoverrow (see apply_theme) so the selection stays visible under the pointer.
proc rl_paint {b} {
	$b tag remove hoverrow 1.0 end
	$b tag remove selrow   1.0 end
	if {$::rl_hover($b) >= 0} {
		set L [expr {$::rl_hover($b) + 1}]
		$b tag add hoverrow $L.0 "$L.0 lineend +1c"
	}
	if {$::rl_sel($b) >= 0} {
		set L [expr {$::rl_sel($b) + 1}]
		$b tag add selrow $L.0 "$L.0 lineend +1c"
	}
}

# Select a row by index (ignoring placeholder rows), repaint, scroll it into view,
# and fire onselect. `fire` lets a headless test set a selection without the callback.
proc rl_select {b row {fire 1}} {
	if {![rl_selectable $b $row]} return
	set ::rl_sel($b) $row
	rl_paint $b
	$b see [expr {$row + 1}].0
	if {$fire && $::rl_onselect($b) ne ""} {
		{*}$::rl_onselect($b) [rl_payload $b $row]
	}
}
# Drop the selection: no row is current. A pane needs this when it shows something that
# has no row of its own — the help viewer following a link out of the contents list.
proc rl_clear {b} { set ::rl_sel($b) -1 ; rl_paint $b }

# Double-click / Return: run onactivate on the selected row.
proc rl_activate {b} {
	set row $::rl_sel($b)
	if {![rl_selectable $b $row]} return
	if {$::rl_onactivate($b) ne ""} {
		{*}$::rl_onactivate($b) [rl_payload $b $row]
	}
}
# Right-click: select the row under the pointer (band only — fire=0, so a git-pane
# right-click doesn't also load its diff) and hand its payload + root coords to the
# owning pane's oncontext, which pops a menu. A right-click off any row does nothing.
proc rl_context {b x y X Y} {
	set row [rl_row_at $b $x $y]
	if {![rl_selectable $b $row]} return
	rl_select $b $row 0
	if {$::rl_oncontext($b) ne ""} {
		{*}$::rl_oncontext($b) [rl_payload $b $row] $X $Y
	}
}

# Row index under a pixel: the text line at @x,y, minus one (line N -> row N-1).
proc rl_row_at {b x y} {
	return [expr {[lindex [split [$b index @$x,$y] .] 0] - 1}]
}
proc rl_click {b x y} {
	if {![llength $::rl_rows($b)]} return
	rl_select $b [rl_row_at $b $x $y]
}
# Keyboard move: step the selection by ±1, skipping placeholder rows, clamped.
proc rl_move {b dir} {
	set n [llength $::rl_rows($b)]
	if {$n == 0} return
	set cur $::rl_sel($b)
	if {$cur < 0} { set cur [expr {$dir > 0 ? -1 : $n}] }
	for {set i [expr {$cur + $dir}]} {$i >= 0 && $i < $n} {incr i $dir} {
		if {[rl_selectable $b $i]} { rl_select $b $i ; return }
	}
}
# Hover follows the pointer; -1 clears it. No-op when unchanged so we don't repaint
# on every motion pixel.
proc rl_hover_at {b x y} {
	if {![llength $::rl_rows($b)]} return
	rl_set_hover $b [rl_row_at $b $x $y]
}
proc rl_set_hover {b row} {
	if {$row >= [llength $::rl_rows($b)]} { set row -1 }
	if {$row >= 0 && ![rl_selectable $b $row]} { set row -1 }
	if {$row == $::rl_hover($b)} return
	set ::rl_hover($b) $row
	rl_paint $b
}

# ---------------------------------------------------------------------------
# The menu Tk leaves bare (AGENTS.md D115) — the half D108 named and deferred.
#
# D108 gave the editor text its context menu and stopped there, deliberately: the
# READ-ONLY views (agent log, compare panes, git diff, the manual, a plan) and every
# entry/text widget OUTSIDE the editor were left for "its own later change". In all
# of them Ctrl+C already works, through Tk's own class bindings — only the door was
# missing, on surfaces where every neighbour in rio has one.
#
# THE COMMANDS ARE TK'S OWN VIRTUAL EVENTS. Unlike the editor, whose edits must
# travel to the core through the group proxy (D3), these are ordinary local Tk
# widgets whose Ctrl+X/C/V *is* the Entry/Text class binding. So the menu generates
# that same event: <<Cut>> <<Copy>> <<Paste>> <<SelectAll>>. The menu and the
# keystroke are then one implementation by construction — D38's anti-drift rule,
# reached from the other side — and there is no second clipboard code path to keep
# in step. (`-state disabled` blocks neither selection nor `tag add sel`; see the
# rl_init note above. A disabled text takes <<Copy>> and <<SelectAll>> and ignores
# <<Paste>>, which is exactly the behaviour these menus want.)
#
# Two families, because the widgets differ in what they can honestly offer:
#   view   read-only  — Copy, Select All
#   input  editable   — Cut, Copy, Paste, Select All
# Both are applied at the widget's CREATION SITE via ctx_bind_view / ctx_bind_input,
# the way every other binding in this file is, and both follow the D44 popup idiom:
# a builder split from the popup so a headless test can read the entries without a
# global grab nobody is there to dismiss.
#
# NOT here: the rl_* row lists (Files, Git, Search results, the manual's contents).
# The first two have real row menus already; the other two have Button-3 bound to an
# empty callback, and filling it means deciding what Copy or Open MEAN for a result
# row — a Search and Help feature, not the missing door this change is about. And
# rl_init kills text selection in those panes outright, so a Copy there could not be
# the copy this menu offers anyway.
# ---------------------------------------------------------------------------

# Entry and Text answer "is anything selected?" and "is there anything at all?"
# differently, and both families need both answers. One switch, in one place.
proc ctx_has_sel {w} {
	if {[winfo class $w] eq "Text"} { return [expr {[llength [$w tag ranges sel]] > 0}] }
	return [expr {![catch {$w selection present} p] && $p}]
}
proc ctx_has_text {w} {
	if {[winfo class $w] eq "Text"} { return [$w compare "end -1c" > 1.0] }
	return [expr {[string length [$w get]] > 0}]
}

# A read-only view's menu: what you can do to text you cannot edit. No Cut and no
# Paste — the widget would refuse them, and an entry that cannot work should not be
# drawn (D108 greys only what it can compute honestly; here the honest answer is to
# leave them out entirely).
proc view_menu_build {m w} {
	set sel  [expr {[ctx_has_sel $w]  ? "normal" : "disabled"}]
	set some [expr {[ctx_has_text $w] ? "normal" : "disabled"}]
	$m add command -label "Copy"       -state $sel  -command [list event generate $w <<Copy>>]
	$m add command -label "Select All" -state $some -command [list event generate $w <<SelectAll>>]
}

# An editable widget's menu. Cut and Copy follow the selection and Select All follows
# the content; PASTE STAYS ENABLED for D108's reason — probing the clipboard is a
# blocking X round-trip to whichever application owns the selection, and an
# unresponsive owner would stall the menu on its way up. An empty clipboard already
# does nothing, silently.
#
# A MASKED field (the provider API key, -show •) offers Paste and Select All only.
# Pasting a key is the thing people actually do; lifting plaintext out of a field
# drawn as bullets is a surprise, and D26 treats a key as a secret.
proc input_menu_build {m w} {
	set sel    [expr {[ctx_has_sel $w]  ? "normal" : "disabled"}]
	set some   [expr {[ctx_has_text $w] ? "normal" : "disabled"}]
	set masked [expr {![catch {$w cget -show} s] && $s ne ""}]
	if {!$masked} {
		$m add command -label "Cut"  -state $sel -command [list event generate $w <<Cut>>]
		$m add command -label "Copy" -state $sel -command [list event generate $w <<Copy>>]
	}
	$m add command -label "Paste" -state normal -command [list event generate $w <<Paste>>]
	$m add separator
	$m add command -label "Select All" -state $some -command [list event generate $w <<SelectAll>>]
}

# What a right-click settles before either menu appears. D108's convention, minus the
# half a read-only view cannot keep: a click INSIDE the selection leaves it alone, so
# Copy acts on what you can see is highlighted; a click outside clears it. The caret
# does NOT move in a read-only view — a disabled text draws no insertion cursor, so
# moving it would be a promise nothing on screen keeps. In an editable widget it does
# move, exactly as in the editor, so Paste lands where you pointed.
proc ctx_click {w x y editable} {
	if {$editable} { focus $w }
	set text [expr {[winfo class $w] eq "Text"}]
	set idx [expr {$text ? [$w index @$x,$y] : [$w index @$x]}]
	set inside 0
	if {$text} {
		foreach {from to} [$w tag ranges sel] {
			if {[$w compare $idx >= $from] && [$w compare $idx < $to]} { set inside 1 ; break }
		}
	} elseif {[ctx_has_sel $w]} {
		set inside [expr {$idx >= [$w index sel.first] && $idx < [$w index sel.last]}]
	}
	if {$inside} return
	if {$text} { $w tag remove sel 1.0 end } else { $w selection clear }
	if {$editable} {
		if {$text} { $w mark set insert $idx } else { $w icursor $idx }
	}
}

# Post a fresh menu at the pointer (the D44 idiom: rebuilt every time, so the greys
# are current by construction).
proc ctx_menu_post {w x y X Y kind} {
	ctx_click $w $x $y [expr {$kind eq "input"}]
	catch {destroy .ctxmenu}
	menu .ctxmenu -tearoff 0
	${kind}_menu_build .ctxmenu $w
	tk_popup .ctxmenu $X $Y
}

# The keyboard route (Menu, Shift+F10). Nothing about the selection changes. An
# editable widget posts at its caret, like the editor does; a read-only view has no
# visible caret, so it posts at the start of the selection — the thing the menu is
# about — and falls back to its own top-left corner when there is none.
proc ctx_menu_key {w kind} {
	set X [winfo rootx $w] ; set Y [winfo rooty $w]
	set at [expr {$kind eq "input" ? "insert" : ""}]
	if {$at eq "" && [ctx_has_sel $w]} {
		set at [expr {[winfo class $w] eq "Text" ? "sel.first" : "insert"}]
	}
	if {$at ne "" && ![catch {$w bbox $at} bb] && [llength $bb] >= 4} {
		lassign $bb bx by bw bh
		set X [expr {$X + $bx}] ; set Y [expr {$Y + $by + $bh}]
	}
	catch {destroy .ctxmenu}
	menu .ctxmenu -tearoff 0
	${kind}_menu_build .ctxmenu $w
	tk_popup .ctxmenu $X $Y
}

# Give a widget its menu. Called at the creation site. `break` so the widget binding
# wins over anything the class or an editing mode puts on Button-3, the same
# precedence the editor's own binding takes (D38).
proc ctx_bind_view  {w} { ctx_bind $w view }
proc ctx_bind_input {w} { ctx_bind $w input }
proc ctx_bind {w kind} {
	bind $w <Button-3>   [list ctx_menu_post %W %x %y %X %Y $kind]\;break
	bind $w <Shift-F10>  [list ctx_menu_key %W $kind]\;break
	bind $w <Key-Menu>   [list ctx_menu_key %W $kind]\;break
}

# A placeholder label sits PLACED ON TOP of its entry (the git commit bar's two), so
# a right-click on an empty field hits the label and never reaches the widget below.
# Forward it, the same way the label already forwards Button-1.
proc ctx_bind_placeholder {lbl target kind} {
	bind $lbl <Button-3> [list ctx_menu_post $target %x %y %X %Y $kind]\;break
}

# Repaint the files pane as a tree from the project root (D87): dirs then files at each
# level (each group dictionary-sorted by the core already), an unfolded dir's children
# rendered indented right below it. Each row is one line: a 2-char git-status gutter
# (blank when clean, D43), one indent step (two spaces) per depth, a mono glyph icon
# (▸ folded dir · ▾ unfolded dir · ▪ file, all U+25xx so they render monochrome, never
# emoji), then the name. The body is an rl_* rich-list.
proc populate_nav {} {
	set b .pfiles.well.body
	rl_begin $b
	set ::nav_row_depth [dict create]   ;# path -> tree depth, for the arrow-click hit test (D87)
	# Probe the root once. Its own folder can vanish under us (deleted on disk mid-run); the
	# core's fs.list is the stat that also works in remote mode (the GUI can't see a server
	# path). A gone root is not an error worth a dialog — it CLOSES the project: forget it as
	# the reopen target if it was the remembered one (D88), and fall through to the placeholder.
	set entries {}
	if {$::nav_root ne ""} {
		set probe [rio_call fs.list [dict create path $::nav_root]]
		if {[dict get $probe ok]} {
			set entries [dict get $probe result entries]
		} else {
			if {$::nav_root eq $::last_project} { set ::last_project "" }
			set ::nav_root ""
			set ::nav_expanded [dict create]
		}
	}
	if {$::nav_root eq ""} {
		.pfiles.hdr.head configure -text "(no folder)"
		$b insert end "    Open a folder…\n"
		rl_row $b 0 [list none ""]
		set ::nav_git {}
		rl_end $b
		return
	}
	.pfiles.hdr.head configure -text [file tail $::nav_root]
	set git [nav_git_map $::nav_root]
	set ::nav_git $git   ;# stashed so the row context menu can read status (D44)
	nav_render_entries $::nav_root 0 $git $entries
	rl_end $b
}

# Render one directory level and recurse into whichever of its subdirs are unfolded
# (::nav_expanded). A folded dir shows ▸, an unfolded one ▾ with its children indented one
# step deeper. An fs.list error is reported once but leaves the siblings already drawn.
# (A vanished subdir raises no error here: its parent's listing simply omits it, so this is
# never called for it — only a live race or a permission fault reaches the report.)
proc nav_render_level {dir depth git} {
	set resp [rio_call fs.list [dict create path $dir]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	nav_render_entries $dir $depth $git [dict get $resp result entries]
}

# Draw one already-listed level's rows (dirs then files, core-sorted), recursing into each
# unfolded subdir. Split from nav_render_level so the root's listing — fetched once in
# populate_nav to probe for a vanished project — is not fetched a second time.
proc nav_render_entries {dir depth git entries} {
	foreach grp {dir file} {
		foreach e $entries {
			if {[dict get $e type] ne $grp} continue
			set name [dict get $e name]
			if {!$::show_hidden && [string index $name 0] eq "."} continue  ;# hide dotfiles (View ▸ Show Hidden Files)
			set path [file join $dir $name]
			if {$grp eq "dir"} {
				set open [dict exists $::nav_expanded $path]
				nav_render_row dir $path "$name/" [expr {$open ? "▾" : "▸"}] \
					$depth [nav_dir_status $git $path]
				if {$open} { nav_render_level $path [expr {$depth + 1}] $git }
			} else {
				nav_render_row file $path $name "▪" $depth [nav_file_status $git $path]
			}
		}
	}
}

# Is directory $d currently on screen in the pane? True for the root and any unfolded dir
# — those are the levels whose children are drawn, so a change under one is worth a repaint
# (the fs.changed / focus-return refresh guards, D47). A folded dir's contents aren't shown.
proc nav_dir_visible {d} {
	return [expr {$d eq $::nav_root || [dict exists $::nav_expanded $d]}]
}

# Toggle: show or hide dotfile / hidden entries in the Files pane, then repaint and persist.
# Off by default, so a fresh pane hides `.git/` and other dotfiles the way `ls` does; on
# reveals them. populate_nav does the filtering (a name-starts-with-"." skip), so this just
# re-lists the shown directory. Three doors drive the same ::show_hidden global through this
# one applier — the View menu, the Preferences window, and the pane-header glyph button — so
# all three (and the header glyph) stay in sync for free.
proc apply_show_hidden {} {
	nav_hidden_glyph
	populate_nav
	prefs_save
}
# The pane-header glyph reflects the current state (a filled ◉ dot when hidden files show,
# a faint dotted ◌ when they are hidden) — a bare glyph, no tooltip, like the ⟳ refresh
# beside it. Kept in sync by apply_show_hidden, so every door updates it. No-op before the
# header exists (called from the boot applier once the pane is built).
proc nav_hidden_glyph {} {
	if {![winfo exists .pfiles.hdr.hidden]} return
	.pfiles.hdr.hidden configure -text [expr {$::show_hidden ? "◉" : "◌"}]
	tooltip .pfiles.hdr.hidden [expr {$::show_hidden ? "Hide hidden files" : "Show hidden files"}]
}
# The header button's action: flip the global and run the shared applier.
proc nav_toggle_hidden {} {
	set ::show_hidden [expr {!$::show_hidden}]
	apply_show_hidden
}

# The git status for the open project, as an abspath -> XY-status dict (the two
# porcelain chars). Empty when there is no repo — a plain file pane, no gutter. The
# porcelain paths are repo-root-relative and rio opens the repo root as the project,
# so we anchor them at $root. (D43)
proc nav_git_map {root} {
	set map [dict create]
	set r [rio_call git.status {}]
	if {![dict get $r ok]} { return $map }
	foreach c [dict get $r result changes] {
		dict set map [file join $root [dict get $c path]] \
			"[dict get $c x][dict get $c y]"
	}
	return $map
}
# A file's one-letter flag: the worktree char if any, else the staged one (so a bare
# stage still shows). "" when the path is clean / untracked-parent.
proc nav_file_status {git path} {
	if {![dict exists $git $path]} { return "" }
	set xy [dict get $git $path]
	set y [string index $xy 1]
	return [expr {$y ne " " ? $y : [string index $xy 0]}]
}
# A directory's rollup flag: "·" when it contains (or is) a change, else "". Lets the
# flat one-dir navigator hint where changes hide without walking into them. An
# untracked directory is reported by porcelain as the directory itself, so we match
# both the dir's own path and anything beneath it.
proc nav_dir_status {git path} {
	if {[dict exists $git $path]} { return "·" }
	foreach p [dict keys $git] {
		if {[string match "$path/*" $p]} { return "·" }
	}
	return ""
}
# Does PATH sit inside a directory git reports as untracked? Porcelain names such a
# directory once and nothing below it, so its files never appear in the status map and
# the row menu has to ask this instead of a lookup. Walks up to the project root: the
# untracked directory can be any ancestor, not just the immediate parent.
proc nav_untracked_parent {git path} {
	for {set d [file dirname $path]} {$d ne [file dirname $d]} {set d [file dirname $d]} {
		if {[dict exists $git $d] && [string index [dict get $git $d] 0] eq "?"} { return 1 }
		if {$d eq $::nav_root} break
	}
	return 0
}

# Append one navigator row: a 2-char status gutter (the flag glyph + a space, or two
# spaces when clean) — kept in a fixed left column so flags stay aligned across depths —
# then one indent step (two spaces) per tree depth, then the type glyph (tagged navicon)
# and the label. Records {type abspath} as the row payload. Caller has the body -state normal.
proc nav_render_row {type path label glyph depth status} {
	set b .pfiles.well.body
	if {$status eq ""} {
		$b insert end "  "
	} else {
		$b insert end $status [nav_status_tag $status] " "
	}
	$b insert end [string repeat "  " $depth]
	$b insert end $glyph navicon " $label\n"
	rl_row $b 1 [list $type $path]
	dict set ::nav_row_depth $path $depth   ;# so a click knows where this row's name starts
}
# Colour tag for a files-pane status flag (see apply_theme for the colours).
proc nav_status_tag {s} {
	switch -- $s {
		A - ? { return navadd }
		D     { return navdel }
		·     { return navdirty }
		default { return navmod }
	}
}

# Double-click / Enter on a row (onactivate): unfold/fold a directory in place, or open
# a file in a tab. The payload is the row's {type abspath}. (D87 — the tree replaced the
# old descend-into-a-dir navigation; single-click and arrows just move the selection.)
proc nav_open {payload} {
	lassign $payload type path
	switch -- $type {
		dir  { nav_toggle_expand $path }
		file { do_open $path }
	}
}
# Flip a directory between folded and unfolded, then repaint. Folding keeps any descendant
# expand-state in ::nav_expanded, so re-opening the dir restores the sub-shape it had.
proc nav_toggle_expand {path} {
	if {[dict exists $::nav_expanded $path]} {
		dict unset ::nav_expanded $path
	} else {
		dict set ::nav_expanded $path 1
	}
	populate_nav
	session_save   ;# the unfolded set changed — record it so the next launch resumes it (D89)
}

# Click routing for the files pane (D87). A folder unfolds on a SINGLE click of its arrow —
# the twisty and the indent/gutter left of the name — while its NAME is reserved for
# double-click (dirs toggle, files open). This splits the plain rl_* click, so it is wired
# only on the files body (the git pane keeps the default select-on-click).
#
# nav_col_is_arrow is the pure decision (kept separate so it is testable without pixels):
# a dir row's name begins at char column 2 (git gutter) + 2·depth (indent) + 2 (glyph +
# space); a click left of that is on the arrow. A file row has no arrow.
proc nav_col_is_arrow {type depth col} {
	return [expr {$type eq "dir" && $col < 2 * $depth + 4}]
}
proc nav_hit_arrow {w row x y} {
	if {![rl_selectable $w $row]} { return 0 }
	lassign [rl_payload $w $row] type path
	set depth [expr {[dict exists $::nav_row_depth $path] ? [dict get $::nav_row_depth $path] : 0}]
	set col [lindex [split [$w index @$x,$y] .] 1]
	return [nav_col_is_arrow $type $depth $col]
}
# Single click: select the row; if it landed on a folder's arrow, unfold/fold it too.
proc nav_b1 {w x y} {
	focus $w
	if {![llength $::rl_rows($w)]} return
	set row [rl_row_at $w $x $y]
	rl_select $w $row
	if {[nav_hit_arrow $w $row $x $y]} { nav_open [rl_payload $w $row] }
}
# Double click: activate (dir toggles, file opens) UNLESS it fell on the arrow — there the
# first click's single-click handler already toggled, so the second must not toggle back.
proc nav_b1_double {w x y} {
	if {![llength $::rl_rows($w)]} return
	set row [rl_row_at $w $x $y]
	rl_select $w $row 0
	if {![nav_hit_arrow $w $row $x $y]} { rl_activate $w }
}

# Right-click a file/dir row (oncontext): a menu of actions ABOUT THIS ROW (the
# UI-design bar — scoped to what was clicked, like the tab menu). Rebuilt each popup
# so the git items reflect the row's current status (read from the ::nav_git stash).
# Open + Copy Path always; git stage/unstage/track appear only when they apply (D44).
# nav_menu_build fills a menu (separated so a headless test can inspect entries
# without posting); nav_context_menu wraps it in the popup.
proc nav_context_menu {payload X Y} {
	catch {destroy .navmenu}
	menu .navmenu -tearoff 0
	nav_menu_build .navmenu $payload
	tk_popup .navmenu $X $Y
}
proc nav_menu_build {m payload} {
	lassign $payload type path
	$m add command -label "Open" -command [list nav_open $payload]
	if {$type eq "file"} {
		$m add command -label "Copy Path" -command [list rio_copy_clip $path]
	}
	nav_menu_fs $m $type $path
	nav_menu_git $m $type $path
}
# Append the file-management verbs (D48). New File/New Folder create in the row's own
# directory (D87): a folder row → inside that folder (and it auto-unfolds so the new entry
# shows); a file row → alongside it; they appear whenever a folder is open. Rename/Delete
# act on the clicked row — any real file/dir row now (the tree has no ".." placeholder to
# exclude), never the no-folder placeholder. Names come from a modal prompt; Delete confirms
# first (nav_delete).
proc nav_menu_fs {m type path} {
	if {$::nav_root eq ""} return
	set target [expr {$type eq "dir" ? $path : \
		($type eq "file" ? [file dirname $path] : $::nav_root)}]
	$m add separator
	$m add command -label "New File…"   -command [list nav_new $target file]
	$m add command -label "New Folder…" -command [list nav_new $target dir]
	if {$type ne "none"} {
		$m add command -label "Rename…" -command [list nav_rename $path]
		$m add command -label "Delete…" -command [list nav_delete $path]
	}
}
# Append the git items for a row, given its type and abspath. A file uses its XY from
# the stash (untracked -> Track; worktree-dirty -> Stage; staged -> Unstage); a dir
# that contains changes offers "Stage folder" (git add on the directory).
proc nav_menu_git {m type path} {
	if {![info exists ::nav_git]} return
	if {$type eq "dir"} {
		if {[nav_dir_status $::nav_git $path] ne ""} {
			$m add separator
			$m add command -label "Stage folder" -command [list do_git add $path]
		}
		return
	}
	if {![dict exists $::nav_git $path]} {
		# Not a change of its own — but git collapses a WHOLLY untracked directory into a
		# single `dir/` entry and reports nothing beneath it, so every file inside one is
		# invisible to status: the git pane has no row for it, and this menu would have no
		# item. The tree is the only place those files are named, and `git add` takes one
		# happily (git then de-collapses the folder and lists the rest individually), so
		# the file's own door belongs here.
		if {[nav_untracked_parent $::nav_git $path]} {
			$m add separator
			$m add command -label "Track (git add)" -command [list do_git add $path]
		}
		return                                    ;# otherwise clean / no repo — no git items
	}
	set xy [dict get $::nav_git $path]
	set x [string index $xy 0] ; set y [string index $xy 1]
	$m add separator
	if {$x eq "?"} {
		$m add command -label "Track (git add)" -command [list do_git add $path]
		return
	}
	if {$y ne " "} { $m add command -label "Stage"   -command [list do_git add $path] }
	if {$x ne " "} { $m add command -label "Unstage" -command [list do_git unstage $path] }
	# Discard, the same confirm-gated entry the git pane carries — this door too (D93), so
	# "undo my edits to this file" is reachable from wherever you are looking at the file.
	# TRACKED changes only: a new file (untracked "?", returned above, or a staged addition
	# "A") is removed rather than reverted, and this menu's own fs "Delete…" already removes
	# it — two "Delete…" entries in one menu would be the worse UI.
	if {$x ne "A"} {
		$m add separator
		$m add command -label "Discard Changes…" \
			-command [list git_discard_confirm [nav_repo_rel $path] 0]
	}
}
# A tree row's abspath as git names it: repo-root-relative. The project root IS the repo
# root (D43), so this is the path porcelain would have printed — which keeps the discard
# confirm reading the same from both doors, instead of quoting a long absolute path.
proc nav_repo_rel {path} {
	set parts [lrange [file split $path] [llength [file split $::nav_root]] end]
	return [expr {[llength $parts] ? [file join {*}$parts] : [file tail $path]}]
}

# ---------------------------------------------------------------------------
# File-management actions (D48). The menu-facing procs (nav_new/nav_rename/
# nav_delete) collect the name via a modal prompt / confirm; the fs_apply_* procs
# do the core call, retarget any open buffers, and repaint — split out so the
# headless smoke can drive the effect without a real dialog (as note_app_focus was
# for D47). Each fs.* op resolves its path against the project root and emits
# fs.changed, but we refresh_dock directly too: the acting GUI shouldn't wait on the
# round-trip event to see its own change.
# ---------------------------------------------------------------------------
proc nav_new {dir type} {
	set what [expr {$type eq "dir" ? "folder" : "file"}]
	set name [name_prompt "New [string totitle $what]" "Name of new $what:" ""]
	if {$name eq ""} return
	fs_apply_create $dir $type $name
}
proc nav_rename {path} {
	set name [name_prompt "Rename" "Rename to:" [file tail $path]]
	if {$name eq "" || $name eq [file tail $path]} return
	fs_apply_rename $path $name
}
proc nav_delete {path} {
	set isdir [file isdirectory $path]
	set what [expr {$isdir ? "folder and everything in it" : "file"}]
	if {[tk_messageBox -icon warning -type yesno -default no -title "rio — delete" \
			-message "Delete this $what?\n\n[file tail $path]\n\nThis cannot be undone."] ne "yes"} {
		return
	}
	fs_apply_delete $path
}

# A single-line component name is required: non-empty, no path separator, not . or ..
# — so a prompt can only ever create/rename WITHIN the target directory (nested paths
# are a deliberate non-goal). Rejected names flash the header and change nothing.
proc nav_name_ok {name} {
	return [expr {$name ne "" && [llength [file split $name]] == 1 && $name ni {. ..}}]
}

# Create $name (a file or dir) inside $dir, then unfold $dir so the new entry is on screen
# before the repaint (a no-op when $dir is the root, which is always shown).
proc fs_apply_create {dir type name} {
	if {![nav_name_ok $name]} { nav_flash "invalid name" ; return }
	set resp [rio_call fs.create \
		[dict create path [file join $dir $name] type $type]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	if {$dir ne $::nav_root} { dict set ::nav_expanded $dir 1 }   ;# reveal the new entry (root is always shown)
	refresh_dock
}
proc fs_apply_rename {path newname} {
	if {![nav_name_ok $newname]} { nav_flash "invalid name" ; return }
	set to [file join [file dirname $path] $newname]
	set resp [rio_call fs.rename [dict create path $path to $to]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	retarget_buffers $path $to
	refresh_dock
}
proc fs_apply_delete {path} {
	set resp [rio_call fs.delete [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	close_buffers_under $path
	refresh_dock
}

# After a rename, repoint every open buffer at the old path (or under it, for a dir
# rename) to the new path — client-side (so the tab retitles via tab_name) AND in the
# core via buffer.setpath (so the buffer's next Save writes the NEW name, not the old).
proc retarget_buffers {old new} {
	set touched 0
	foreach id [dict keys $::buffers] {
		set p [bufget $id path]
		if {$p eq ""} continue
		if {$p eq $old} {
			set np $new
		} elseif {[string match "$old/*" $p]} {
			set np "$new/[string range $p [expr {[string length $old] + 1}] end]"
		} else {
			continue
		}
		bufset $id path $np
		rio_call buffer.setpath [dict create buffer $id path $np]
		hl_refresh_buffer $id   ;# a new extension may mean a new highlighter (D112)
		set touched 1
	}
	if {$touched} refresh_all
}

# After a delete, close every open buffer at that path (or under it, for a dir). We
# clear the modified flag first so close_tab's discard prompt doesn't offer to save a
# file that no longer exists; close_tab reuses do_close's reactivation / group-collapse.
proc close_buffers_under {path} {
	foreach id [dict keys $::buffers] {
		set p [bufget $id path]
		if {$p eq ""} continue
		if {$p eq $path || [string match "$path/*" $p]} {
			bufset $id modified 0
			close_tab $id
		}
	}
}

# Briefly show a message in the files-pane header, then restore the real header.
# The files sibling of git_flash — reuses the header rather than adding a status
# widget; the scheduled populate_nav repaints the true directory line.
proc nav_flash {text} {
	.pfiles.hdr.head configure -text $text
	after cancel populate_nav
	after 2000 populate_nav
}

# A modal single-line name prompt (New / Rename). rio's first custom modal input —
# existing dialogs are tk_messageBox / tk_chooseDirectory. Returns the entered string,
# or "" on Cancel/Escape/empty. Grab + tkwait make it synchronous like those helpers.
proc name_prompt {title label prefill} {
	set w .nameprompt
	catch {destroy $w}
	toplevel $w
	wm title $w $title
	wm transient $w .
	wm resizable $w 0 0
	set ::name_prompt_result ""
	label $w.l -text $label -anchor w
	entry $w.e -width 32
	ctx_bind_input $w.e   ;# (D115)
	$w.e insert 0 $prefill
	frame $w.b
	button $w.b.ok     -text OK     -width 8 -command [list name_prompt_done $w 1]
	button $w.b.cancel -text Cancel -width 8 -command [list name_prompt_done $w 0]
	pack $w.b.ok $w.b.cancel -side left -padx 4
	pack $w.l -side top -fill x -padx 8 -pady {8 2}
	pack $w.e -side top -fill x -padx 8
	pack $w.b -side top -pady 8
	bind $w.e <Return> [list name_prompt_done $w 1]
	bind $w   <Escape> [list name_prompt_done $w 0]
	wm protocol $w WM_DELETE_WINDOW [list name_prompt_done $w 0]
	# Centre over the main window, then grab focus for the modal wait.
	wm withdraw $w
	update idletasks
	set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth $w])  / 2}]
	set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight $w]) / 3}]
	wm geometry $w +$x+$y
	wm deiconify $w
	$w.e selection range 0 end
	focus $w.e
	grab $w
	tkwait window $w
	return $::name_prompt_result
}
proc name_prompt_done {w ok} {
	if {$ok} { set ::name_prompt_result [string trim [$w.e get]] } \
	else     { set ::name_prompt_result "" }
	catch {grab release $w}
	destroy $w
}

proc open_folder_dialog {} {
	if {$::core_remote} {
		set p [remote_browse_dialog "Open folder (remote)" dir]
	} else {
		set p [tk_chooseDirectory -title "Open folder"]
	}
	if {$p ne ""} { open_folder $p }
}

# ---------------------------------------------------------------------------
# The git pane (AGENTS.md D7 read layer in a view). Shares the dock with the
# file pane — only one shows at a time. A dumb view of the core's git.* against
# the open project (git.* now defaults its cwd to the project root): git.status
# fills the branch + changed-file list, selecting a file fetches git.diff into a
# read-only diff area. No file-watching, so a Refresh button re-reads on demand.
# The change list is an rl_* rich-list too (D43) — same well/bands/nav as the file
# pane — each row's payload being its change dict {x y path ...} (or "" for a
# placeholder like "(clean)").
# ---------------------------------------------------------------------------
# The diff area is collapsible (D13): hidden until a file is picked, so the
# default git pane is just a full-height change list — consistent with the file
# pane — and the diff slides in below (sharing the height) only when there is one
# to read, instead of sitting empty and looking like dead space.
proc git_show_diff {text} {
	.pgit.diff configure -state normal
	.pgit.diff delete 1.0 end
	.pgit.diff insert 1.0 $text
	.pgit.diff configure -state disabled
	if {[lsearch -exact [pack slaves .pgit] .pgit.diff] < 0} {
		pack .pgit.diff -side top -fill both -expand 1
	}
}
proc git_hide_diff {} {
	.pgit.diff configure -state normal
	.pgit.diff delete 1.0 end
	.pgit.diff configure -state disabled
	pack forget .pgit.diff
}

proc refresh_git {} {
	set b .pgit.well.body
	rl_begin $b
	git_hide_diff
	# With no folder open, git.* would fall back to rio's OWN process cwd and show
	# the wrong repo — so the pane is honest about needing a project first.
	if {[dict get [rio_call project.get {}] result root] eq ""} {
		.pgit.hdr.branch configure -text "git"
		git_placeholder "(open a folder)"
		git_commit_bar 0
		git_discard_all_button 0
		rl_end $b
		return
	}
	set resp [rio_call git.status {}]
	if {![dict get $resp ok]} {
		.pgit.hdr.branch configure -text "git"
		set code [dict get $resp error code]
		git_placeholder [expr {$code eq "bad_request" ? "(not a git repository)" \
			: [dict get $resp error message]}]
		git_commit_bar 0
		git_discard_all_button 0
		rl_end $b
		return
	}
	set r [dict get $resp result]
	.pgit.hdr.branch configure -text "⎇ [dict get $r branch]"
	set changes [dict get $r changes]
	if {![llength $changes]} {
		git_placeholder "(clean)"
		git_commit_bar 0
		git_discard_all_button 0
		rl_end $b
		return
	}
	# The commit bar shows only when the index has something to commit: a change whose
	# X (staged column) is a real status char — not clean " " and not untracked "?".
	set staged 0
	foreach c $changes {
		git_render_row $c
		set x [dict get $c x]
		if {$x ne " " && $x ne "?"} { set staged 1 }
	}
	git_commit_bar $staged
	git_discard_all_button [llength $changes]   ;# ↩ in the header, only while there's something to discard (D93)
	rl_end $b
}

# A non-selectable message row (no folder / not a repo / clean). Two-space indent
# keeps it clear of the status gutter column. Caller has the body in -state normal.
proc git_placeholder {text} {
	.pgit.well.body insert end "  $text\n"
	rl_row .pgit.well.body 0 ""
}
# One change row: the two porcelain status chars (each colour-tagged by kind), a
# space, then the path. Payload is the whole change dict.
proc git_render_row {c} {
	set b .pgit.well.body
	foreach ch [list [dict get $c x] [dict get $c y]] {
		set tag [git_status_tag $ch]
		if {$tag eq ""} { $b insert end $ch } else { $b insert end $ch $tag }
	}
	$b insert end " [dict get $c path]\n"
	rl_row $b 1 $c
}
# Colour tag for a git porcelain status char (see apply_theme). "" for a blank.
proc git_status_tag {ch} {
	switch -- $ch {
		A - ? { return gitadd }
		D     { return gitdel }
		" "   { return "" }
		default { return gitmod }
	}
}

# Selecting a changed file (onselect) shows its diff. A path staged but not also
# modified in the worktree (X set, Y blank) is shown via --cached; otherwise the
# worktree diff. An untracked file has no textual diff — git returns empty, said
# plainly. The payload is the change dict ("" for a placeholder row).
proc git_pick {row} {
	if {$row eq ""} { git_hide_diff ; return }
	set x [dict get $row x] ; set y [dict get $row y]
	set staged [expr {$y eq " " && $x ne " " && $x ne "?"}]
	set resp [rio_call git.diff [dict create path [dict get $row path] staged $staged]]
	if {![dict get $resp ok]} {
		git_show_diff [dict get $resp error message]
		return
	}
	set d [dict get $resp result diff]
	git_show_diff [expr {$d eq "" ? "(no textual diff)" : $d}]
}

# Right-click a change row (oncontext): Open the file (file rows only — see below), Copy
# Path, and Stage/Unstage from its X/Y (D44). The porcelain path is repo-root-relative and
# the project root is the repo root, so it doubles as git's cwd-relative path; Open needs
# the abspath.
# git_menu_build fills the menu (separated for headless inspection); the wrapper posts.
proc git_context_menu {payload X Y} {
	catch {destroy .gitmenu}
	menu .gitmenu -tearoff 0
	git_menu_build .gitmenu $payload
	tk_popup .gitmenu $X $Y
}
proc git_menu_build {m payload} {
	set path [dict get $payload path]
	# A wholly untracked DIRECTORY is one porcelain row, marked only by its trailing slash
	# — which survives here, though `file join` strips it from the tree's map. It is a
	# folder, so it has no text to open and staging it stages everything under it: drop
	# Open, and say "folder" where the act is the folder's. Reaching one file inside it is
	# the file tree's job (nav_menu_git), since only the tree lists them.
	set isdir [string match "*/" $path]
	set root [dict get [rio_call project.get {}] result root]
	set abs  [file join $root $path]
	if {!$isdir} { $m add command -label "Open" -command [list do_open $abs] }
	$m add command -label "Copy Path" -command [list rio_copy_clip $abs]
	set x [dict get $payload x] ; set y [dict get $payload y]
	$m add separator
	if {$y ne " "} {
		$m add command -label [expr {$isdir ? "Stage folder" : "Stage"}] \
			-command [list do_git add $path]
	}
	if {$x ne " " && $x ne "?"} {
		$m add command -label "Unstage" -command [list do_git unstage $path]
	}
	# Discard is destructive, so it's confirm-gated (like file Delete, D48) and set apart
	# by a separator. A NEW file — untracked ("?") or a staged addition ("A") — has no
	# committed version, so discarding DELETES it; a tracked change reverts to the last
	# commit. Word each for what it actually does (D80).
	$m add separator
	if {$x eq "?" || $x eq "A"} {
		$m add command -label "Delete…"          -command [list git_discard_confirm $path 1]
	} elseif {$x eq "R"} {
		# A rename discards back to the OLD name (D97), which is a different promise from
		# "reverts its contents" — so hand the confirm the name it will reappear under.
		# Only this door can: porcelain carries the original path, the file tree doesn't.
		$m add command -label "Discard Changes…" \
			-command [list git_discard_confirm $path 0 [dict get $payload orig]]
	} else {
		$m add command -label "Discard Changes…" -command [list git_discard_confirm $path 0]
	}
}

# Run a git write op (add | unstage) on a path, then repaint the shown pane so the
# new flag / change list appears. The path may be a file-pane abspath or a git-pane
# repo-relative path — git resolves both against the project-root cwd.
proc do_git {op path} {
	set resp [rio_call git.$op [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	refresh_dock
}

# Confirm, then discard a change row's local changes (git.discard, D80). `isnew` picks the
# wording — a new file is DELETED (nothing committed to fall back to); a tracked file
# REVERTS to the last commit. `orig` is a rename's original path (D97), where reverting
# also moves the file back under that name — say so, because the file vanishing from the
# tree under the name you right-clicked would otherwise read as a deletion. Both are
# irreversible, so the default button is No (mirrors the file Delete confirm, D48). On
# success the pane repaints and the header flashes the outcome.
proc git_discard_confirm {path isnew {orig ""}} {
	if {$isnew} {
		set q "Delete “$path”?\n\nThis is a new file, not in the last commit — deleting it can't be undone."
	} elseif {$orig ne ""} {
		set q "Discard the rename of “$orig”?\n\nIt will go back to its old name and its last committed contents. This can't be undone."
	} else {
		set q "Discard changes to “$path”?\n\nIt will return to the last committed version. This can't be undone."
	}
	if {[tk_messageBox -icon warning -type yesno -default no -title "rio — discard" -message $q] ne "yes"} {
		return
	}
	set resp [rio_call git.discard [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	refresh_dock
	if {[dict get $resp result action] eq "remove"} {
		git_flash "✓ deleted"
	} elseif {$orig ne ""} {
		git_flash "✓ rename undone"
	} else {
		git_flash "✓ discarded changes"
	}
}

# Show or hide the header's ↩ button — "discard all" (D93) — and stash the change count the
# confirm will quote. refresh_git passes the number of changes, so the button is packed
# exactly when there is something to discard: the commit bar's rule (D45, the D36 "only when
# needed" bar) applied to the header, which also keeps a destructive control off the chrome
# of a clean repo. Packed with -side right AFTER ⟳ was, so it sits to ⟳'s left.
proc git_discard_all_button {n} {
	set ::git_change_count $n
	if {$n > 0} {
		if {[lsearch -exact [pack slaves .pgit.hdr] .pgit.hdr.discard] < 0} {
			pack .pgit.hdr.discard -side right
		}
	} else {
		pack forget .pgit.hdr.discard
	}
}

# Confirm, then discard EVERY change in the project (git.discard_all, D93). One core call,
# not one per file — the core does the whole sweep in git and returns how many changes it
# found. This is the most destructive thing rio can do to a working tree, so the question
# spells out both halves (changed files revert, never-committed files are deleted), says
# what it does NOT touch, and defaults to No like every other irreversible action (D48, D80).
proc git_discard_all_confirm {} {
	if {$::git_change_count <= 0} return
	set q "Discard all $::git_change_count [git_plural $::git_change_count change] in this project?\n\nEvery changed file goes back to its last committed version, and files that were never committed are deleted. Files git ignores are left alone.\n\nThis can't be undone."
	if {[tk_messageBox -icon warning -type yesno -default no -title "rio — discard all" -message $q] ne "yes"} {
		return
	}
	set resp [rio_call git.discard_all {}]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	set n [dict get $resp result count]
	refresh_dock
	git_flash "✓ discarded $n [git_plural $n change]"
}
# "1 change" / "2 changes" — the count is real data (it says how much is about to go), so
# it can be 1, and "1 changes" in a warning dialog reads as a bug.
proc git_plural {n word} {
	return [expr {$n == 1 ? $word : "${word}s"}]
}

# Show or hide the commit bar (D45). refresh_git calls this with 1 when the index has a
# staged change to commit, 0 otherwise — so the bar is present exactly when committing is
# meaningful. Packed at the very bottom of the git pane (below the change list and any
# diff). Hiding clears the entry so a stale message never lingers into the next repo.
proc git_commit_bar {show} {
	if {$show} {
		if {[lsearch -exact [pack slaves .pgit] .pgit.commit] < 0} {
			pack .pgit.commit -side bottom -fill x
		}
	} else {
		pack forget .pgit.commit
		.pgit.commit.msg delete 0 end
		.pgit.commit.body delete 1.0 end
		git_commit_body_set 0
	}
}

# Show/hide the optional multi-line description below the summary (D80). Re-packs the
# whole bar each time so the row order is deterministic: body (when shown) claims the
# bottom, then Commit + ＋ on the right, the summary filling the left. `＋`/`−` on the
# toggle says which way it goes. Collapsed is the default — most commits are one line,
# so the bar stays a single row until the user asks for more (the D36 "only when needed"
# quality bar, applied within the bar).
proc git_commit_body_set {show} {
	foreach w {.pgit.commit.body .pgit.commit.msg .pgit.commit.go .pgit.commit.more} {
		catch {pack forget $w}
	}
	if {$show} { pack .pgit.commit.body -side bottom -fill x -padx 4 -pady {0 3} }
	pack .pgit.commit.go   -side right -padx {2 4} -pady 2
	pack .pgit.commit.more -side right -pady 2
	pack .pgit.commit.msg  -side left -fill x -expand 1 -padx {4 2} -pady 2
	set ::git_commit_body_shown $show
	.pgit.commit.more configure -text [expr {$show ? "−" : "＋"}]
	if {$show} { git_commit_body_hint ; focus .pgit.commit.body }
}
proc git_commit_body_toggle {} { git_commit_body_set [expr {!$::git_commit_body_shown}] }

# The body's greyed placeholder, shown only while the description is empty (the same
# device as the summary hint — a child label placed over the text widget, never part of
# `.body get`, so the commit assembly stays honest).
proc git_commit_body_hint {args} {
	if {[string trim [.pgit.commit.body get 1.0 end]] eq ""} {
		place .pgit.commit.body.ph -x 4 -y 3 -anchor nw
	} else {
		place forget .pgit.commit.body.ph
	}
}

# Show the greyed "message" hint exactly while the commit entry is empty; hide it once
# the user has typed anything. Driven by the git_commit_msg textvariable trace, so it
# tracks typing, clearing, and refresh-driven resets alike.
proc git_commit_hint {args} {
	global git_commit_msg
	if {$git_commit_msg eq ""} {
		place .pgit.commit.msg.ph -x 3 -rely 0.5 -anchor w
	} else {
		place forget .pgit.commit.msg.ph
	}
}

# Commit the staged index with the bar's summary line, plus the optional description
# body joined as "summary\n\nbody" — git's own convention (subject, blank line, body),
# which `git commit -m` records verbatim, so the core op is unchanged. An empty (or
# whitespace) SUMMARY is refused quietly — a flash, focus kept, no core call — rather than
# letting git abort; an empty body just adds nothing. On success the staged changes vanish,
# so refresh_dock auto-hides the bar; the header then flashes the new short hash.
proc git_commit {} {
	set summary [string trim [.pgit.commit.msg get]]
	if {$summary eq ""} { git_flash "enter a commit message" ; focus .pgit.commit.msg ; return }
	set body [string trim [.pgit.commit.body get 1.0 end]]
	set msg $summary
	if {$body ne ""} { append msg "\n\n" $body }
	set resp [rio_call git.commit [dict create message $msg]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	.pgit.commit.msg delete 0 end
	.pgit.commit.body delete 1.0 end
	git_commit_body_set 0
	refresh_dock
	git_flash "✓ committed [dict get $resp result hash]"
}

# Briefly show a message in the git header's branch label, then restore it. Reuses the
# header rather than adding a status widget; the scheduled refresh_git repaints the real
# branch line. Runs after refresh_dock, so the flash survives that repaint.
proc git_flash {text} {
	.pgit.hdr.branch configure -text $text
	# The op that flashed here has usually just announced fs.changed as well (D94), and
	# that idle repaint would wipe the message before anyone read it. Drop it while the
	# git pane is the one showing — the scheduled refresh_git below repaints all the same,
	# once the flash has had its 2.5s. With another pane shown the settle is left alone:
	# it is repainting the file tree, which the flash has no claim on.
	if {$::dock_pane eq "git" && $::fs_changed_after ne ""} {
		after cancel $::fs_changed_after
		set ::fs_changed_after "" ; set ::fs_changed_paths {}
	}
	after cancel refresh_git
	after 2500 refresh_git
}

# An auto-hiding scrollbar: visible only when the view can't show everything.
# Wired as a widget's -yscrollcommand (Tk appends the lo/hi fractions). It re-packs
# with -before the scrolled widget so it reclaims its edge instead of being
# squeezed to zero width by that widget's -expand. Keeps the dock uncluttered
# when a short file list or change list fits — the common case.
proc autoscroll {sb widget lo hi} {
	if {$lo <= 0.0 && $hi >= 1.0} {
		pack forget $sb
	} else {
		pack $sb -side right -fill y -before $widget
	}
	$sb set $lo $hi
}

# Same idea for a grid-managed scrollbar (the editor's horizontal bar). grid remove
# keeps the cell config, so re-`grid`ing restores its row/col. Wired as the editor's
# -xscrollcommand so the bar shows only when a line runs past the right edge.
proc gridscroll {sb lo hi} {
	if {$lo <= 0.0 && $hi >= 1.0} { grid remove $sb } else { grid $sb }
	$sb set $lo $hi
}

# Blend two "#rrggbb" colours: pct% of b mixed into a, returned as "#rrggbb". Used
# to derive theme-relative tints (e.g. the files pane's hover band) without needing
# a dedicated theme role for every shade. winfo rgb resolves names/hex to 16-bit
# channels; we scale back to 8-bit.
proc blend_hex {a b pct} {
	lassign [winfo rgb . $a] ar ag ab
	lassign [winfo rgb . $b] br bg bb
	set mix [list]
	foreach x [list $ar $ag $ab] y [list $br $bg $bb] {
		lappend mix [expr {(($x * (100 - $pct) + $y * $pct) / 100) >> 8}]
	}
	return [format "#%02x%02x%02x" {*}$mix]
}

# ---------------------------------------------------------------------------
# The dock: which pane shows, and which edge it sits on. Both are runtime choices
# driven from the View menu; apply_layout and show_pane are the two seams.
# ---------------------------------------------------------------------------
# Reveal a panel wherever it currently lives: give it a tab (unhide) in its site and
# make it the active/foreground one, then refresh. The robust "show me pane X" the
# reveal keys (Ctrl+E/G) use — it works even when the panel was hidden or in another
# site, so a panel can always be recovered (no pane ever becomes unreachable).
proc panel_reveal {id} {
	set s [rio::layout::site_of $id]
	if {$s eq ""} return
	rio::layout::unhide $s $id
	rio::layout::put $s active $id
	set ::layout [rio::layout::normalize $::layout]   ;# recompute derived visible
	apply_layout
	rio::panel::refresh $id
}
# Back-compat: "show the files/git pane" (Ctrl+E/G) is a reveal (idempotent "go to").
proc show_pane {which} { panel_reveal $which }

# Show/hide a pane — the View-menu checkbuttons' toggle. "Hide" means NO TAB at all
# (not merely backgrounded): a shown pane loses its tab (added to the site's hidden
# list); if it was the foreground tab, another shown pane takes over, and if it was
# the site's last shown pane the whole dock collapses. A hidden pane is revealed (tab
# back + foreground). normalize re-derives the site's visibility and active; apply_layout
# resyncs the ::shown_* mirrors so the checkmarks track tab presence.
proc panel_toggle {id} {
	set s [rio::layout::site_of $id]
	if {$s eq ""} return
	if {[rio::layout::shown $id]} {
		rio::layout::hide $s $id
	} else {
		rio::layout::unhide $s $id
		rio::layout::put $s active $id
	}
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	rio::panel::refresh $id
}

# Draw site `site`'s host tab strip: one label per docked panel (its registry
# title), the active one highlighted like a selected tab. Rebuilt from scratch each
# layout pass (cheap — a handful of labels) so it always matches ::layout. Clicking
# a tab activates that panel. This replaces the old bespoke Files/Git selector.
proc render_tabs {site} {
	set f .site$site.tabs
	foreach w [winfo children $f] { destroy $w }
	set c $::theme_colors
	set active [rio::layout::get $site active]
	foreach id [rio::layout::shown_panels $site] {
		set t $f.$id
		label $t -text [rio::panel::field $id title] -font RioUIFont -padx 8 -pady 1 \
			-foreground [dict get $c tab.fg] \
			-background [expr {$id eq $active ? [dict get $c tab.active.bg] : [dict get $c tab.inactive.bg]}]
		pack $t -side left -padx 1 -pady 1
		# Press/motion/release drive click-vs-drag (D35 c3); right-click is Move to (c2).
		bind $t <ButtonPress-1>   [list tab_press $site $id %X %Y]
		bind $t <B1-Motion>       [list tab_motion %X %Y]
		bind $t <ButtonRelease-1> [list tab_release $site $id %X %Y]
		bind $t <Button-3>        [list site_tab_menu $site $id %X %Y]
	}
}

# Activate panel `id` in site `site` (a tab click). Only which body shows in THIS
# site changes — sizes, edges and the other sites are untouched — so we swap in
# place instead of calling apply_layout, which forgets and re-packs every site,
# sash and the center editor area and makes the whole window flicker (D35 polish).
# The outgoing body is forgotten, this site's tab strip + body re-rendered, the
# dockside mirror kept correct (View menu radios read ::dock_pane), and prefs saved.
proc site_tab_click {site id} {
	set prev [rio::layout::get $site active]
	if {$prev eq $id} { rio::panel::refresh $id ; return }
	rio::layout::put $site active $id
	if {$prev ne ""} { catch {pack forget [rio::panel::field $prev body]} }
	render_tabs $site
	render_site_body $site
	if {$site eq [rio::layout::dockside]} {
		set da [rio::layout::get $site active]
		set ::dock_pane [expr {$da in {files git} ? $da : "files"}]
	}
	prefs_save
	rio::panel::refresh $id
}

# Pack site `site`'s active panel body into its .body area. Bodies are toplevel
# children moved between sites via -in; a slave packed into a non-parent master must
# be raised above it or it is obscured.
proc render_site_body {site} {
	set active [rio::layout::get $site active]
	if {$active eq ""} return
	set body [rio::panel::field $active body]
	pack $body -in .site$site.body -fill both -expand 1
	raise $body .site$site.body
}

# Derive the whole non-document layout from ::layout (D35 step b/c) — the single
# choke point that replaces the old place_dock/show_pane/search packing. Each site
# (when visible and non-empty) renders its tab strip + active body and claims its
# edge; the center is the editor groups (or the compare view in their place, D28).
# The bottom site is packed first so it spans the full width and the side docks stop
# above it (the old Search-strip behaviour). The legacy ::dock_* / ::chat_shown /
# ::search_shown globals are refreshed from the sites so menus and read-only call
# sites stay correct (::dock_pane is pinned to files|git — the dock's selection —
# even when its site's active tab is another panel like chat).
proc apply_layout {} {
	set ds [rio::layout::dockside]                 ;# left|right — the files/git side
	set da [rio::layout::get $ds active]
	set ::dock_side  $ds
	set ::dock_pane  [expr {$da in {files git} ? $da : "files"}]
	set ::chat_shown [rio::layout::get [rio::layout::site_of chat] visible]
	set ::search_shown [rio::layout::get bottom visible]
	# Per-pane shown mirrors for the View-menu toggle checkmarks (has a tab / not hidden).
	foreach _p {files git chat search} { set ::shown_$_p [rio::layout::shown $_p] }

	catch {pack forget .siteleft .siteright .sitebottom .sash .csash .bsash .groups .cmp .plan}
	foreach id [rio::panel::ids] { catch {pack forget [rio::panel::field $id body]} }

	set showL [expr {[rio::layout::get left   visible] && [llength [rio::layout::get left   panels]]}]
	set showR [expr {[rio::layout::get right  visible] && [llength [rio::layout::get right  panels]]}]
	set showB [expr {[rio::layout::get bottom visible] && [llength [rio::layout::get bottom panels]]}]

	if {$showB} {
		render_tabs bottom ; render_site_body bottom
		pack .sitebottom -side bottom -fill x
		pack .bsash -side bottom -fill x          ;# height grip on the dock's top edge
		.sitebottom configure -height [rio::layout::get bottom size]
	}
	if {$showL} {
		render_tabs left ; render_site_body left
		pack .siteleft -side left -fill y ; pack .sash -side left -fill y
		.siteleft configure -width [rio::layout::get left size]
	}
	if {$showR} {
		render_tabs right ; render_site_body right
		pack .siteright -side right -fill y ; pack .csash -side right -fill y
		.siteright configure -width [rio::layout::get right size]
	}
	if {$::plan_shown} {
		pack .plan -side left -fill both -expand 1
	} elseif {$::compare_shown} {
		pack .cmp -side left -fill both -expand 1
	} else {
		pack .groups -side left -fill both -expand 1
	}
	prefs_save
}

# Move the files/git dock to `side` (View ▸ Dock Left/Right). Carries the active
# files|git choice and the dock's size; the other side keeps its remaining tenants
# (e.g. chat). normalize repairs membership/actives; moving there implies showing.
proc dock_set_side {side} {
	if {$side ni {left right}} return
	set cur  [rio::layout::dockside]
	if {$cur eq $side} return
	set pane [rio::layout::get $cur active]
	set size [rio::layout::get $cur size]
	# Carry each of files/git's tab-presence (hidden) state across the move.
	set curhid [rio::layout::hidden_of $cur]
	set moved_hidden {} ; foreach p {files git} { if {$p in $curhid} { lappend moved_hidden $p } }
	dict set ::layout sites $cur  panels [rio::layout::_without [rio::layout::get $cur panels] {files git}]
	dict set ::layout sites $cur  hidden [rio::layout::_without $curhid {files git}]
	dict set ::layout sites $side panels [concat {files git} [rio::layout::_without [rio::layout::get $side panels] {files git}]]
	dict set ::layout sites $side hidden [concat [rio::layout::_without [rio::layout::hidden_of $side] {files git}] $moved_hidden]
	dict set ::layout sites $side active $pane
	dict set ::layout sites $side size $size
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
}

# Relocate one panel to another site (D35 c2 — the right-click "Move to" gesture).
# The panel lands with a tab (shown) and becomes its new site's foreground pane; it
# leaves its old site's membership AND hidden list. normalize repairs the site it
# left (active/emptiness) and derives visibility. Refresh so it paints fresh.
proc panel_move {id target} {
	if {$target ni {left right bottom}} return
	set from [rio::layout::site_of $id]
	if {$from eq $target || $from eq ""} return
	dict set ::layout sites $from   panels [rio::layout::_without [rio::layout::get $from panels] [list $id]]
	dict set ::layout sites $from   hidden [rio::layout::_without [rio::layout::hidden_of $from] [list $id]]
	dict set ::layout sites $target panels [concat [rio::layout::get $target panels] [list $id]]
	rio::layout::unhide $target $id            ;# lands with a tab
	dict set ::layout sites $target active $id
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	rio::panel::refresh $id
}

# Pop the tab's context menu: move this panel to a site it isn't already in. Built
# fresh each time (like the nav/git menus), so the current site is greyed out.
proc site_tab_menu {site id X Y} {
	catch {destroy .sitetabmenu}
	menu .sitetabmenu -tearoff 0
	menu .sitetabmenu.to -tearoff 0
	.sitetabmenu add cascade -label "Move to" -menu .sitetabmenu.to
	foreach {t label} {left Left right Right bottom Bottom} {
		.sitetabmenu.to add command -label $label \
			-state [expr {$t eq $site ? "disabled" : "normal"}] \
			-command [list panel_move $id $t]
	}
	tk_popup .sitetabmenu $X $Y
}

# Which dock site (left|right|bottom) the pointer at screen X,Y is over, or "" if
# none — used as the drop target while dragging a tab (D35 c3). The pointer may be
# over a site's chrome (.site$s.*) OR over a panel body, which is a toplevel child
# packed -in the site (path .pfiles/.chat/.results, not under .site$s), so map that
# body back to its panel and thence to the site it currently sits in.
proc site_under_pointer {X Y} {
	set w [winfo containing $X $Y]
	if {$w eq ""} return ""
	foreach s {left right bottom} {
		if {$w eq ".site$s" || [string match ".site$s.*" $w]} { return $s }
	}
	foreach id [rio::panel::ids] {
		set body [rio::panel::field $id body]
		if {$w eq $body || [string match "$body.*" $w]} { return [rio::layout::site_of $id] }
	}
	return ""
}

# Tint each site's tab strip: the drop-target `site` gets the accent, the rest go
# back to their normal bar colour. Called during a drag and cleared on drop.
proc tabdrag_highlight {site} {
	foreach s {left right bottom} {
		if {![winfo exists .site$s.tabs]} continue
		.site$s.tabs configure -background \
			[dict get $::theme_colors [expr {$s eq $site ? "accent" : "ui.bg"}]]
	}
}

# Tab drag (D35 c3): the same relocation as the right-click menu, by dragging. Press
# records the candidate without activating; a motion past a small threshold starts a
# real drag and previews the drop target (the hovered site, if different, lit with
# the accent); release relocates there, or — if it was really just a click, never
# passing the threshold — activates the tab. An invalid/self drop snaps back.
proc tab_press {site id X Y} {
	set ::tabdrag [dict create id $id from $site x0 $X y0 $Y active 0 over ""]
}
proc tab_motion {X Y} {
	if {![info exists ::tabdrag]} return
	if {![dict get $::tabdrag active]} {
		if {abs($X - [dict get $::tabdrag x0]) < 6 && abs($Y - [dict get $::tabdrag y0]) < 6} return
		dict set ::tabdrag active 1
	}
	set over [site_under_pointer $X $Y]
	if {$over ne [dict get $::tabdrag over]} {
		dict set ::tabdrag over $over
		set from [dict get $::tabdrag from]
		tabdrag_highlight [expr {($over ne "" && $over ne $from) ? $over : ""}]
	}
}
proc tab_release {site id X Y} {
	if {![info exists ::tabdrag]} { site_tab_click $site $id ; return }
	set dragging [dict get $::tabdrag active]
	set from     [dict get $::tabdrag from]
	unset ::tabdrag
	tabdrag_highlight ""
	if {!$dragging} { site_tab_click $site $id ; return }   ;# never crossed the threshold — a click
	set over [site_under_pointer $X $Y]
	if {$over ne "" && $over ne $from} { panel_move $id $over }
}

# Lay the editor groups left-to-right inside the .groups panedwindow. In v1 there are
# at most two; each pane -stretches so they share the width, and the panedwindow gives
# a draggable divider between them. Called after a split/unsplit changes ::groups; with
# one group it just fills the center.
proc relayout_groups {} {
	foreach p [.groups panes] { .groups forget $p }
	foreach g $::groups {
		.groups add [gget $g frame] -stretch always -minsize 120
	}
}

# Centre the sash so a fresh split opens 50/50 (Tk otherwise sizes the new pane from its
# requested width, leaving it a sliver). Called only when a split is *created* (add_group)
# — moving tabs between two existing panes never re-lays-out, so a user who has since
# dragged the sash keeps their layout. Runs after idle so the panedwindow has its width.
proc even_split {} {
	if {[llength [.groups panes]] != 2} return
	set w [winfo width .groups]
	if {$w <= 1} return                       ;# not mapped yet (e.g. headless) — skip
	.groups sash place 0 [expr {$w / 2}] 0
}

# Drag the sash to resize the LEFT site (always on the left edge; D35 c1b). The site
# keeps a fixed -width (propagate off), so we recompute it from the pointer measured
# against the TOPLEVEL'S stable edge (not the site's own, which moves as we resize it
# — referencing that fed back on itself and made the panes jump). The toplevel also
# has propagation off (startup), so a wider site shrinks the editor instead of the
# whole window. Clamped so neither side collapses.
proc sash_drag {} {
	set total [winfo width .]
	set min 120
	set max [expr {$total - 200}]
	set w [expr {[winfo pointerx .] - [winfo rootx .]}]
	if {$w < $min} { set w $min }
	if {$max > $min && $w > $max} { set w $max }
	.siteleft configure -width $w
}

# Toggle line wrapping (View menu). With wrap on, lines fold at the word and the
# horizontal scrollbar is meaningless, so it is hidden; with wrap off the bar comes
# back for long lines. Configures every group's real widget (the proxy only guards
# edits) and its own horizontal scrollbar.
proc apply_wrap {} {
	set mode [expr {$::wrap_lines ? "word" : "none"}]
	foreach g $::groups {
		set t [gw $g] ; set hsb [gget $g frame].hsb
		$t configure -wrap $mode
		if {$::wrap_lines} {
			grid remove $hsb
		} else {
			gridscroll $hsb {*}[$t xview]   ;# show only if a line overflows
		}
	}
	cmp_apply_wrap
	prefs_save
}

# The compare panes have no horizontal scrollbar, so wrap is the only way to read
# long lines there; keep them in step with the editor's View ▸ Wrap Lines.
proc cmp_apply_wrap {} {
	set w [expr {$::wrap_lines ? "word" : "none"}]
	.cmp.l.t configure -wrap $w
	.cmp.r.t configure -wrap $w
}

# ---------------------------------------------------------------------------
# Line-number gutter (View ▸ Line Numbers). A thin canvas down the left of each
# editor group showing one number per LOGICAL line, drawn from the text widget's
# own dlineinfo so a wrapped line's number sits at its FIRST display row (VSCode's
# behaviour) and the two never drift. It repaints on every signal that can change what
# the numbers should read: a view move (the widget's -yscrollcommand), a resize/re-wrap
# (<Configure>), a text edit (apply_change) and a tab switch/open (load_buffer). The
# last two matter because an edit that adds/removes lines — or a same-height buffer
# swap — need not move the view, so -yscrollcommand alone would leave stale numbers.
# All coalesced to one idle pass so a fast scroll or a burst of typing paints once. Pure
# display: the numbers live only in the canvas, never in the buffer text (D12).
# ---------------------------------------------------------------------------

# The editor's -yscrollcommand: drive the group's own vertical scrollbar, then mark
# its gutter for repaint (the scrollbar move is exactly our "view changed" signal).
proc edscroll {g lo hi} {
	[gget $g frame].vsb set $lo $hi
	gutter_mark $g
	hl_vmark $g     ;# the window moved — highlight whatever just came into view (D126)
}

# Coalesce a group's gutter repaints into a single idle callback.
proc gutter_mark {g} {
	after cancel [list gutter_redraw $g]
	after idle   [list gutter_redraw $g]
}

# The editor widget changed shape: resized, re-wrapped, or zoomed. Both the gutter and
# the highlight window are derived from the visible line range, so both want re-deriving.
proc editor_reconfigured {g} {
	gutter_mark $g
	hl_vmark $g
}

# The number a gutter row paints for logical line `ln` when the caret sits on line
# `caret`. Absolute normally; with relative numbering on, every line BUT the caret's
# shows its DISTANCE from the caret (vim's hybrid number+relativenumber — the caret line
# keeps its absolute number as a where-am-I anchor). Pure (no Tk) so it unit-tests, where
# the painted glyphs can't (dlineinfo needs a mapped window — see the D49 gutter smoke).
proc gutter_label {ln caret relative} {
	return [expr {$relative && $ln != $caret ? abs($ln - $caret) : $ln}]
}

# Repaint group g's line-number canvas to match its visible lines. The width (sized
# to the last line's digit count, min two) is set even off-screen so it is stable
# without a render; the numbers themselves are drawn only once the canvas is mapped —
# dlineinfo needs a real geometry. Walks the visible logical lines (@0,0 down to the
# bottom pixel); a line with no display box (scrolled past / elided) is skipped, so
# wrapped lines fall out naturally. No-op when the gutter is off or the group is gone.
proc gutter_redraw {g} {
	if {!$::line_numbers} return
	if {![dict exists $::grp $g]} return
	set gut [gget $g frame].gutter
	if {![winfo exists $gut]} return
	set t [gw $g]                 ;# the renamed widget COMMAND (::real$g) — subcommands only
	set win [gget $g path]        ;# its window PATH (.eg$g.t) — what winfo takes
	set last [expr {int([$t index end-1c])}]
	set digits [expr {max(2, [string length $last])}]
	set w [expr {$digits * [font measure RioEditorFont 0] + 12}]
	if {[$gut cget -width] != $w} { $gut configure -width $w }
	$gut delete all
	if {![winfo ismapped $gut]} return
	set fg [dict get $::theme_colors gutter.fg]
	set top [expr {int([$t index @0,0])}]
	set bot [expr {int([$t index @0,[winfo height $win]])}]
	if {$bot > $last} { set bot $last }
	set caret [expr {int([$t index insert])}]   ;# anchor for relative numbering
	for {set ln $top} {$ln <= $bot} {incr ln} {
		set dl [$t dlineinfo $ln.0]
		if {$dl eq ""} continue
		set y [expr {[lindex $dl 1] + [lindex $dl 3] / 2}]
		$gut create text [expr {$w - 6}] $y -anchor e -fill $fg -font RioEditorFont \
			-text [gutter_label $ln $caret $::relative_line_numbers]
	}
}

# View-menu toggle: show or hide every group's gutter, then persist. Showing it
# re-grids the canvas into column 0 (grid remembers the cell) and paints it; hiding
# grid-removes it. The gutter's colours ride apply_theme (restyle_group).
proc apply_line_numbers {} {
	foreach g $::groups {
		set gut [gget $g frame].gutter
		if {$::line_numbers} {
			grid $gut
			gutter_redraw $g
		} else {
			grid remove $gut
		}
	}
	prefs_save
}

# Click a gutter number to select its whole logical line; drag to extend the selection
# line-by-line, up or down (D61). The gutter shares the text's vertical extent and scroll
# position (both grid row 1) and gutter_redraw draws each number at the text widget's own
# dlineinfo y, so a canvas y inverts back through `index @0,$y`. We anchor at the pressed
# line and select the inclusive span anchor..current; the `$b.0 lineend +1c` end reaches
# past the newline for a full-width line select (the D60 curline trick) and clamps to `end`
# on the last, newline-less line. The gutter is -takefocus 0, so we move keyboard focus to
# the text ourselves; cursor_moved refreshes the status Ln/Col and the D60 current-line band.
proc gutter_press {g y} {
	if {![dict exists $::grp $g]} return
	focus_group $g
	focus [gget $g path]
	set ln [expr {int([[gw $g] index @0,$y])}]
	set ::gutter_anchor $ln            ;# scalar — only one drag at a time
	gutter_select $g $ln $ln
}
proc gutter_motion {g y} {
	if {![dict exists $::grp $g] || ![info exists ::gutter_anchor]} return
	gutter_select $g $::gutter_anchor [expr {int([[gw $g] index @0,$y])}]
}
proc gutter_select {g a b} {
	if {$a > $b} { lassign [list $b $a] a b }
	set t [gw $g]
	$t tag remove sel 1.0 end
	$t tag add sel $a.0 "$b.0 lineend +1c"
	$t mark set insert "$b.0 lineend +1c"
	$t see insert
	cursor_moved $g
}

# ---------------------------------------------------------------------------
# Current-line highlight (View ▸ Highlight Current Line). A full-width background
# band on the LOGICAL line the insert caret sits on, one per editor group so a split
# shows the band under each pane's own caret. Pure display: a `curline` tag, coloured
# by restyle_group from the editor.currentline role and lowered under selection / find
# so those paint over it. The range is `insert linestart` … `insert lineend +1c` — the
# +1c reaches into the newline so the band spans the full width (selrow's trick); a
# wrapped logical line is covered across all its display rows. Updated wherever the
# caret can move: cursor_moved (typing / arrows / click), refresh_status (open / switch
# / jump / reload, which all route through it) and the search-result jump.
# ---------------------------------------------------------------------------

# Repaint group g's caret-line band to its current insert position (or clear it when
# the feature is off / the group is gone).
proc curline_update {g} {
	if {![dict exists $::grp $g]} return
	set t [gw $g]
	if {$::relative_line_numbers} { gutter_mark $g }  ;# relative gutter is caret-anchored — repaint as the caret moves (idle-coalesced; gutter_redraw no-ops when the gutter is hidden)
	$t tag remove curline 1.0 end
	if {!$::highlight_current_line} return
	$t tag add curline "insert linestart" "insert lineend +1c"
}

# View-menu toggle: re-band (or clear) every group, then persist.
proc apply_curline {} {
	foreach g $::groups { curline_update $g }
	prefs_save
}

# View-menu toggle: relative numbering is a modifier on the shown gutter, so just repaint
# every group's gutter (gutter_redraw no-ops when the gutter is hidden), then persist. The
# gutter's width stays sized to the absolute last-line digits, so toggling relative — or
# moving the caret — never reflows it.
proc apply_relnum {} {
	foreach g $::groups { gutter_redraw $g }
	prefs_save
}

# ---------------------------------------------------------------------------
# Wrap indent (View ▸ Indent Wrapped Lines). With line wrap on, Tk shows a
# logical line's leading indentation on its FIRST display line only; the wrapped
# continuation lines fall back to the left margin. With this on, each continuation
# line is indented to sit under its own line's first non-whitespace character —
# VSCode's "wrappingIndent: same". It is a pure display layer: a per-line
# -lmargin2 tag sized to the line's leading whitespace, so it works on plain
# (un-highlighted) files too. Tk tags ride with the text on insert/delete, so an
# edit only recomputes the lines it actually touched (apply_change), never the
# whole buffer. No visible effect while wrap is off — the tags simply wait.
# ---------------------------------------------------------------------------

# Visual column of a line's first non-whitespace char, tabs expanded to the
# widget's default 8-column stops (make_editor_group sets no -tabs).
proc wrapind_cols {line} {
	set col 0
	foreach ch [split $line ""] {
		if {$ch eq " "}  { incr col ; continue }
		if {$ch eq "\t"} { set col [expr {($col / 8 + 1) * 8}] ; continue }
		break
	}
	return $col
}

# Pixels per monospace column of the editor font (rio's editor font is monospace
# by design; a proportional font would only skew the alignment, never break it).
proc wrapind_colpx {} { return [font measure RioEditorFont "0"] }

# The wrapind:<cols> tags currently defined on widget t.
proc wrapind_tags {t} {
	set out {}
	foreach tag [$t tag names] { if {[string match wrapind:* $tag]} { lappend out $tag } }
	return $out
}

# (Re)compute the wrap indent for lines L1..L2 of t: drop any old wrapind tag on
# each line, then — when enabled and the line is indented — tag it with a
# wrapind:<cols> tag whose -lmargin2 matches that indentation. One shared tag per
# distinct column count, created on demand.
proc wrapind_apply {t L1 L2} {
	if {$L2 < $L1} return
	set tags [wrapind_tags $t]
	for {set L $L1} {$L <= $L2} {incr L} {
		foreach tag $tags { $t tag remove $tag $L.0 "$L.0 lineend" }
		if {!$::wrap_indent} continue
		set cols [wrapind_cols [$t get $L.0 "$L.0 lineend"]]
		if {$cols == 0} continue
		set tag wrapind:$cols
		$t tag configure $tag -lmargin2 [expr {$cols * [wrapind_colpx]}]
		$t tag add $tag $L.0 "$L.0 lineend"
	}
}

# Whole-buffer refresh for group g (on open/switch and the menu toggle).
proc wrapind_group {g} {
	if {![winfo exists [gget $g path]]} return
	set t [gw $g]
	wrapind_apply $t 1 [hl_linecount $t]
}

# Reconfigure existing wrapind tags after a font change (pixels-per-column moved).
proc wrapind_refont {t} {
	set px [wrapind_colpx]
	foreach tag [wrapind_tags $t] {
		$t tag configure $tag -lmargin2 [expr {[lindex [split $tag :] 1] * $px}]
	}
}

# View-menu toggle: re-tag every group, then persist (prefs_save self-gates on boot).
proc apply_wrap_indent {} {
	foreach g $::groups { wrapind_group $g }
	prefs_save
}

# Recolour every site's tab strip to the current theme (the active tab stands out,
# the rest recede). Called from apply_theme; render_tabs does the same colouring
# when a layout pass rebuilds a strip. Guarded so it can run before the sites exist.
proc restyle_tabs {} {
	foreach s {left right bottom} {
		if {[winfo exists .site$s.tabs]} { render_tabs $s }
	}
}

# ---------------------------------------------------------------------------
# The agent chat pane (AGENTS.md D14 `chat` column; D20/D26/D30). A dumb view (D3)
# over the agent.* event stream: a read-only transcript, a composer, and Send.
# agent.send is a STREAMING op — its reply is an ack, and the turn's content arrives
# as agent.delta events the core broadcasts over the channel (D30), routed here by
# dispatch_event and appended live (chat_event), so the answer builds in view;
# agent.message closes the turn, agent.error shows a classified failure (D26). The
# core owns the conversation (D3): chat_clear is agent.reset. Right side; toggleable.
# ---------------------------------------------------------------------------
# Insert into the read-only transcript (briefly enabled), scrolling to the end.
proc chat_log {text {tag ""}} {
	.chat.log configure -state normal
	if {$tag eq ""} { .chat.log insert end $text } else { .chat.log insert end $text $tag }
	.chat.log configure -state disabled
	.chat.log see end
}
# A speaker label opening a block (a blank line between blocks, not at the top).
proc chat_label {tag label} {
	if {[.chat.log index "end-1c"] ne "1.0"} { chat_log "\n" }
	chat_log "$label\n" $tag
}

# Send the composer's text as a turn (D26). agent.send is a streaming op: its reply
# is just an ack — the turn's content streams back afterward as agent.* events the
# core broadcasts over the channel, landing in chat_event via dispatch_event (D30).
proc chat_send {} {
	set text [string trim [.chat.input get 1.0 end]]
	if {$text eq ""} return
	.chat.input delete 1.0 end
	chat_send_text $text
}

# The one path a turn leaves the GUI by — the composer above, and Change with Agent…
# (D113), which passes the selection's `scope` {buffer start end} and a `note` saying
# what the request is about, shown muted under the user's words.
proc chat_send_text {text {scope {}} {note ""}} {
	# Sending a new message abandons any proposal still awaiting a decision; the core
	# seals the dangling tool call, so dismiss its review UI here to match (D28).
	if {$::pending_turn ne ""} { approve_bar 0 ; compare_close ; plan_close }
	chat_label you-label "You"
	chat_log "$text\n"
	if {$note ne ""} { chat_log "· $note\n" tool }
	set ::chat_turn_open 0
	set params [dict merge [dict create text $text] $scope]
	set resp [rio_call agent.send $params]
	if {![dict get $resp ok]} {
		set e [dict get $resp error]
		chat_label error-label "Error"
		chat_log "[dict get $e message] ([dict get $e code])\n"
	} else {
		chat_busy_start   ;# the turn is in flight — animate until it replies (D82)
	}
}

# Apply one streamed agent.* event to the transcript.
proc chat_event {ev} {
	switch -- [dict get $ev event] {
		agent.delta {
			if {!$::chat_turn_open} { chat_label agent-label "Agent" ; set ::chat_turn_open 1 }
			chat_log [dict get $ev params text]
		}
		agent.message {
			# A provider that didn't stream deltas still shows its full reply.
			if {!$::chat_turn_open} {
				chat_label agent-label "Agent"
				chat_log [dict get $ev params text]
			}
			chat_log "\n"
			set ::chat_turn_open 0
			chat_busy_stop   ;# turn done (D82)
		}
		agent.error {
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			chat_busy_stop   ;# turn failed (D82)
			approve_bar 0
			chat_label error-label "Error"
			chat_log "[dict get $ev params message] ([dict get $ev params code])\n"
		}
		agent.stopped {
			# The user stopped the turn (D104) — here or in another frontend attached to
			# the same core. Not an error: it did what it was told, so it gets the muted
			# tool styling rather than the red error label. Any review UI the turn had put
			# up is asking about a decision nothing waits for now.
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			chat_busy_stop
			approve_bar 0 ; compare_close ; plan_close
			chat_log "· stopped\n" tool
		}
		agent.tool {
			# A read-only tool the agent is running (D26 slice 4) — auto-executed, so
			# this is transparency, not a prompt. Shown on its own line, mid-turn.
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			set args [dict get $ev params args]
			chat_log "· [dict get $ev params name][expr {$args eq "" ? "" : " $args"}]\n" tool
		}
		agent.propose {
			# A proposed action awaiting the user's decision. Two kinds (D26 s5, D83):
			# an EDIT carries a diff (auto-accept may skip the gate); a run_command
			# carries the argv and is ALWAYS gated (never auto-run, even under
			# auto-accept edits — running a command is the more dangerous act).
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			set turn [dict get $ev params turn]
			set kind [expr {[dict exists $ev params kind] ? [dict get $ev params kind] : "edit"}]
			if {$kind eq "plan"} {
				# A plan (D101): always gated, and always opened — a plan the user has to
				# go looking for is a plan they will approve unread. The chat keeps the
				# one-line trace and the decision; the plan itself gets the center.
				chat_log "· presents a plan: [dict get $ev params title]\n" tool
				if {[dict get $ev params path] ne ""} {
					chat_log "  saved as [dict get $ev params path]\n" tool
				}
				plan_open [dict get $ev params title] [dict get $ev params plan] \
					[dict get $ev params path]
				set ::pending_turn $turn
				approve_bar 1 "Start work on this plan?" 0 0 1
				chat_busy_stop   ;# now waiting on the user, not the model (D82)
			} elseif {$kind eq "command"} {
				set argv [expr {[dict exists $ev params command] ? [dict get $ev params command] : {}}]
				set disp [dict get $ev params display]
				set auto [expr {[dict exists $ev params auto] ? [dict get $ev params auto] : 0}]
				if {$auto} {
					# Covered by an allow-list rule (D84): it runs without a bar. Show
					# what ran and keep the busy indicator — the turn is still working.
					chat_log "· runs run_command (allowed)\n" tool
					chat_command_preview $disp [dict get $ev params cwd]
				} else {
					chat_log "· proposes run_command\n" tool
					chat_command_preview $disp [dict get $ev params cwd]
					set ::pending_turn $turn
					set ::pending_cmd_argv $argv
					chat_allow_menu_populate $argv $disp
					approve_bar 1 "Run this command?" 0 1
					chat_busy_stop   ;# now waiting on the user, not the model (D82)
				}
			} else {
				# A *complex* edit (more than ::compare_threshold diff lines) opens in the
				# side-by-side compare view instead of dumping the whole diff inline —
				# unless the user turned that off (Settings ▸ Compare complex edits) (D28).
				set diff [dict get $ev params diff]
				chat_log "· proposes [dict get $ev params name]: [dict get $ev params path]\n" tool
				set complex [expr {[llength [split $diff "\n"]] > $::compare_threshold}]
				if {$::agent_compare_complex && $complex && !$::agent_auto_accept \
						&& [compare_proposal $turn]} {
					chat_log "  (opened in compare view)\n" tool
				} else {
					chat_diff $diff
				}
				if {!$::agent_auto_accept} {
					set ::pending_turn $turn
					approve_bar 1
					chat_busy_stop   ;# now waiting on the user, not the model (D82)
				}
			}
		}
		agent.mode {
			# The core changed the mode itself — approving a plan turns plan mode off
			# (D101). Mirror it, or the control would go on claiming the agent is planning
			# while it edits.
			set ::agent_plan_mode [expr {[dict get $ev params mode] eq "plan"}]
			agent_mode_sync
		}
		agent.options {
			# A provider's options changed — here, in another window (D3/D30), or because
			# a refresh has just come back from the network. The event says only THAT they
			# changed, so re-read: the list we then render is the list as it is now.
			set err [expr {[dict exists $ev params error] ? [dict get $ev params error] : ""}]
			if {$err ne ""} { report_error $err }
			# Re-read from the IDLE loop, not from here: this handler runs inside the
			# channel reader, and an op call from there would nest one vwait inside
			# another. The repaint is not urgent — nothing is waiting on it.
			if {[dict get $ev params provider] eq $::agent_provider} {
				after idle agent_options_refresh
			}
		}
		agent.tool_result {
			# The outcome of a read or an applied/rejected edit (red if it failed).
			approve_bar 0
			set tag [expr {[dict get $ev params ok] ? "tool" : "tool-error"}]
			chat_log "  → [dict get $ev params summary]\n" $tag
		}
	}
}

# Render a proposed command for review (D83): the shell-style command line (no tag,
# so it reads in the plain foreground — the human must read it before approving) and,
# when it isn't the project root, the directory it runs in. Display only: the core
# runs the argument vector directly, never through a shell.
proc chat_command_preview {display cwd} {
	chat_log "  \$ $display\n"
	if {$cwd ne ""} { chat_log "  in $cwd/\n" tool }
}

# Render a proposed edit's diff: -removed in red, +added in green.
proc chat_diff {diff} {
	foreach line [split $diff "\n"] {
		set tag tool
		if {[string match "+*" $line]} { set tag diff-add } elseif {[string match {-*} $line]} { set tag diff-del }
		chat_log "  $line\n" $tag
	}
}

# Show/hide the Approve/Reject bar for a pending proposal. `prompt` is the bar's
# question (an edit vs. a command vs. a plan each ask differently); `compare` shows the
# edit-only Compare button (a command has no diff to compare, D83); `always` shows the
# command-only "Always allow" menubutton (standing approval, D84 — an edit has no
# allow-list); `plan` shows the plan-only Plan button, which reopens a plan the user
# closed while thinking about it (D101). The extra buttons default off, so an edit shows
# just Approve/Reject.
proc approve_bar {show {prompt "Apply this edit?"} {compare 1} {always 0} {plan 0}} {
	if {!$show} {
		catch {pack forget .chat.approve}
		set ::pending_turn ""
		return
	}
	.chat.approve.lbl configure -text $prompt
	foreach w {yes appr edit no cmp always plan} { catch {pack forget .chat.approve.$w} }
	if {$plan} {
		# Approve ▾ | Edit plan | Reject | Plan, right to left (D102). A plan with no
		# project behind it was filed nowhere, so there is no file to edit.
		pack .chat.approve.appr -side right
		if {$::plan_path ne ""} { pack .chat.approve.edit -side right }
		pack .chat.approve.no   -side right
		pack .chat.approve.plan -side right
	} else {
		pack .chat.approve.yes -side right
		pack .chat.approve.no  -side right
		if {$always}  { pack .chat.approve.always -side right }
		if {$compare} { pack .chat.approve.cmp    -side right }
	}
	pack .chat.approve -side bottom -fill x -before .chat.input
}

# Rebuild the "Always allow" menu for the currently proposed command (D84). Two
# granularities as cascades — the program (argv[0], the recommended default: trust every
# invocation) first, the exact command line (trust only this identical argv) second —
# and each opens a submenu picking the SCOPE the rule is saved in: all projects (global),
# this project, or the active provider only. A long exact command is truncated in the
# label only. Each leaf remembers the rule (agent.allow.add) and approves the command in
# front of the user (agent_allow_always).
proc chat_allow_menu_populate {argv display} {
	set m .chat.approve.always.m
	$m delete 0 end
	# Which scopes are available right now.
	set pr [rio_result project.get {}]
	set haveproj [expr {$pr ne "" && [dict get $pr root] ne ""}]
	set prov [expr {[info exists ::agent_provider] ? $::agent_provider : ""}]
	set provok [expr {$prov ne "" && $prov ne "echo"}]
	set provlabel [expr {$provok ? [agent_provider_label $prov] : ""}]
	set prog [lindex $argv 0]
	set exact $display
	if {[string length $exact] > 40} { set exact "[string range $exact 0 39]…" }
	# (submenu suffix, cascade label, the rule)
	foreach {suf label rule} [list \
			prog  "Always allow: $prog"                        [list $prog] \
			exact "Always allow this exact command: $exact"    $argv] {
		set sm $m.$suf
		destroy $sm
		menu $sm -tearoff 0 -font RioUIFont
		$sm add command -label "For all projects" \
			-command [list agent_allow_always $rule global ""]
		$sm add command -label "For this project only" \
			-command [list agent_allow_always $rule project ""] \
			-state [expr {$haveproj ? "normal" : "disabled"}]
		if {$provok} {
			$sm add command -label "While $provlabel is the provider" \
				-command [list agent_allow_always $rule provider $prov]
		}
		$m add cascade -label $label -menu $sm
	}
}

# Persist a trust rule in a scope, then approve the command now in front of the user
# (D84). "Always allow" = remember + run this one. Add first (so a failed write still
# leaves the command awaiting the plain decision), then decide.
proc agent_allow_always {rule scope name} {
	if {$::pending_turn eq ""} return
	catch {rio_call agent.allow.add [dict create rule $rule scope $scope name $name]}
	agent_decide approve
}

# The user's decision on the pending edit → agent.approve resumes the turn, whose
# remaining events stream back as broadcast agent.* events (dispatch_event → chat).
# Approve a plan, saying how the work it starts should go (D102). The policy is decided
# HERE, on the plan, rather than inherited from a flag set before the user knew what would
# be proposed — which is what let auto-accept sit armed behind "plan mode". Set the flag
# first, so a failed write leaves the plan still awaiting a decision instead of starting
# work under a policy the core never accepted.
proc agent_decide_plan {policy} {
	if {$::pending_turn eq ""} return
	set on [expr {$policy eq "auto"}]
	set r [rio_call agent.autoaccept.set [dict create on $on]]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		return
	}
	set ::agent_auto_accept $on
	agent_mode_sync
	agent_decide approve
}

proc agent_decide {decision} {
	if {$::pending_turn eq ""} return
	set t $::pending_turn
	approve_bar 0
	compare_close
	plan_close
	catch {rio_call agent.approve [dict create turn $t decision $decision]}
	chat_busy_start   ;# the turn resumes; the next message/error stops it (D82)
}

# Clear the conversation: reset the core's state (agent.reset) and the transcript.
proc chat_clear {} {
	rio_call agent.reset {}
	chat_busy_stop   ;# abort any working animation (D82)
	# agent.reset aborts any turn suspended at the approval gate, so the review UI is now
	# asking about a decision nothing is waiting for — take it down with the conversation
	# it belonged to. Most visible with a plan (D101), which holds the whole center.
	approve_bar 0 ; compare_close ; plan_close
	.chat.log configure -state normal
	.chat.log delete 1.0 end
	.chat.log configure -state disabled
	set ::chat_turn_open 0
}

# Show/hide the chat pane by tab presence (kept for callers that flip the ::chat_shown
# mirror directly, e.g. tests). Give chat a tab (foreground) or take it away, re-derive,
# then apply_layout syncs the mirror back so the two never drift.
proc apply_chat_visibility {} {
	set s [rio::layout::site_of chat]
	if {$::chat_shown} { rio::layout::unhide $s chat ; rio::layout::put $s active chat } else { rio::layout::hide $s chat }
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	if {$::chat_shown} { focus .chat.input }
}

# Drag the csash to resize the RIGHT site (always on the right edge; D35 c1b). Its
# width is the toplevel's right edge minus the pointer — measured against the
# toplevel's STABLE edge like sash_drag. Clamped so neither side collapses.
proc csash_drag {} {
	set total [winfo width .]
	set min 200
	set max [expr {$total - 250}]
	set w [expr {[winfo rootx .] + $total - [winfo pointerx .]}]
	if {$w < $min} { set w $min }
	if {$max > $min && $w > $max} { set w $max }
	.siteright configure -width $w
}

# Drag the bsash to resize the BOTTOM site's height (D35). Its bottom edge is fixed
# just above the status bar, so the height is the window's bottom minus the status
# bar minus the pointer — measured against the toplevel's STABLE edge like sash_drag.
proc bsash_drag {} {
	set total [winfo height .]
	set min 60
	set max [expr {$total - 150}]
	set h [expr {[winfo rooty .] + $total - [winfo height .status] - [winfo pointery .]}]
	if {$h < $min} { set h $min }
	if {$max > $min && $h > $max} { set h $max }
	.sitebottom configure -height $h
}

# Drag the composer sash to resize the input box. Its height is in text lines, so we
# anchor on the press (start height + pointer y) and convert the vertical drag to a
# line delta via the font's line height — dragging up grows the input, down shrinks
# it. Clamped so it can't vanish or eat the whole transcript.
proc isash_press {y} {
	set ::isash_y0 $y
	set ::isash_h0 [.chat.input cget -height]
}
proc isash_drag {y} {
	set lh [font metrics [.chat.input cget -font] -linespace]
	if {$lh < 1} { set lh 1 }
	set h [expr {$::isash_h0 + int(double($::isash_y0 - $y) / $lh + 0.5)}]
	if {$h < 1} { set h 1 }
	set max [chat_input_max]
	if {$h > $max} { set h $max }
	.chat.input configure -height $h
}
# The most lines the input may take while leaving the sash and a few transcript
# lines on screen — otherwise a maxed input squeezes the divider out of reach.
proc chat_input_max {} {
	set lh [font metrics [.chat.input cget -font] -linespace]
	if {$lh < 1} { set lh 1 }
	set avail [expr {[winfo height .chat] - [winfo height .chat.hdr] \
		- [winfo height .chat.status] - [winfo height .chat.send] \
		- [winfo reqheight .chat.isash] - 3 * $lh}]
	set m [expr {$avail / $lh}]
	if {$m < 1} { set m 1 }
	return $m
}
# Re-clamp on layout changes (chat shown, window resized) so the input never hides
# the sash — and a previously over-tall input shrinks back into reach on its own.
proc clamp_input_height {} {
	set m [chat_input_max]
	if {[.chat.input cget -height] > $m} { .chat.input configure -height $m }
}

# ---------------------------------------------------------------------------
# The compare / diff view (AGENTS.md D28; D13/D14 anticipated it). Two read-only
# panes side by side with line-level diff coloring, shown in the center INSTEAD
# of the editor while comparing (apply_layout swaps .ed <-> .cmp). A dumb view
# (D3): the line alignment comes from the core diff.lines op; this only renders
# it. Filler rows keep equal lines level across the panes (VSCode-style). The
# right/proposed side is read-only for now — an editable temp buffer and a real
# tabbed second editor group are later enrichments.
# ---------------------------------------------------------------------------
# Compare text `ltext` (left) against `rtext` (right), labelled and shown.
proc compare_open {ltext rtext llabel rlabel} {
	.cmp.l.hdr configure -text $llabel
	.cmp.r.hdr configure -text $rlabel
	set resp [rio_call diff.lines [dict create a $ltext b $rtext]]
	set ops [expr {[dict get $resp ok] ? [dict get $resp result ops] : {}}]
	cmp_fill $ops [split $ltext "\n"] [split $rtext "\n"]
	cmp_apply_wrap
	set ::compare_shown 1
	apply_layout
	.cmp.l.t yview moveto 0
	.cmp.r.t yview moveto 0
}

# Fill both panes in one pass over the diff ops so equal lines stay aligned: an
# equal op emits a real line on each side; a delete emits the left line (tagged
# del) opposite a blank filler row; an insert a filler opposite the right line
# (tagged add). Adjacent delete+insert runs read as a change (red beside green).
proc cmp_fill {ops La Lb} {
	foreach t {.cmp.l.t .cmp.r.t} { $t configure -state normal ; $t delete 1.0 end }
	foreach o $ops {
		set a [dict get $o a] ; set b [dict get $o b]
		switch -- [dict get $o tag] {
			equal  { cmp_put .cmp.l.t "  " [lindex $La [expr {$a-1}]] "" ; cmp_put .cmp.r.t "  " [lindex $Lb [expr {$b-1}]] "" }
			delete { cmp_put .cmp.l.t "- " [lindex $La [expr {$a-1}]] del ; cmp_put .cmp.r.t "  " "" filler }
			insert { cmp_put .cmp.l.t "  " "" filler ; cmp_put .cmp.r.t "+ " [lindex $Lb [expr {$b-1}]] add }
		}
	}
	foreach t {.cmp.l.t .cmp.r.t} { $t configure -state disabled }
}
proc cmp_put {t marker text tag} {
	if {$tag eq ""} { $t insert end "$marker$text\n" } else { $t insert end "$marker$text\n" $tag }
}

# Scroll both panes together: the shared scrollbar drives both (cmp_yview); each
# pane's own scroll keeps the bar and the OTHER pane in step (cmp_yscroll, guarded
# against the feedback loop). Equal row counts (fillers) make the lockstep exact.
proc cmp_yview {args} {
	.cmp.l.t yview {*}$args
	.cmp.r.t yview {*}$args
}
proc cmp_yscroll {which lo hi} {
	.cmp.sb set $lo $hi
	if {$::cmp_syncing} return
	set ::cmp_syncing 1
	[expr {$which eq "l" ? {.cmp.r.t} : {.cmp.l.t}}] yview moveto $lo
	set ::cmp_syncing 0
}

# Leave the compare view, restoring the editor as the center.
proc compare_close {} {
	if {!$::compare_shown} return
	set ::compare_shown 0
	apply_layout
	focus [gget $::focus path]
}

# Open the side-by-side review for a pending agent proposal (D28): pull both full
# versions (agent.proposal) and show original | proposed. Returns 1 on success, 0
# if there is nothing to pull (the caller then falls back to the inline diff).
proc compare_proposal {turn} {
	if {$turn eq ""} { return 0 }
	set resp [rio_call agent.proposal [dict create turn $turn]]
	if {![dict get $resp ok]} { return 0 }
	set r [dict get $resp result]
	set path [dict get $r path]
	compare_open [dict get $r original] [dict get $r proposed] \
		"$path (original)" "$path (proposed)"
	return 1
}

# Compare the active buffer against a file the user picks (Compare menu). The other
# side is read-only via fs.read (D28) (an absolute path is taken as-is, D11), so it
# need not be open or even inside the project.
proc compare_with_file_dialog {} {
	if {$::core_remote} {
		set path [remote_browse_dialog "Compare with file (remote)" open]
	} else {
		set path [tk_getOpenFile -title "Compare active buffer with file"]
	}
	if {$path eq ""} return
	set resp [rio_call fs.read [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	compare_open [buf_text $::cur] [dict get $resp result text] \
		"[tab_name $::cur] (buffer)" "[file tail $path] (file)"
}

# ---------------------------------------------------------------------------
# The plan view (AGENTS.md D101). In plan mode the agent may not change anything; what
# it may do is say what it WOULD do, through the core's `present_plan` tool. The plan
# arrives as an `agent.propose` of kind `plan` carrying Markdown, and lands here — in the
# center, instead of the editor, exactly as a complex proposed edit lands in the compare
# view (D28). The two views are the same idea: a proposal too big to read in the chat
# column gets the width of the document area, while the decision stays on the chat's
# Approve/Reject bar where every other agent decision is made.
#
# It renders with the manual's renderer (help_blocks → help_paint, D100), so a plan reads
# like a page of the manual rather than like a text dump. Links inside a plan are STYLED
# BUT INERT: the renderer's click binding follows a manual topic, which is not what a path
# in a plan means — a wrong door is worse than no door.
# ---------------------------------------------------------------------------
set ::plan_shown 0   ;# plan view active? (.plan shown instead of .ed)
set ::plan_title ""
set ::plan_path  ""  ;# where the core filed this plan, project-relative ("" = nowhere)

# Show a plan, replacing the editor as the center. Mutually exclusive with the compare
# view — there is one center, and whichever proposal arrived last is the one being read.
proc plan_open {title md path} {
	set ::plan_title $title
	set ::plan_path  $path
	plan_paint $md
	plan_show
}

# Render one Markdown document into the plan pane, from the top. Read-only: the pane is a
# view of the plan, and the place to CHANGE a plan is its file (plan_edit).
proc plan_paint {md} {
	.plan.hdr configure -text [plan_header]
	set t .plan.text
	$t configure -state normal
	$t delete 1.0 end
	help_paint $t [help_blocks $md]
	$t configure -state disabled
	$t yview moveto 0
	plan_restyle
}

# Put the plan back in the center after the user closed it. Repainted from the plan as it
# stands NOW, because the user may have opened and changed it in between (D102) — a view
# that still showed the model's draft would be showing a plan nobody is about to approve.
# Mutually exclusive with the compare view: there is one center, one thing being reviewed.
proc plan_reopen {} {
	if {$::plan_title eq ""} return
	set md [plan_current_text]
	if {$md ne ""} { plan_paint $md }
	plan_show
}

# Give the plan the center. Mutually exclusive with the compare view: there is one center,
# and whichever proposal arrived last is the one being read.
proc plan_show {} {
	set ::compare_shown 0
	set ::plan_shown 1
	apply_layout
}

# The plan's absolute path, or "" when it was filed nowhere (no project) or the core has
# no project to resolve it against.
proc plan_abs {} {
	if {$::plan_path eq ""} { return "" }
	set pr [rio_result project.get {}]
	if {$pr eq "" || [dict get $pr root] eq ""} { return "" }
	return [file join [dict get $pr root] $::plan_path]
}

# The filed plan as it stands: the open buffer's text when the user has it open (so an
# unsaved edit shows, matching what the core will read at approval), else the disk copy,
# else "" — the caller then keeps what is already painted.
proc plan_current_text {} {
	set abs [plan_abs]
	if {$abs eq ""} { return "" }
	foreach id [dict keys $::buffers] {
		if {[bufget $id path] eq $abs} { return [buf_text $id] }
	}
	set r [rio_result fs.read [dict create path $::plan_path]]
	if {$r eq ""} { return "" }
	return [dict get $r text]
}

# Open the filed plan as an ordinary buffer so the user can change it before approving
# (D102). The plan view and the editor both want the center, so the view steps aside; the
# turn stays pending and the bar stays up, because approving is still the next thing.
proc plan_edit {} {
	set abs [plan_abs]
	if {$abs eq ""} return
	plan_close
	do_open $abs
}

# The header line: the plan's title, and where it was filed so the reader can go back to
# it after the window is closed (a plan with no project behind it names no file).
proc plan_header {} {
	set h "Plan — $::plan_title"
	if {$::plan_path ne ""} { append h "   ·   $::plan_path" }
	return $h
}

# Leave the plan view, restoring the editor as the center.
proc plan_close {} {
	if {!$::plan_shown} return
	set ::plan_shown 0
	apply_layout
	focus [gget $::focus path]
}

# Colour the plan view from the live theme: its own chrome, then the renderer's tags.
proc plan_restyle {} {
	if {![winfo exists .plan]} return
	set c $::theme_colors
	.plan configure -background [dict get $c ui.bg]
	.plan.bar configure -background [dict get $c ui.bg]
	.plan.bar.close configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.plan.hdr configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.plan.sb configure -background [dict get $c ui.bg]
	help_style .plan.text
}

# The open-buffer picker (D74). One modal dialog (pick_dialog, below) serves both
# "Compare With Another Tab…" and View ▸ "Switch to Tab…" — each is just "pick an open
# buffer from a list". It replaces the old unbounded .m.tabs cascade (a menu could grow
# screen-tall on X11; a dialog is bounded and scrolls), and unlike the cascade it can
# show a path hint so two same-named tabs are told apart.
#
# The row list is built by a separate proc so it stays headless-testable the way
# tabs_menu_fill was directly callable: walk every group's tab order (the same source),
# skipping `exclude` (the current buffer, for compare). Each row is {id label}; the
# label is the tab name + unsaved dot, plus the parent directory as a dim hint when the
# buffer has a path.
proc buffer_pick_rows {{exclude ""}} {
	set rows {}
	foreach g $::groups {
		foreach id [gorder $g] {
			if {$id eq $exclude} continue
			set label "[tab_name $id][tab_dot $id]"
			set p [bufget $id path]
			if {$p ne ""} { append label "    [file dirname $p]" }
			lappend rows [list $id $label]
		}
	}
	return $rows
}

# The bounded list picker — "pick one row from a list", the shape D74 introduced for
# buffers and D92 generalised. The dialog knows nothing about what a row *means*: each
# row is {payload label}, and the return is the chosen payload, or "" on cancel or an
# empty list. Modelled on remote_browse_dialog: themed toplevel, listbox + auto-hiding
# scrollbar, Double-click/Return choose, Escape/Cancel abort, grab + tkwait. It exists
# because a Tk menu has no size bound (an unbounded cascade can post taller than the
# screen and misbehave on X11, see CAVEATS.md) while a listbox scrolls inside a fixed
# frame — so every data-driven, unbounded list in rio comes here instead of to a menu.
#
# `initial` preselects the row carrying that payload (the theme in use, say) rather than
# row 0, so the dialog opens on the current value the way a Windows chooser does. The box
# is sized to its content within bounds — a 5-theme list isn't a 14-row well, and a long
# one still stops well short of the screen.
proc pick_dialog {title rows {initial ""}} {
	if {![llength $rows]} { bell ; return "" }   ;# nothing to pick — don't open an empty dialog

	set w .pick
	destroy $w
	toplevel $w
	wm title $w $title
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	set wide 0
	foreach r $rows { set wide [expr {max($wide, [string length [lindex $r 1]])}] }

	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.pick.body.list yview}
	listbox $w.body.list -activestyle none -exportselection 0 \
		-height [expr {max(6, min(16, [llength $rows]))}] \
		-width  [expr {max(28, min(72, $wide + 2))}] \
		-borderwidth 0 -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] \
		-selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .pick.body.sb .pick.body.list}
	pack $w.body.list -side left -fill both -expand 1

	set ::pick_payloads {}
	set at 0
	foreach r $rows {
		if {[lindex $r 0] eq $initial} { set at [llength $::pick_payloads] }
		lappend ::pick_payloads [lindex $r 0]
		$w.body.list insert end [lindex $r 1]
	}
	$w.body.list selection set $at
	$w.body.list activate $at
	$w.body.list see $at

	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.ok     -text OK     -font RioUIFont -command pick_choose
	button $w.btns.cancel -text Cancel -font RioUIFont \
		-command {set ::pick_result "" ; destroy .pick}
	pack $w.btns.cancel $w.btns.ok -side right -padx 3

	grid $w.body -row 0 -column 0 -sticky nsew -padx 8 -pady {8 4}
	grid $w.btns -row 1 -column 0 -sticky e    -padx 5 -pady {2 8}
	grid rowconfigure $w 0 -weight 1
	grid columnconfigure $w 0 -weight 1

	bind $w.body.list <Double-Button-1> pick_choose
	bind $w.body.list <Return>          pick_choose
	bind $w <Escape> {set ::pick_result "" ; destroy .pick}

	set ::pick_result ""
	catch {grab $w}
	focus $w.body.list
	tkwait window $w
	return $::pick_result
}
# Resolve the listbox selection to its row payload and close the dialog.
proc pick_choose {} {
	set sel [.pick.body.list curselection]
	if {$sel eq ""} return
	set ::pick_result [lindex $::pick_payloads $sel]
	destroy .pick
}

# Show the buffer picker modally and return the chosen buffer id (or "" on cancel).
proc buffer_pick_dialog {title {exclude ""}} {
	return [pick_dialog $title [buffer_pick_rows $exclude]]
}

# Compare the active buffer against another open buffer `id` — both sides are live
# buffer text (buffer.text), so unsaved edits on either tab are what you see (D74).
# Split from the picker so the compare itself is testable without opening the dialog.
proc compare_with_tab {id} {
	compare_open [buf_text $::cur] [buf_text $id] \
		"[tab_name $::cur] (current)" "[tab_name $id]"
}
proc compare_with_tab_dialog {} {
	set id [buffer_pick_dialog "Compare with another tab" $::cur]
	if {$id ne ""} { compare_with_tab $id }
}

# View ▸ Switch to Tab… (D74): the bounded replacement for the old top-level Tabs menu —
# pick any open buffer and activate it (activate focuses the group that holds it).
proc switch_tab_dialog {} {
	set id [buffer_pick_dialog "Switch to tab"]
	if {$id ne ""} { activate $id }
}

# rio's own build identity for Help ▸ About rio (D76). This is NOT rio's version — that
# is $rio::version (D123), the row above it. The two answer different questions and both
# are worth showing: Version says which RELEASE LINE this is, Build says which exact
# COMMIT, and between releases Build is the precise one.
# `git describe --tags --always` gives the *tag* once one exists and the abbreviated commit
# otherwise, so at a release Build sharpens itself for free. Run against rio's OWN source dir
# ([file dirname $::rio_self], the normalized script path) — not the user's project, and not
# the core, which may be a different build on another machine. An installed copy with no git
# metadata (or no git) falls back to "unknown". Computed once and cached; About is rare, so
# there's no reason to shell out at startup.
proc rio_build_id {} {
	if {![info exists ::rio_build]} {
		if {[catch {exec git -C [file dirname $::rio_self] describe --tags --always} id]} {
			set ::rio_build "unknown"
		} else {
			set ::rio_build [string trim $id]
		}
	}
	return $::rio_build
}

# The date/time of that build's commit (committer date, local zone), so About can say not
# just which rio but when it was cut. Same source dir and same "unknown" fallback + caching
# as rio_build_id. --date=format gives a compact "YYYY-MM-DD HH:MM"; %cd honours it.
proc rio_build_date {} {
	if {![info exists ::rio_build_date]} {
		if {[catch {exec git -C [file dirname $::rio_self] show -s --format=%cd \
			{--date=format:%Y-%m-%d %H:%M} HEAD} d]} {
			set ::rio_build_date "unknown"
		} else {
			set ::rio_build_date [string trim $d]
		}
	}
	return $::rio_build_date
}

# What About's Version row says (D123). Normally just this checkout's release version —
# a spawned core is the same tree, so naming it twice would be noise. But a core reached
# over --connect (D29/D30) can be any build, and when it reports a DIFFERENT version that
# is precisely the fact a bug report needs, so the row carries it: "0.1.0 (core 0.1.1)".
# A core too old to report one leaves ::core_version empty and says nothing, which is the
# D19 fallback rather than a claim that the versions match.
proc about_version {} {
	if {$::core_version ne "" && $::core_version ne $rio::version} {
		return "$rio::version (core $::core_version)"
	}
	return $rio::version
}

# Help ▸ About rio (D76): a small themed modal with rio's name, one-line description, and the
# release version (D123), the build id, its commit date, the wire-protocol version (all handy
# in a bug report — see ::rio_protocol) and the licence (D121) — the one fact here that is
# about the copy in front of you rather than this build, and the reason it is legible without
# going back to the repository.
# The licence name is written here rather than read from LICENSE: the file need not sit beside a
# deployed GUI, and smoke.tcl holds this string to it. Info is
# static labels (muted), the lone control is Close; Esc/Return dismiss. Non-blocking (grab but
# no tkwait) — it just informs, it returns nothing.
#
# Version comes FIRST: it is the coarsest and most quotable fact, and the one a bug report
# leads with. It names the core too, but only when the core's differs (about_version) —
# a second permanent row would repeat the same number on every local run, since a spawned
# core is always this very tree.
proc about_dialog {} {
	set w .about
	destroy $w
	toplevel $w
	wm title $w "About rio"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set fam [font actual RioUIFont -family]
	# No dedicated "muted" UI role in the theme vocabulary — blend the fg halfway toward the
	# bg for a dim label tone that reads on any theme (the restyle_group currentline pattern).
	set mute [blend_hex [dict get $c ui.fg] [dict get $c ui.bg] 45]

	label $w.name -text "rio" -font [list $fam 20 bold] \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	label $w.tag -font RioUIFont -justify left -wraplength 340 \
		-text "A small, cross-platform IDE, written from scratch in Tcl/Tk." \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	# The static facts, as a dim two-column block so they read as info, not controls.
	frame $w.facts -background [dict get $c ui.bg]
	set r 0
	foreach {k v} [list Version [about_version] Build [rio_build_id] \
		Date [rio_build_date] Protocol $::rio_protocol License "MIT"] {
		label $w.facts.k$r -text $k -font RioUIFont -anchor e \
			-background [dict get $c ui.bg] -foreground $mute
		label $w.facts.v$r -text $v -font RioUIFont -anchor w \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		grid $w.facts.k$r -row $r -column 0 -sticky e -padx {0 8}
		grid $w.facts.v$r -row $r -column 1 -sticky w
		incr r
	}
	button $w.ok -text "Close" -font RioUIFont -command {destroy .about}

	# rio's own icon, to the left of the name — the Win2000/VSCode About-box shape. It
	# reuses an image apply_window_icon (D117) already loaded for `wm iconphoto`, so
	# nothing is read from disk here and the box always shows the icon rio is actually
	# wearing. The PNG's transparency composites over the label's themed background.
	#
	# Column 0 is the icon's, column 1 the text's, ALWAYS — so when there is no icon to
	# show (the D117 soft case: a checkout with icons/ removed) column 0 simply has no
	# width and the box keeps its old single-column look, with no second layout to hold
	# in step.
	set icon ""
	foreach n {64 48 32} {
		if {[llength [info commands ::rio_icon_$n]]} { set icon ::rio_icon_$n ; break }
	}
	if {$icon ne ""} {
		label $w.icon -image $icon -background [dict get $c ui.bg] -borderwidth 0
		grid $w.icon -row 0 -column 0 -rowspan 3 -sticky n -padx {16 0} -pady {16 0}
	}

	grid $w.name  -row 0 -column 1 -sticky w  -padx 16 -pady {14 0}
	grid $w.tag   -row 1 -column 1 -sticky w  -padx 16 -pady {4 8}
	grid $w.facts -row 2 -column 1 -sticky w  -padx 16
	grid $w.ok    -row 3 -column 1 -sticky e  -padx 16 -pady {10 12}
	grid columnconfigure $w 1 -weight 1

	bind $w <Escape> {destroy .about}
	bind $w <Return> {destroy .about}
	catch {grab $w}
	focus $w.ok
}

# ---------------------------------------------------------------------------
# The help viewer — Help ▸ Contents…, F1 (AGENTS.md D99, D100). rio showing its own manual.
#
# The manual is `docs/`, one Markdown topic per file, and the filename IS the topic id
# (D91) — which is why this needs no index of its own: index.md is the contents, and the
# files are the topics. The window is the WinHelp shape: the contents on the left, the
# selected topic on the right. D99 put the Markdown SOURCE in that right pane; D100
# renders it — headings, tables, code, and links a reader can follow, with Back/Forward
# behind them, which is what makes the manual's own cross-references work as doors
# rather than as text describing a door. The Find box searches it (D100).
#
# The GUI reads these files ITSELF, off its own tree, rather than through `file.open`.
# Help is the GUI's own chrome, not project content: over a remote core (D29) the project
# lives on another machine, so asking the core for a manual page would open the SERVER's
# copy — a different rio's documentation — or nothing at all. The same reasoning that puts
# syntax/ and themes/ beside the code puts docs/ there — and since rio is deployed by
# cloning it, docs/ is already wherever the code is, with nothing to install separately.
# ---------------------------------------------------------------------------

# Where the shipped manual lives: beside the code, like syntax/ (hl_load) and themes/.
proc help_dir {} { return [file normalize [file join $::rio_dir .. docs]] }

# Read one manual file as UTF-8 whatever the system encoding is — these pages are full of
# the arrows and dashes a cp1252 read would mangle, and the manual is UTF-8 by rule (D21).
proc help_slurp {path} {
	set f [open $path r] ; fconfigure $f -encoding utf-8
	set t [read $f] ; close $f
	return $t
}

# The contents, read from index.md as {section title file} in document order. index.md's
# shape is the contract — `### Section` headings and `- [Title](topic.md)` entries under
# `## Contents` — the same shape docs.tcl already holds the page to, so the viewer and the
# guard agree on what a contents entry is. Links that leave docs/ (`../README.md`) are not
# topics: this window shows the manual, and the manual says where else to look.
proc help_contents {} {
	set idx [file join [help_dir] index.md]
	if {![file exists $idx]} { return {} }
	set out {} ; set inside 0 ; set section ""
	foreach line [split [help_slurp $idx] \n] {
		if {[regexp {^##\s+(.+?)\s*$} $line -> h]} {
			set inside [string equal $h "Contents"] ; continue
		}
		if {!$inside} continue
		if {[regexp {^###\s+(.+?)\s*$} $line -> s]} { set section $s ; continue }
		if {[regexp {^\s*-\s+\[([^\]]+)\]\(([^)#]+)\)} $line -> title target]} {
			if {[string match */* $target]} continue
			lappend out [list $section $title $target]
		}
	}
	return $out
}

set ::help_topic ""   ;# the topic the viewer is showing, "" while it is closed

# Open the viewer (or raise it) and show TOPIC, a docs/ filename. Non-modal and
# single-instance, the Extensions window's idiom (D39) — which is also what makes a later
# move into a dock site a re-host rather than a rewrite, if that is where help ends up.
proc help_window {{topic ""}} {
	set w .help
	if {[winfo exists $w]} {
		raise $w ; focus $w.nav.list
		if {$topic ne ""} { help_show $topic }
		return
	}
	toplevel $w
	wm title $w "rio Help"

	# Find: the Extensions window's header idiom — a filter entry that repaints the list
	# below it as you type (D39). The contents list answers "what is in the manual"; this
	# answers "where is the word", which is the other way a reader arrives at a page.
	frame $w.find
	label $w.find.l -text "Find:" -font RioUIFont
	entry $w.find.e -font RioUIFont -width 18
	ctx_bind_input $w.find.e   ;# (D115)
	pack $w.find.l -side left -padx {0 4}
	pack $w.find.e -side left
	bind $w.find.e <KeyRelease> help_find_changed
	# Escape clears the search rather than closing the window — but only while there IS
	# one, so a second Escape still leaves, which is what the key means everywhere else.
	bind $w.find.e <Escape> {
		if {[.help.find.e get] ne ""} { .help.find.e delete 0 end ; help_find_changed ; break }
	}

	# Contents: a rich list (D42) like the file and git panes, so it selects, hovers and
	# arrows exactly as the rest of rio's lists do. Section headings are rows too — not
	# selectable — because rl_* indexes rows by line, so every line must be one.
	frame $w.nav -borderwidth 2 -relief sunken
	text $w.nav.list -width 24 -height 26 -wrap none -state disabled -cursor arrow \
		-insertwidth 0 -takefocus 1 -borderwidth 0 -highlightthickness 0 -padx 2 -pady 2
	pack $w.nav.list -side left -fill both -expand 1
	rl_init $w.nav.list help_pick {} {}

	# The topic, rendered (D100). The pages are hand-wrapped for a text editor, but this
	# window reflows them to whatever width it has — so it wraps by word, and the two block
	# kinds that must NOT reflow (code and tables) opt out per tag. Those are also the only
	# reason there is a horizontal bar at all, which is why it auto-hides.
	frame $w.page -borderwidth 2 -relief sunken
	scrollbar $w.page.sb  -command {.help.page.text yview}
	scrollbar $w.page.hsb -orient horizontal -command {.help.page.text xview}
	text $w.page.text -width 80 -height 26 -wrap word -state disabled -cursor arrow \
		-insertwidth 0 -borderwidth 0 -highlightthickness 0 -padx 8 -pady 4 \
		-yscrollcommand {gridscroll .help.page.sb} \
		-xscrollcommand {gridscroll .help.page.hsb}
	ctx_bind_view $w.page.text   ;# Copy / Select All (D115)
	grid $w.page.text -row 0 -column 0 -sticky nsew
	grid $w.page.sb   -row 0 -column 1 -sticky ns
	grid $w.page.hsb  -row 1 -column 0 -sticky we
	grid rowconfigure    $w.page 0 -weight 1
	grid columnconfigure $w.page 0 -weight 1
	help_link_binds $w.page.text

	# Back/Forward: following a link is the one way to end up somewhere the contents list
	# cannot bring you back from (an anchor inside a topic, or a document outside the
	# manual), so the doors D100 opens come with the way back.
	frame $w.foot
	button $w.foot.back -text "◀" -font RioUIFont -command {help_history back}
	button $w.foot.fwd  -text "▶" -font RioUIFont -command {help_history forward}
	label $w.foot.where -anchor w -font RioUIFont   ;# the file being shown, so a reader
	button $w.foot.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.foot.back  -side left -padx {0 2}
	pack $w.foot.fwd   -side left -padx {0 8}
	pack $w.foot.close -side right                  ;# can go find it on disk
	pack $w.foot.where -side left -fill x -expand 1

	grid $w.find -row 0 -column 0 -columnspan 2 -sticky we   -padx 8 -pady {8 0}
	grid $w.nav  -row 1 -column 0 -sticky nsew -padx {8 4} -pady {8 4}
	grid $w.page -row 1 -column 1 -sticky nsew -padx {0 8} -pady {8 4}
	grid $w.foot -row 2 -column 0 -columnspan 2 -sticky we -padx 8 -pady {0 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 1 -weight 1
	bind $w <Escape> [list destroy $w]
	bind $w <Alt-Left>  {help_history back}
	bind $w <Alt-Right> {help_history forward}
	bind $w <Control-f> {focus .help.find.e ; .help.find.e selection range 0 end}
	bind $w <Destroy> {if {"%W" eq ".help"} {set ::help_topic "" ; set ::help_needle ""}}

	set ::help_back {} ; set ::help_fwd {} ; set ::help_needle ""
	help_restyle
	help_fill_contents
	help_show [expr {$topic ne "" ? $topic : "index.md"}]
	focus $w.nav.list
}

# Paint the contents list. index.md leads it under its own title: it is a topic like any
# other (the manual's front page), and the viewer would otherwise be the one reader who
# can never see it.
proc help_fill_contents {} {
	set b .help.nav.list
	rl_begin $b
	$b insert end "The rio manual\n" ; rl_row $b 1 index.md
	set section ""
	foreach e [help_contents] {
		lassign $e s title file
		if {$s ne $section} {
			set section $s
			$b insert end "$s\n" helpsect ; rl_row $b 0 ""
		}
		$b insert end "  $title\n" ; rl_row $b 1 $file
	}
	rl_end $b
}

# Selecting a row shows what it points at. A contents row's payload is a filename; a search
# result's is {file slug} — lassign reads both, since a one-element payload leaves the anchor
# empty, which is exactly "show this topic from the top".
proc help_pick {payload} {
	lassign $payload file anchor
	if {$file ne ""} { help_show $file $anchor }
}

# ---------------------------------------------------------------------------
# Searching the manual. This runs HERE, in the GUI, over the same files the viewer reads —
# not through the core's project.search. The core may be on another machine (D29), where
# docs/ is a different rio's manual or absent entirely; the reasoning that makes the viewer
# read its own tree makes the search read it too.
#
# It is deliberately small. The manual is fourteen files and about 50 KB, so a search is a
# re-read of all of them — no index to build, and nothing that can go stale. Matching is
# line by line rather than over help_blocks, because a result needs the HEADING a match sits
# under, which the lines still know and the joined blocks no longer do.
# ---------------------------------------------------------------------------

set ::help_needle ""   ;# the live search, "" when the contents list is showing

# Every heading with a match, as {file title slug heading hits}, in document order.
proc help_search {needle} {
	set needle [string tolower [string trim $needle]]
	if {$needle eq ""} { return {} }
	set out {}
	# index.md is a topic like any other here, and leads, exactly as it does in the contents.
	foreach e [linsert [help_contents] 0 [list "" "The rio manual" index.md]] {
		lassign $e -> title file
		set path [help_path $file]
		if {$path eq "" || [catch {help_slurp $path} md]} continue
		set sect $title ; set slug "" ; set hits 0
		foreach line [split [string map {\r ""} $md] \n] {
			if {[regexp {^#{1,6}[ \t]+(.+?)[ \t]*$} $line -> h]} {
				if {$hits} { lappend out [list $file $title $slug $sect $hits] }
				set sect [help_plain $h] ; set slug [help_slug $h] ; set hits 0
			}
			# Matched against the STRIPPED line, so markup the reader never sees cannot hide a
			# word from them: searching "wrap lines" finds `**Wrap Lines**`.
			if {[string first $needle [string tolower [help_plain $line]]] >= 0} { incr hits }
		}
		if {$hits} { lappend out [list $file $title $slug $sect $hits] }
	}
	return $out
}

# The results, in the contents list's own two-level shape: the topic's title as a heading
# row, its matching sections under it. The pane is narrow, so a row names its section and
# its count rather than quoting the line — the highlight on the page does that job.
proc help_fill_results {needle} {
	set b .help.nav.list
	rl_begin $b
	set hits [help_search $needle]
	if {![llength $hits]} {
		# Never a blank pane: a search that found nothing says so.
		$b insert end "No matches\n" helpsect ; rl_row $b 0 ""
		rl_end $b
		return
	}
	set last ""
	foreach h $hits {
		lassign $h file title slug sect n
		if {$file ne $last} {
			set last $file
			$b insert end "$title\n" helpsect ; rl_row $b 0 ""
		}
		$b insert end "  $sect  ($n)\n" ; rl_row $b 1 [list $file $slug]
	}
	rl_end $b
}

# The entry changed: swap the list between contents and results, and re-show the current
# topic so its highlight follows the needle. Unchanged text is ignored, so arrowing around
# inside the entry does not repaint anything.
proc help_find_changed {} {
	if {![winfo exists .help]} return
	set needle [string trim [.help.find.e get]]
	if {$needle eq $::help_needle} return
	set ::help_needle $needle
	if {$needle eq ""} { help_fill_contents } else { help_fill_results $needle }
	if {$::help_topic ne ""} { help_show $::help_topic $::help_anchor_now 0 }
}

# Band every occurrence of the needle in the rendered page. Landing on the right heading is
# only half an answer — this is the half that says where in it.
proc help_mark_hits {t needle} {
	$t tag remove hit 1.0 end
	if {$needle eq ""} return
	set n 0 ; set i 1.0
	while {[set i [$t search -nocase -count n -- $needle $i end]] ne "" && $n > 0} {
		$t tag add hit $i "$i + $n chars"
		set i "$i + $n chars"
	}
}

# ---------------------------------------------------------------------------
# The renderer (D100). Markdown in, a painted text widget out, in two halves that are
# deliberately separate: help_blocks turns a page into a list of block descriptors with no
# widget in sight (so it can be checked as a function, and so a later help search can walk
# the same structure), and help_paint puts those blocks on screen.
#
# It reads the slice index.md commits the manual to — headings, paragraphs, lists, links,
# bold/italic, inline code, fenced code, simple tables, blockquotes — and nothing else. A
# construct outside that slice is not an error here; it simply renders as the text it is,
# which is the honest failure for a viewer whose input is hand-written prose.
# ---------------------------------------------------------------------------

# A heading's anchor, GitHub's rule: lowercased, punctuation dropped, spaces hyphenated.
# The manual links to headings by that slug (`preferences.md#where-everything-lives`), so
# rio has to derive the same one the author typed — docs.tcl holds both ends to it.
proc help_slug {s} {
	set s [string tolower [help_plain $s]]
	regsub -all {[^a-z0-9 -]} $s "" s
	return [string map {" " -} [string trim $s]]
}

# Inline markup, as a list of {text style target} runs. style is "" | strong | em | strongem
# | code | link; target carries a link's destination. One alternation finds the next marker
# of any kind, so the scan is a handful of regexps per line rather than per character, and
# leftmost-longest picks *** over ** over * without needing the order spelled out.
proc help_inline {s} {
	set re {`[^`]+`|\*\*\*[^*]+\*\*\*|\*\*[^*]+\*\*|\*[^*]+\*|\[[^\]]*\]\([^)]*\)}
	set out {}
	while {[regexp -indices $re $s m]} {
		lassign $m a b
		if {$a > 0} { lappend out [list [string range $s 0 $a-1] "" ""] }
		set tok [string range $s $a $b]
		# Matched by leading marker, with string compares rather than a glob: every `*` in a
		# glob pattern is a wildcard, so "starts with ***" cannot be written as one.
		if {[string index $tok 0] eq "`"} {
			lappend out [list [string range $tok 1 end-1] code ""]
		} elseif {[string index $tok 0] eq "\["} {
			regexp {^\[([^\]]*)\]\(([^)]*)\)$} $tok -> title target
			lappend out [list $title link $target]
		} elseif {[string range $tok 0 2] eq "***"} {
			lappend out [list [string range $tok 3 end-3] strongem ""]
		} elseif {[string range $tok 0 1] eq "**"} {
			lappend out [list [string range $tok 2 end-2] strong ""]
		} else {
			lappend out [list [string range $tok 1 end-1] em ""]
		}
		set s [string range $s $b+1 end]
	}
	if {$s ne ""} { lappend out [list $s "" ""] }
	return $out
}

# The same text with its markup taken off — what a reader sees. Column widths and anchor
# slugs both need the visible length, not the source's.
proc help_plain {s} {
	set out ""
	foreach run [help_inline $s] { append out [lindex $run 0] }
	return $out
}

# Close whatever block is open. Tcl has no closures, so the accumulator travels by name.
proc help_flush {outv textv kindv depthv markerv} {
	upvar 1 $outv out $textv text $kindv kind $depthv depth $markerv marker
	if {$text ne ""} {
		switch $kind {
			item    { lappend out [list item $depth $marker $text] }
			quote   { lappend out [list quote $text] }
			default { lappend out [list para $text] }
		}
	}
	set text "" ; set kind "" ; set depth 0 ; set marker ""
}

# One page as a list of blocks: {heading LEVEL text} {para text} {quote text}
# {item DEPTH MARKER text} {code text} {table ROWS} {rule}. Prose blocks arrive as ONE
# string with their source line breaks joined out — the manual is hand-wrapped for an
# 80-column editor and this window has its own width, so it re-wraps rather than inheriting
# someone else's margin. Code and tables keep their lines, which is the whole point of them.
proc help_blocks {md} {
	set out {} ; set text "" ; set kind "" ; set depth 0 ; set marker ""
	set lines [split [string map {\r ""} $md] \n]
	set n [llength $lines]
	for {set i 0} {$i < $n} {incr i} {
		set ln [lindex $lines $i]
		set bare [string trimleft $ln]

		if {[string match "```*" $bare]} {          ;# fenced code, verbatim to the closing fence
			help_flush out text kind depth marker
			set code {}
			for {incr i} {$i < $n} {incr i} {
				if {[string match "```*" [string trimleft [lindex $lines $i]]]} break
				lappend code [lindex $lines $i]
			}
			lappend out [list code [join $code \n]]
			continue                                 ;# the loop's own incr steps past the fence
		}
		if {$bare eq ""} { help_flush out text kind depth marker ; continue }
		if {[regexp {^(#{1,6})\s+(.*?)\s*$} $ln -> hashes htext]} {
			help_flush out text kind depth marker
			lappend out [list heading [string length $hashes] $htext]
			continue
		}
		if {[regexp {^(-{3,}|\*{3,}|_{3,})$} $bare]} {
			help_flush out text kind depth marker
			lappend out [list rule]
			continue
		}
		if {[string index $bare 0] eq "|"} {         ;# a table runs until a line that isn't one
			help_flush out text kind depth marker
			set rows {}
			for {} {$i < $n} {incr i} {
				set r [string trim [lindex $lines $i]]
				if {[string index $r 0] ne "|"} break
				set cells {}
				foreach c [split [string trim $r "|"] "|"] { lappend cells [string trim $c] }
				if {![help_table_sep $cells]} { lappend rows $cells }
			}
			incr i -1
			lappend out [list table $rows]
			continue
		}
		if {[regexp {^>\s?(.*)$} $bare -> qtext]} {
			if {$kind ne "quote"} { help_flush out text kind depth marker ; set kind quote }
			append text [expr {$text eq "" ? "" : " "}] $qtext
			continue
		}
		if {[regexp {^(\s*)([-*+]|\d+[.)])\s+(.*)$} $ln -> ind mk itext]} {
			help_flush out text kind depth marker
			set kind item
			set depth [expr {[string length $ind] / 2}]
			set marker [expr {[string is digit [string index $mk 0]] ? $mk : "•"}]
			set text $itext
			continue
		}
		# Anything else continues the open block — which is how a hand-wrapped paragraph,
		# or the second line of a list item, rejoins the sentence it belongs to.
		if {$kind eq ""} { set kind para }
		append text [expr {$text eq "" ? "" : " "}] [string trim $ln]
	}
	help_flush out text kind depth marker
	return $out
}

# Is this row a table's `| --- | --- |` rule? It carries alignment in Markdown; rio renders
# every column left-aligned, so it carries nothing here and is dropped — wherever it sits,
# since a row of nothing but dashes has no content to lose either way. A cell holding a
# lone `-` as a value is safe: the row is only dropped if EVERY cell is dashes.
proc help_table_sep {cells} {
	foreach c $cells { if {![regexp {^:?-+:?$} $c]} { return 0 } }
	return [llength $cells]
}

# Paint one run of inline markup. `mono` picks the fixed-pitch variants, which a table needs
# so that a bold cell still measures the same as a plain one and the columns stay lined up.
proc help_spans {t s blocktags {mono 0}} {
	foreach run [help_inline $s] {
		lassign $run text style target
		set tags $blocktags
		switch $style {
			strong   { lappend tags [expr {$mono ? "mstrong" : "strong"}] }
			em       { lappend tags [expr {$mono ? "mem" : "em"}] }
			strongem { lappend tags [expr {$mono ? "mstrongem" : "strongem"}] }
			code     { lappend tags tt }
			link     { set tag L[incr ::help_link_n($t)]
			           set ::help_link($t,$tag) $target
			           lappend tags link $tag }
		}
		$t insert end $text $tags
	}
}

# Put a page on screen. Records where each heading landed (::help_anchor) so a `#slug` link
# can scroll to it, and what each link points at (::help_link) so a click can follow it.
# Both are keyed by WIDGET: the plan view (D101) paints with the same renderer, and painting
# a plan must not cost an open manual page its anchors.
proc help_paint {t blocks} {
	array unset ::help_anchor "$t,*"
	array unset ::help_link "$t,*"
	set ::help_link_n($t) 0
	foreach blk $blocks {
		set kind [lindex $blk 0]
		switch $kind {
			heading {
				lassign $blk -> level htext
				set ::help_anchor($t,[help_slug $htext]) [$t index "end-1c"]
				help_spans $t $htext [list h[expr {$level > 3 ? 3 : $level}]]
				$t insert end "\n"
			}
			para  { help_spans $t [lindex $blk 1] para  ; $t insert end "\n" }
			quote { help_spans $t [lindex $blk 1] quote ; $t insert end "\n" }
			item {
				lassign $blk -> depth marker itext
				if {$depth > 3} { set depth 3 }
				$t insert end "$marker " [list li$depth listmark]
				help_spans $t $itext li$depth
				$t insert end "\n" li$depth
			}
			code { $t insert end "[lindex $blk 1]\n" code }
			rule { $t insert end "[string repeat ─ 40]\n" rule }
			table { help_paint_table $t [lindex $blk 1] }
		}
	}
}

# A table, padded into columns. Widths come from the VISIBLE text (help_plain), not the
# source, or a cell of `code` would reserve room for its backticks.
proc help_paint_table {t rows} {
	set w {}
	foreach row $rows {
		for {set i 0} {$i < [llength $row]} {incr i} {
			set len [string length [help_plain [lindex $row $i]]]
			if {$i >= [llength $w]} { lappend w $len } \
			elseif {$len > [lindex $w $i]} { lset w $i $len }
		}
	}
	set first 1
	foreach row $rows {
		for {set i 0} {$i < [llength $row]} {incr i} {
			set cell [lindex $row $i]
			help_spans $t $cell [expr {$first ? {table mstrong} : {table}}] 1
			set pad [expr {[lindex $w $i] - [string length [help_plain $cell]]}]
			if {$i < [llength $row] - 1} {
				$t insert end "[string repeat { } $pad]  │ " table
			}
		}
		$t insert end "\n" table
		if {$first} {                        ;# a rule under the header, in the same pitch
			set segs {}
			foreach cw $w { lappend segs [string repeat ─ [expr {$cw + 2}]] }
			$t insert end "[join $segs ┼]\n" table
			set first 0
		}
	}
}

# --- following a link ------------------------------------------------------------------

proc help_link_binds {t} {
	$t tag bind link <Button-1> [list help_link_click $t %x %y]
	$t tag bind link <Enter> [list $t configure -cursor hand2]
	$t tag bind link <Leave> [list $t configure -cursor arrow]
}

# Which link was clicked: the L<n> tag under the pointer names it.
proc help_link_click {t x y} {
	foreach tag [$t tag names [$t index @$x,$y]] {
		if {[info exists ::help_link($t,$tag)]} { help_goto $::help_link($t,$tag) ; return }
	}
}

# Follow one link target: `topic.md`, `topic.md#heading`, or a bare `#heading` in this page.
proc help_goto {target} {
	set file $target ; set anchor ""
	regexp {^([^#]*)#(.*)$} $target -> file anchor
	if {$file eq ""} { set file $::help_topic }
	help_show $file $anchor
}

# Scroll a heading to the top of the page. A slug rio cannot place is left alone rather than
# guessed at — the reader is on the right page, just not moved.
proc help_anchor_see {slug} {
	set t .help.page.text
	if {![info exists ::help_anchor($t,$slug)]} { return 0 }
	$t yview $::help_anchor($t,$slug)
	return 1
}

# --- where the reader has been -----------------------------------------------------------

set ::help_back {} ; set ::help_fwd {} ; set ::help_anchor_now ""

proc help_history {dir} {
	if {![winfo exists .help]} return
	set from [list $::help_topic $::help_anchor_now]
	if {$dir eq "back"} {
		if {![llength $::help_back]} return
		set to [lindex $::help_back end]
		set ::help_back [lrange $::help_back 0 end-1]
		lappend ::help_fwd $from
	} else {
		if {![llength $::help_fwd]} return
		set to [lindex $::help_fwd end]
		set ::help_fwd [lrange $::help_fwd 0 end-1]
		lappend ::help_back $from
	}
	help_show [lindex $to 0] [lindex $to 1] 0
}

proc help_history_buttons {} {
	if {![winfo exists .help]} return
	.help.foot.back configure -state [expr {[llength $::help_back] ? "normal" : "disabled"}]
	.help.foot.fwd  configure -state [expr {[llength $::help_fwd]  ? "normal" : "disabled"}]
}

# --- showing a topic ---------------------------------------------------------------------

# Resolve a manual filename to a path on disk, refusing to leave the tree rio ships. The
# manual's links are relative by rule (D91); the ones that leave docs/ (`../README.md`)
# point at rio's OTHER documents, which are rio's own files too, so they are followed —
# but nothing outside the rio directory is, whatever a page asks for.
proc help_path {file} {
	if {$file eq "" || [file pathtype $file] ne "relative"} { return "" }
	set root [file dirname [help_dir]]
	set path [file normalize [file join [help_dir] $file]]
	if {$path ne $root && [string first "$root/" $path] != 0} { return "" }
	return $path
}

# How the footer names a file: its path relative to the rio directory, so a reader can go
# find it — `docs/git.md`, or `README.md` for the documents beside it.
proc help_label {file} {
	set path [help_path $file]
	if {$path eq ""} { return $file }
	set root [file dirname [help_dir]]/
	if {[string first $root $path] == 0} { return [string range $path [string length $root] end] }
	return $path
}

# Show one topic, optionally scrolled to one of its headings, and put the contents selection
# on it so the two halves never disagree — including when the topic was reached any way
# other than clicking its row. `push` is what separates a new destination from retracing
# one: Back and Forward re-show a page without recording the move as another move.
#
# A file that cannot be read is reported IN the window: a partial install should say what is
# missing, not break the one window that would explain it.
proc help_show {file {anchor ""} {push 1}} {
	set t .help.page.text
	if {$push && $::help_topic ne "" && [list $file $anchor] ne [list $::help_topic $::help_anchor_now]} {
		lappend ::help_back [list $::help_topic $::help_anchor_now]
		set ::help_fwd {}
	}
	set path [help_path $file]
	if {$path eq ""} {
		set text "## This is not a page of rio's manual\n\n`$file` is outside the rio\ndirectory, so the help viewer will not open it."
	} elseif {[catch {help_slurp $path} text]} {
		set text "## This topic could not be read\n\n`$path`\n\n$text"
	}
	$t configure -state normal
	$t delete 1.0 end
	help_paint $t [help_blocks $text]
	help_mark_hits $t $::help_needle
	$t configure -state disabled
	$t yview moveto 0
	.help.foot.where configure -text [help_label $file]
	set ::help_topic $file
	set ::help_anchor_now $anchor
	if {$anchor ne ""} { help_anchor_see $anchor }
	help_history_buttons
	# Which row is this page? A search result names a file AND a heading, so the exact pair
	# wins where it exists — otherwise the reader clicks one section and the list marks that
	# topic's first. A contents row is the file alone, which the loose match covers.
	set b .help.nav.list
	set row -1 ; set loose -1
	for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
		set p [rl_payload $b $i]
		if {$p eq [list $file $anchor]} { set row $i ; break }
		if {$loose < 0 && [lindex $p 0] eq $file} { set loose $i }
	}
	if {$row < 0} { set row $loose }
	# A document outside the contents (README.md, reached from index.md's own table) has no
	# row — so nothing is current, rather than the last topic still looking current.
	if {$row >= 0} { rl_select $b $row 0 } else { rl_clear $b }
}

# A font size N points bigger than `base`, honouring Tk's sign convention: a negative size
# is pixels, and "bigger" there means further from zero.
proc help_font_size {base delta} {
	return [expr {$base < 0 ? $base - $delta : $base + $delta}]
}

# Colours and fonts: at open, and again from apply_theme while the window is up — help can
# stay open across a theme change, unlike the modal dialogs that read the palette once. The
# list is a rich-list well like the file/git panes; the page is rendered prose, so it reads
# in the UI font with the editor's fixed-pitch font for the things that must not reflow.
#
# The render tags are configured HERE rather than at paint time for two reasons: a theme
# switch then recolours a page already on screen, and tag priority falls out of the order
# below (see the note at the end, where the headings are raised back over it).
proc help_restyle {} {
	if {![winfo exists .help]} return
	set c $::theme_colors
	set bg [dict get $c editor.bg]
	set fg [dict get $c editor.fg]
	set mute [blend_hex $fg $bg 45]
	.help configure -background [dict get $c ui.bg]
	.help.find configure -background [dict get $c ui.bg]
	.help.find.l configure -background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.help.find.e configure -background $bg -foreground $fg \
		-insertbackground [dict get $c editor.cursor] \
		-selectbackground [dict get $c editor.selection]
	.help.foot configure -background [dict get $c ui.bg]
	.help.foot.where configure -background [dict get $c ui.bg] \
		-foreground [blend_hex [dict get $c ui.fg] [dict get $c ui.bg] 45]
	foreach b {.help.foot.back .help.foot.fwd .help.foot.close} { $b configure -font RioUIFont }
	foreach f {.help.nav .help.page} { $f configure -background $bg }
	set b .help.nav.list
	$b configure -font RioUIFont -background $bg -foreground [dict get $c ui.fg]
	$b tag configure selrow   -background [dict get $c editor.selection]
	$b tag configure hoverrow -background [blend_hex $bg [dict get $c editor.selection] 25]
	$b tag configure helpsect -foreground [blend_hex [dict get $c ui.fg] $bg 35]
	$b tag raise selrow

	help_style .help.page.text

	# Search hits, last and raised: this one has to win -background over the block that
	# happens to be under it (a match inside a code block or a table is still a match). The
	# find bar's own role, falling back the way it does when a theme omits it. Help-only —
	# the plan view has nothing to search.
	set t .help.page.text
	$t tag configure hit -background [expr {[dict exists $c editor.findmatch] \
		? [dict get $c editor.findmatch] : [dict get $c editor.selection]}]
	$t tag raise hit
}

# Dress a text widget to be painted by help_paint: every tag the renderer uses, from the
# current theme and UI font. Separate from help_restyle because the renderer has a second
# consumer — the plan view (D101) — and a plan should read exactly like a manual page; the
# window's own chrome is what stays in help_restyle.
proc help_style {t} {
	set c $::theme_colors
	set bg [dict get $c editor.bg]
	set fg [dict get $c editor.fg]
	set mute [blend_hex $fg $bg 45]
	set fam  [font configure RioUIFont -family]
	set sz   [font configure RioUIFont -size]
	set mfam [font configure RioEditorFont -family]
	$t configure -font [list $fam $sz] -background $bg -foreground $fg

	# Blocks.
	$t tag configure para  -spacing3 [expr {$sz > 0 ? $sz : 8}]
	$t tag configure h1 -font [list $fam [help_font_size $sz 6] bold] -spacing1 14 -spacing3 8
	$t tag configure h2 -font [list $fam [help_font_size $sz 3] bold] -spacing1 14 -spacing3 6
	$t tag configure h3 -font [list $fam [help_font_size $sz 1] bold] -spacing1 12 -spacing3 4
	for {set d 0} {$d <= 3} {incr d} {
		set ind [expr {18 + $d * 20}]
		$t tag configure li$d -lmargin1 $ind -lmargin2 [expr {$ind + 14}] -spacing3 4
	}
	$t tag configure listmark -foreground $mute
	$t tag configure quote -lmargin1 20 -lmargin2 20 -foreground $mute \
		-font [list $fam $sz italic] -spacing3 [expr {$sz > 0 ? $sz : 8}]
	$t tag configure code -font [list $mfam $sz] -wrap none -lmargin1 20 -lmargin2 20 \
		-background [blend_hex $bg $fg 8] -spacing1 4 -spacing3 8
	$t tag configure table -font [list $mfam $sz] -wrap none -lmargin1 12
	$t tag configure rule -foreground $mute -spacing1 6 -spacing3 6

	# Inline, after the blocks so these win the font.
	$t tag configure em         -font [list $fam $sz italic]
	$t tag configure strong     -font [list $fam $sz bold]
	$t tag configure strongem   -font [list $fam $sz bold italic]
	$t tag configure mem        -font [list $mfam $sz italic]
	$t tag configure mstrong    -font [list $mfam $sz bold]
	$t tag configure mstrongem  -font [list $mfam $sz bold italic]
	$t tag configure tt         -font [list $mfam $sz] -foreground [blend_hex $fg [dict get $c accent] 35]
	$t tag configure link -foreground [dict get $c accent] -underline 1
	# Tag priority is per-option and follows configure order, so the inline tags above beat
	# the block tags on -font — which is right inside a paragraph and wrong inside a heading,
	# where the heading's size has to win. Raising the headings settles only -font; a link in
	# one keeps its colour, since no heading sets a foreground.
	foreach h {h1 h2 h3} { $t tag raise $h }
}


# ---------------------------------------------------------------------------
# Agent provider selection + the Claude API key (AGENTS.md D26). The agent runs
# one provider at a time: the offline `echo` stub (the default — proves the
# streaming path with no network or credentials) or `claude`, the claude-api
# provider, which needs a stored Anthropic API key. Which one is live is a
# runtime choice from the Settings menu; the API key is the only DURABLE agent
# credential, kept by the face as a 0600 secret (D21). The chat header names the
# active provider so the choice is never invisible.
# ---------------------------------------------------------------------------
set ::agent_provider echo   ;# echo | claude | openai | …
set ::provider_key_show 0   ;# the key dialog's reveal toggle
# The Agent Prompts dialog's per-provider chooser (D79): which provider's prompt the
# "Edit its prompt…" button targets, and its live button label. Set when the dialog
# opens; seeded so the vars exist beforehand.
set ::agent_prompt_provider ""
set ::agent_prompt_provider_label ""
# The providers the core carries, each {name,label,keyed,key_set,signup} — the core
# owns the list (D30), so the picker and key dialog render from it rather than
# hardcoding names. Refreshed from agent.providers; an installed provider (milestone
# B) then appears with no GUI change. Seeded so the menus have labels before connect.
set ::agent_providers {{name echo label Echo keyed 0 key_set 0 signup {}}}

# Pull the core's provider list into the cache (agent.providers, D30).
proc agent_providers_refresh {} {
	set resp [rio_call agent.providers {}]
	if {[dict get $resp ok]} { set ::agent_providers [dict get $resp result providers] }
}

# A provider's cache entry by name, or "" if unknown.
proc agent_provider_entry {name} {
	foreach p $::agent_providers { if {[dict get $p name] eq $name} { return $p } }
	return ""
}

# A provider's display label (the chat badge / status strip); falls back to a
# title-cased name if the cache hasn't been populated yet.
proc agent_provider_label {name} {
	set p [agent_provider_entry $name]
	return [expr {$p ne "" ? [dict get $p label] : [string totitle $name]}]
}

# A picker label: the provider's name plus how it authenticates — "(API key)" for a
# keyed provider, "(offline)" for a keyless one (echo).
proc provider_radio_label {p} {
	return "[dict get $p label] ([expr {[dict get $p keyed] ? {API key} : {offline}}])"
}

# Tell the core which provider to run (agent.provider.set, D30). The agent lives in
# the core wherever it runs, so this is an op, not an in-process swap; the chat
# header then names the live choice. Only ever called from a user action (the
# Settings radio) — see adopt_agent_status for why we don't write at attach time.
proc apply_provider {} {
	rio_result agent.provider.set [dict create name $::agent_provider]
	agent_options_refresh   ;# a different provider offers different choices
	chat_status_update
}

# --- the live agent: provider, model, effort, as one control (D106) -----------
#
# What a provider lets you choose is the PROVIDER's business (a model, an effort, or
# something rio has never heard of): the core hands over a list of declared options
# and this pane renders whatever is in it. So nothing below names a model or an
# effort — a provider that grows a third option gets a third section for free.
set ::agent_options {}           ;# the active provider's options, as the core declared them
array set ::agent_option_value {} ;# option name -> chosen value, for the menu's radios

# Pull the active provider's options from the core (D30: they live where the agent
# runs, so a remote core answers for its own machine) and repaint the control.
proc agent_options_refresh {} {
	set r [rio_call agent.options.list {}]
	set ::agent_options [expr {[dict get $r ok] ? [dict get $r result options] : {}}]
	agent_options_sync
}

# One option's descriptor by name, or "" — the pane asks by name, never by position.
proc agent_option_entry {name} {
	foreach o $::agent_options { if {[dict get $o name] eq $name} { return $o } }
	return ""
}

# A value's label, falling back to the value itself (a free value the list never had).
proc agent_option_label {o value} {
	foreach c [dict get $o choices] {
		if {[dict get $c value] eq $value} { return [dict get $c label] }
	}
	return $value
}

# Repaint the selector: the provider, then every option whose value is worth saying.
# The FIRST option is always shown (that is the model, for both shipped providers —
# "which model am I talking to" is the question this strip exists to answer); the rest
# appear only when they are not at their default, so a non-default effort is never
# invisible and a default one never takes up room in a 340 px column.
proc agent_options_sync {} {
	if {![winfo exists .chat.status.sel]} return
	set parts [list [agent_provider_label $::agent_provider]]
	set full  [list "Provider: [agent_provider_label $::agent_provider]"]
	set first 1
	foreach o $::agent_options {
		set n [dict get $o name] ; set v [dict get $o value]
		set ::agent_option_value($n) $v
		if {$first || ![agent_option_is_default $o]} { lappend parts [agent_option_label $o $v] }
		lappend full "[dict get $o label]: [agent_option_label $o $v] ($v)"
		set first 0
	}
	.chat.status.sel configure -text "[join $parts { · }] ▾"
	tooltip .chat.status.sel [join $full "\n"]
	agent_options_menu_fill
}

# Whether an option sits at its default. The core does not say which choice is the
# default — it has no opinion about meaning — so the rule is the provider's own
# convention, declared in the choice list: the FIRST choice is the quiet one.
proc agent_option_is_default {o} {
	set cs [dict get $o choices]
	if {![llength $cs]} { return 0 }
	return [expr {[dict get $o value] eq [dict get [lindex $cs 0] value]}]
}

# Build the selector's menu: the providers (the same radios and the same writer the
# Settings cascade and Preferences use — three doors, one answer, as D102 established),
# then one section per declared option.
proc agent_options_menu_fill {} {
	if {![winfo exists .chat.status.sel.m]} return
	set m .chat.status.sel.m
	$m delete 0 end
	$m add command -label "Provider" -state disabled
	foreach p $::agent_providers {
		$m add radiobutton -label "   [provider_radio_label $p]" \
			-variable ::agent_provider -value [dict get $p name] -command apply_provider
	}
	foreach o $::agent_options {
		set n [dict get $o name]
		$m add separator
		$m add command -label [dict get $o label] -state disabled
		foreach c [dict get $o choices] {
			$m add radiobutton -label "   [dict get $c label]" \
				-variable ::agent_option_value($n) -value [dict get $c value] \
				-command [list agent_option_pick $n [dict get $c value]]
		}
		if {[dict get $o free]} {
			$m add command -label "   Other…" -command [list agent_option_other $n]
		}
		if {[dict get $o refresh]} {
			$m add command -label "   ⟳ Refresh from provider" \
				-command [list agent_option_fetch $n]
		}
	}
}

# The single writer. Push the choice to the core and then re-read: the reply carries
# what the provider ACCEPTED (it may canonicalize), and on a refusal nothing changed,
# so re-reading puts the menu back rather than leaving it claiming a choice the agent
# is not running.
proc agent_option_pick {name value} {
	rio_result agent.option.set [dict create name $name value $value]
	agent_options_refresh
}

# A value the shipped list doesn't carry — a model released after this build, a tag
# on a local server. Only offered for an option the provider declared `free`.
proc agent_option_other {name} {
	set o [agent_option_entry $name]
	if {$o eq ""} return
	set v [name_prompt "[dict get $o label]" "Enter a [string tolower [dict get $o label]]:" \
		[dict get $o value]]
	if {$v eq "" || $v eq [dict get $o value]} return
	agent_option_pick $name $v
}

# Ask the provider to re-enumerate (its models endpoint, a local server's own list).
# The call only acks — the list arrives as an agent.options event, which repaints.
proc agent_option_fetch {name} {
	rio_result agent.options.refresh [dict create name $name]
}

# Adopt the core's LIVE agent settings into our menus instead of imposing ours.
# The agent — provider, auto-accept, stored key — lives in the core (D26/D30), and
# a daemon we attach to over --connect or an in-place reconnect may already have a
# provider chosen and auto-accept set by whoever configured it. Writing our boot
# default (echo, gated) over that at attach time would silently reset that core, so
# at startup and after a reconnect we READ agent.status and mirror it into the
# radio/checkbutton; a WRITE (apply_provider / autoaccept.set) happens only when the
# user actually picks something.
proc adopt_agent_status {} {
	set st [rio_result agent.status {}]
	if {$st eq ""} return   ;# error already surfaced; keep the current menu state
	set ::agent_provider    [dict get $st provider]
	set ::agent_auto_accept [dict get $st auto_accept]
	if {[dict exists $st mode]} { set ::agent_plan_mode [expr {[dict get $st mode] eq "plan"}] }
	providers_menu_fill    ;# refresh the cache + the provider/key menus from the core
	agent_options_refresh   ;# what this provider lets us choose, and what it chose (D106)
	agent_mode_sync         ;# and the mode control, which repaints the strip
	adopt_tls_settings      ;# the core-wide https switch sits beside it at every attach (D114)
}

# Mirror the core's https switch (D114) and what its tcltls can check. Same rule as the
# agent's settings: read at attach, never written then. Quiet on failure — a core that
# predates tls.settings just leaves the Network pane showing its defaults.
proc adopt_tls_settings {} {
	set r [rio_call tls.settings {}]
	if {![dict get $r ok]} return
	set st [dict get $r result]
	set ::tls_unchecked       [dict get $st unchecked]
	set ::tls_checks_hostname [dict get $st checks_hostname]
	set ::tls_version         [dict get $st tcltls]
	if {[winfo exists .prefs.body.network.hint]} {
		.prefs.body.network.hint configure -text [tls_unchecked_hint]
	}
}

# The chat status strip (under the Send button): which agent is live and whether
# proposed edits auto-apply or wait for review. A spot for context-window usage
# later. Called on provider change and on the auto-accept toggle.
# Fill the Settings ▸ Agent Provider picker from the core's provider list (mirrors
# modes_menu_fill). Rebuilt on connect and reconnect (adopt_agent_status) so an
# installed provider (milestone B) shows up with no code change. The provider radios
# share ::agent_provider with the Preferences pane. Provider choice is the one agent
# knob quick enough to belong in the menu; its key/prompts/allow-list are configured
# from the Preferences Agent pane (jka, 2026-09-09), not from here.
proc providers_menu_fill {} {
	agent_providers_refresh
	if {[winfo exists .m.settings.provider]} {
		.m.settings.provider delete 0 end
		foreach p $::agent_providers {
			.m.settings.provider add radiobutton -label [provider_radio_label $p] \
				-variable ::agent_provider -value [dict get $p name] -command apply_provider
		}
	}
}

# --- the agent "working" indicator (D82) -------------------------------------
# Begin animating: a turn is now being worked. Idempotent — cancels any pending tick
# first, so a fresh send (or a resumed turn) just restarts the cycle from a new phrase.
proc chat_busy_start {} {
	after cancel $::chat_busy_after
	set ::chat_busy 1
	set ::chat_busy_frame 0
	set ::chat_busy_word [lindex $::chat_busy_words \
		[expr {int(rand() * [llength $::chat_busy_words])}]]
	chat_busy_render
	chat_send_button
	set ::chat_busy_after [after 400 chat_busy_tick]
}
# One animation frame: advance the dots every tick and the phrase every ~2.4 s, then
# reschedule. A stray tick after a stop is a no-op (guarded on ::chat_busy).
proc chat_busy_tick {} {
	if {!$::chat_busy} return
	incr ::chat_busy_frame
	if {$::chat_busy_frame % 6 == 0} {
		set ::chat_busy_word [lindex $::chat_busy_words \
			[expr {int(rand() * [llength $::chat_busy_words])}]]
	}
	chat_busy_render
	set ::chat_busy_after [after 400 chat_busy_tick]
}
# Paint the current phrase with a 1→2→3 "Please wait…" dot cycle. ASCII dots only, so no
# UI font can drop a glyph (the D54 Windows / Alpine / OpenBSD matrix).
proc chat_busy_render {} {
	set dots [string repeat "." [expr {$::chat_busy_frame % 3 + 1}]]
	catch {.chat.status.busy configure -text "$::chat_busy_word$dots"}
}
# Stop animating and clear the indicator's half of the strip (the agent selector beside
# it never went anywhere).
proc chat_busy_stop {} {
	after cancel $::chat_busy_after
	set ::chat_busy_after ""
	set ::chat_busy 0
	catch {.chat.status.busy configure -text ""}
	chat_send_button
	chat_status_update
}

# The composer's button follows the turn (D104): ▶ Send while it is yours to type into,
# ■ Stop while the agent is working. One button, because the two are never both available —
# and because a turn now runs until it is finished or stopped, so Stop must never be more
# than one click away. At the approval gate the animation stops and the button goes back to
# Send: the turn is parked, waiting on the bar, and there is nothing running to stop.
proc chat_send_button {} {
	if {![winfo exists .chat.send]} return
	if {$::chat_busy} {
		.chat.send configure -text "■" -command chat_stop
		tooltip .chat.send "Stop the agent"
	} else {
		.chat.send configure -text "▶" -command chat_send
		tooltip .chat.send "Send this message"
	}
}

# Stop the turn in flight. The core kills it and announces agent.stopped, which every
# attached frontend adopts (D3/D30) — including this one, so the transcript line and the
# indicator are written by the event, not here, and a stop from another window looks the
# same as a stop from this one.
proc chat_stop {} {
	set r [rio_call agent.stop {}]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		return
	}
	# Nothing was running: the click raced the turn's last event. Put the button back.
	if {[dict get $r result stopped] == 0} { chat_busy_stop }
}

# The status strip names the live agent, and nothing else: the mode is stated once, by the
# header control that sets it (D102). Two places saying it was how the old strip came to lie
# — it showed "plan mode" over an armed auto-accept flag it had no room for. Since D106 the
# strip is a control, and it keeps answering while a turn runs: the working indicator has
# its own half.
proc chat_status_update {} {
	agent_options_sync
}

# --- the agent's mode, as one control (D102) ---------------------------------
# The core keeps two independent flags — `mode` (build|plan, D101) and `auto_accept`
# (edits-only, D26 s5/D83) — because they answer different questions and a TUI may spell
# them differently. The UI offers the three states a user actually chooses between, derived
# from those flags, never a third source of truth: ::agent_mode_ui is computed, never
# stored. Every door (the header menubutton, Settings, Preferences) writes through
# agent_mode_set and reads through agent_mode_sync, so two doors cannot disagree.
proc agent_mode_label {m} {
	return [dict get {plan Plan review Review auto Auto} $m]
}
proc agent_mode_hint {m} {
	return [dict get {
		plan   "Plan mode: the agent reads and plans; it changes nothing until you approve a plan"
		review "Every proposed edit waits for your approval"
		auto   "Proposed edits apply as they come; commands still ask"
	} $m]
}

# Re-derive the control from the flags and relabel it. Called after every write, when the
# core announces a mode change (agent.mode), and on attach (adopt_agent_status).
proc agent_mode_sync {} {
	set ::agent_mode_ui [expr {$::agent_plan_mode ? "plan" :
		($::agent_auto_accept ? "auto" : "review")}]
	if {[winfo exists .chat.hdr.mode]} {
		.chat.hdr.mode configure -text "[agent_mode_label $::agent_mode_ui] ▾"
		tooltip .chat.hdr.mode [agent_mode_hint $::agent_mode_ui]
	}
	chat_status_update
}

# The single writer: push ::agent_mode_ui (just set by whichever radiobutton the user
# picked) to the core, mirroring only what the core accepted. Picking Plan LEAVES
# auto-accept alone — while planning, "Plan" is the whole truth about what the agent may do,
# and how the work goes afterwards is asked on the plan's own approval bar, where the user
# has just read what is proposed (jka, D102). On a refusal the flags are untouched, so
# agent_mode_sync puts the control back rather than leave it claiming a state the agent is
# not in.
proc agent_mode_set {} {
	set want $::agent_mode_ui
	set r [rio_call agent.mode.set [dict create mode [expr {$want eq "plan" ? "plan" : "build"}]]]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		agent_mode_sync
		return
	}
	set ::agent_plan_mode [expr {$want eq "plan"}]
	if {$want ne "plan"} {
		set on [expr {$want eq "auto"}]
		set r [rio_call agent.autoaccept.set [dict create on $on]]
		if {![dict get $r ok]} {
			report_error [dict get $r error message] [dict get $r error code]
			agent_mode_sync
			return
		}
		set ::agent_auto_accept $on
	}
	agent_mode_sync
}

# The writer behind Preferences ▸ Network ▸ "Allow https without host-name checks" (D110,
# core-wide since D114: the agent and extension repositories alike). The choice is the
# CORE's — its tcltls is the one in question, and every frontend attached to it shares the
# answer — so the checkbutton only asks, and shows what the core stored. A refusal puts
# the box back rather than leave it claiming a setting that isn't in force.
proc tls_unchecked_set {} {
	set want $::tls_unchecked
	set ::tls_unchecked [expr {!$want}]
	set r [rio_call tls.settings.set [dict create unchecked $want]]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		return
	}
	set ::tls_unchecked [dict get $r result unchecked]
}

# The hint under that checkbox: what ticking it gives away, and whether it matters on the
# core this GUI is attached to.
proc tls_unchecked_hint {} {
	set what "Off: on a core whose tcltls is older than 1.8, the agent and https extension repositories refuse https — that tcltls accepts a valid certificate issued for any host, not just the server's. Turn on only on a network you trust, if tcltls can't be upgraded there. Plain http is never affected."
	if {$::tls_checks_hostname} {
		return "This core's tcltls checks host names, so this changes nothing here. $what"
	}
	if {$::tls_version ne ""} {
		return "This core has tcltls $::tls_version. $what"
	}
	return $what
}

# The provider API-key dialog (Preferences ▸ Agent ▸ <provider> API Key…). A small
# modal that is a dumb view of one provider's key store: it never holds the key, it
# hands what the user types to agent.key.set for THAT provider / removes it with
# agent.key.clear. Title, prompt and signup hint come from the provider's declared
# metadata (agent.providers), so one dialog serves Claude, ChatGPT, and any future
# provider. Selecting a provider with no key stored isn't blocked here — the first
# turn then surfaces the face's actionable not_configured error (D26).
proc provider_key_dialog {name} {
	agent_providers_refresh
	set p [agent_provider_entry $name]
	if {$p eq "" || ![dict get $p keyed]} return
	set label  [dict get $p label]
	set signup [dict get $p signup]
	set stored [dict get $p key_set]
	set w .providerkey
	destroy $w
	toplevel $w
	wm title $w "$label API key"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set prompt "$label API key"
	if {$signup ne ""} { append prompt " — create one at $signup" }
	append prompt "."
	label $w.prompt -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] -text $prompt
	entry $w.e -show • -width 52 -font RioUIFont
	ctx_bind_input $w.e   ;# masked, so Cut/Copy are left out (D115)
	checkbutton $w.show -text "Show key" -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -selectcolor [dict get $c ui.bg] \
		-variable ::provider_key_show -command [list provider_key_reveal $w]
	set ::provider_key_show 0
	label $w.status -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-text [expr {$stored ? "A key is stored; saving one replaces it." : "No key stored yet."}]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.save   -text "Save"   -font RioUIFont -command [list provider_key_save $w $name]
	button $w.btns.clear  -text "Clear"  -font RioUIFont -command [list provider_key_clear $w $name] \
		-state [expr {$stored ? "normal" : "disabled"}]
	button $w.btns.cancel -text "Cancel" -font RioUIFont -command [list destroy $w]
	pack $w.btns.cancel $w.btns.clear $w.btns.save -side right -padx 3
	grid $w.prompt -row 0 -column 0 -sticky we -padx 8 -pady {8 2}
	grid $w.e      -row 1 -column 0 -sticky we -padx 8
	grid $w.show   -row 2 -column 0 -sticky w  -padx 6
	grid $w.status -row 3 -column 0 -sticky we -padx 8 -pady {2 4}
	grid $w.btns   -row 4 -column 0 -sticky e  -padx 5 -pady {2 8}
	bind $w.e <Return> [list $w.btns.save invoke]
	bind $w <Escape>   [list destroy $w]
	catch {grab $w}
	focus $w.e
}
proc provider_key_reveal {w} {
	$w.e configure -show [expr {$::provider_key_show ? "" : "•"}]
}
proc provider_key_save {w name} {
	set key [string trim [$w.e get]]
	if {$key eq ""} {
		report_error "Enter an API key, or use Clear to remove the stored one."
		return
	}
	rio_result agent.key.set [dict create key $key name $name]
	providers_menu_fill   ;# the provider's key_set state changed
	destroy $w
}
proc provider_key_clear {w name} {
	rio_result agent.key.clear [dict create name $name]
	providers_menu_fill
	destroy $w
}

# ---------------------------------------------------------------------------
# The agent's prompt, laid out layer by layer (Preferences ▸ Agent ▸ Agent Prompts…,
# D70/D79/D105). The dialog lists EVERY layer in composition order — rio's shipped base,
# your system prompt, the active provider's, this project's, and rio's plan-mode layer —
# each with what it is, whether it is in effect right now, and a door: *Edit* for the
# three that are yours, *View* for the two that are rio's. Nothing about what the agent
# is told is hidden from the person whose project it acts on; the shipped text is one
# click away, and "Show the whole prompt…" renders exactly what the provider is sent.
#
# The CORE owns every path and every text (agent.prompt.list / .get / .edit) — a remote
# core answers from its OWN disk (D30), which is the disk that matters — so this dialog
# asks and renders, and never touches the filesystem itself. The static help is muted
# (gutter.fg); the buttons/chooser are the only interactive elements, so help never reads
# as a control (D68).
# ---------------------------------------------------------------------------
# The last inventory read from the core, keyed by layer name — so the row labels, the
# state words and the viewer's header describe what is actually in effect rather than
# what rio ships by default.
set ::prompt_layers {}

proc prompt_layers_refresh {} {
	set ::prompt_layers {}
	set res [rio_result agent.prompt.list {}]
	if {$res eq ""} return
	foreach l [dict get $res prompts] { dict set ::prompt_layers [dict get $l which] $l }
}

# One field of one layer, with a default for a core too old to answer or a layer the
# inventory did not carry.
proc prompt_layer_field {which field {default ""}} {
	if {![dict exists $::prompt_layers $which $field]} { return $default }
	return [dict get $::prompt_layers $which $field]
}

# What this layer is doing right now, in three words — the honest states are "no file
# yet", "a file that says nothing", "saying something the provider is being sent", and
# "saying something that does not apply right now" (the plan layer outside plan mode, a
# provider layer for a provider that is not live).
proc prompt_state_word {which} {
	if {![prompt_layer_field $which exists 0]} { return "not created yet" }
	if {[prompt_layer_field $which chars 0] == 0} { return "empty" }
	if {[prompt_layer_field $which active 0]} { return "in effect now" }
	return "not in effect now"
}

proc agent_prompts_dialog {} {
	set w .agentprompts
	destroy $w
	toplevel $w
	wm title $w "Agent Prompts"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set pr [rio_result project.get {}]
	set have_project [expr {$pr ne "" && [dict get $pr root] ne ""}]
	prompt_layers_refresh

	label $w.intro -anchor w -justify left -font RioUIFont -wraplength 460 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text "Every layer of what the agent is told, in the order it is composed. All of it is plain Markdown, loaded as data — never run. rio's own instructions always apply; your files add to them, and any may be left empty."

	# Layer 1 — rio's own. Shipped, so the door is a reader, not an editor; once the user
	# has made their own copy the door changes to that copy, because that is now the text
	# in effect.
	set mine [expr {[prompt_layer_field base origin] eq "user"}]
	button $w.base -font RioUIFont \
		-text [expr {$mine ? "Edit your copy…" : "View rio's instructions…"}] \
		-command [expr {$mine ? [list agent_prompt_open base] : [list prompt_view base]}]
	label $w.baseh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text [expr {$mine ?
			"Your copy replaces rio's — rio's own updates no longer reach it." :
			"Ships with rio: the tool contract and how the agent works — [prompt_state_word base]."}]

	button $w.sys -text "Edit system prompt…" -font RioUIFont \
		-command [list agent_prompt_open system]
	label $w.sysh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text "For every project — kept with your rio settings ([prompt_state_word system])."
	button $w.proj -text "Edit project prompt…" -font RioUIFont \
		-command [list agent_prompt_open project] \
		-state [expr {$have_project ? "normal" : "disabled"}]
	label $w.projh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text [expr {$have_project ?
			"For the open project — kept in its .rio/ folder ([prompt_state_word project])." :
			"Open a project folder to add one for it."}]

	# The per-provider row (D79): instructions for ONE provider, applied only while
	# that provider is active. The chooser lists every provider except echo (which
	# ignores the system prompt entirely); the button opens that provider's
	# providers/<name>.md via agent.prompt.edit. When only echo is present the row is
	# disabled with a hint — provider prompts need a provider to attach to.
	agent_providers_refresh
	set provnames {}
	foreach p $::agent_providers {
		if {[dict get $p name] eq "echo"} continue
		lappend provnames [dict get $p name]
	}
	if {[llength $provnames]} {
		if {[lsearch -exact $provnames $::agent_provider] >= 0} {
			set ::agent_prompt_provider $::agent_provider
		} else {
			set ::agent_prompt_provider [lindex $provnames 0]
		}
		set ::agent_prompt_provider_label "[agent_provider_label $::agent_prompt_provider]  ▾"
		frame $w.prov -background [dict get $c ui.bg]
		menubutton $w.prov.sel -textvariable ::agent_prompt_provider_label \
			-menu $w.prov.sel.m -font RioUIFont -anchor w -relief raised -borderwidth 1 \
			-highlightthickness 0 -padx 6 -pady 1 \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
			-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
		menu $w.prov.sel.m -tearoff 0 -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
			-activebackground [dict get $c editor.selection] -activeforeground [dict get $c ui.fg]
		foreach name $provnames {
			$w.prov.sel.m add radiobutton -label [agent_provider_label $name] \
				-variable ::agent_prompt_provider -value $name \
				-command [list set ::agent_prompt_provider_label "[agent_provider_label $name]  ▾"]
		}
		button $w.prov.edit -text "Edit its prompt…" -font RioUIFont \
			-command {agent_prompt_open provider $::agent_prompt_provider}
		pack $w.prov.sel $w.prov.edit -side left -padx {0 6}
		label $w.provh -anchor w -justify left -font RioUIFont -wraplength 300 \
			-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
			-text "Only while that provider is active — kept with your rio settings."
	} else {
		button $w.prov -text "Edit provider prompt…" -font RioUIFont -state disabled
		label $w.provh -anchor w -justify left -font RioUIFont -wraplength 300 \
			-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
			-text "Install a provider to add provider-specific instructions."
	}

	# Layer 5 — rio's plan-mode instructions. Same offer as the base layer, and the same
	# reason for it: it is rio's machinery, so it is readable, and replaceable by a copy.
	set pmine [expr {[prompt_layer_field plan origin] eq "user"}]
	button $w.plan -font RioUIFont \
		-text [expr {$pmine ? "Edit your copy…" : "View plan instructions…"}] \
		-command [expr {$pmine ? [list agent_prompt_open plan] : [list prompt_view plan]}]
	label $w.planh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text [expr {$pmine ?
			"Your copy replaces rio's — rio's own updates no longer reach it." :
			"Ships with rio: added only in Plan mode — [prompt_state_word plan]."}]

	# And the whole thing, joined: the one view that cannot mislead, because it is
	# literally the string the provider is handed.
	button $w.full -text "Show the whole prompt…" -font RioUIFont \
		-command [list prompt_view composed]
	label $w.fullh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text "Every active layer, joined — exactly what the provider is sent."

	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.close -text "Close" -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right -padx 3

	grid $w.intro -row 0 -column 0 -columnspan 2 -sticky we -padx 8 -pady {8 6}
	grid $w.base  -row 1 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.baseh -row 1 -column 1 -sticky w -padx {0 8}
	grid $w.sys   -row 2 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.sysh  -row 2 -column 1 -sticky w -padx {0 8}
	grid $w.prov  -row 3 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.provh -row 3 -column 1 -sticky w -padx {0 8}
	grid $w.proj  -row 4 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.projh -row 4 -column 1 -sticky w -padx {0 8}
	grid $w.plan  -row 5 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.planh -row 5 -column 1 -sticky w -padx {0 8}
	grid $w.full  -row 6 -column 0 -sticky w -padx {8 6} -pady {10 3}
	grid $w.fullh -row 6 -column 1 -sticky w -padx {0 8} -pady {10 3}
	grid $w.btns  -row 7 -column 0 -columnspan 2 -sticky e -padx 5 -pady {6 8}
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.sys
}

# Read one prompt layer, rendered, in a window of its own (D105) — rio's shipped base or
# plan-mode instructions, or `composed`, the finished string the provider is sent. It is a
# READER: the text belongs to rio (or, for `composed`, to no single file), so there is
# nothing here to save. What there is, for a shipped layer, is *Make my own copy*, which
# hands the same text back as an editable override in the user's own agent dir.
#
# Rendered with the manual's renderer (help_blocks → help_paint, D100), like the plan view
# (D101) — these ARE Markdown documents, and reading them as a rendered page is the whole
# point of showing them at all. Links are styled but inert here, as in the plan view: the
# renderer's click binding follows a manual topic, which is not what a link in a prompt
# means.
proc prompt_view {which {name ""}} {
	set params [dict create which $which]
	if {$name ne ""} { dict set params name $name }
	set res [rio_result agent.prompt.get $params]
	if {$res eq ""} return
	set w .promptview
	destroy $w
	toplevel $w
	wm title $w [prompt_view_title $which]
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	label $w.where -anchor w -justify left -font RioUIFont -wraplength 640 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text [prompt_view_where $res]
	frame $w.body -background [dict get $c ui.bg]
	text $w.body.t -wrap word -width 82 -height 28 -state disabled -cursor arrow \
		-padx 10 -pady 8 -borderwidth 0 -highlightthickness 0 \
		-yscrollcommand [list $w.body.sb set]
	ctx_bind_view $w.body.t   ;# Copy / Select All (D115)
	scrollbar $w.body.sb -command [list $w.body.t yview]
	pack $w.body.sb -side right -fill y
	pack $w.body.t -side left -fill both -expand 1

	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.close -text "Close" -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right -padx 3
	# The copy is offered only where it means something: a shipped layer the user has not
	# already replaced. `composed` has no file to copy, and an override is already theirs.
	if {$which in {base plan} && [dict get $res origin] ne "user"} {
		button $w.btns.copy -text "Make my own copy…" -font RioUIFont \
			-command [list prompt_view_copy $which]
		pack $w.btns.copy -side right -padx 3
	}

	grid $w.where -row 0 -column 0 -sticky we -padx 10 -pady {8 4}
	grid $w.body  -row 1 -column 0 -sticky nsew -padx 8
	grid $w.btns  -row 2 -column 0 -sticky e -padx 5 -pady {6 8}
	grid rowconfigure $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1

	$w.body.t configure -state normal
	$w.body.t delete 1.0 end
	help_paint $w.body.t [help_blocks [dict get $res text]]
	$w.body.t configure -state disabled
	$w.body.t yview moveto 0
	help_style $w.body.t
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.btns.close
}

# The viewer's window title — what you are reading, not which layer number it is.
proc prompt_view_title {which} {
	switch -- $which {
		base     { return "rio's instructions to the agent" }
		plan     { return "rio's plan-mode instructions" }
		composed { return "The whole prompt" }
	}
	return "Agent prompt"
}

# The line above the text: where it comes from, in the words the inventory uses. The path
# is the core's, so a remote core names the file on the machine the agent actually runs on
# (D30) — which is the answer to "where do I change this?".
proc prompt_view_where {res} {
	set path [dict get $res path]
	switch -- [dict get $res origin] {
		composed { return "Every active layer, joined in order — this is the exact text the provider is sent." }
		shipped  { return "Shipped with rio: $path — read-only here. Your own copy would override it." }
		user     { return "Your own file: $path" }
		project  { return "This project's file: $path" }
	}
	return "No file — this layer is contributing nothing."
}

# Turn a shipped layer into the user's own copy: the core writes the override, seeded with
# the text that was in effect (agent.prompt.edit, D105), and it opens as an ordinary tab.
# The viewer and the list both close — what is in effect has just changed, and a list that
# still said "ships with rio" would be describing the past.
proc prompt_view_copy {which} {
	destroy .promptview
	agent_prompt_open $which
}
# Ask the core to resolve+create the prompt file, then open it as a normal tab. `which`
# is system | project | provider — or base | plan, where the file created is the user's
# OVERRIDE of a shipped layer, seeded by the core with a copy of the text it overrides
# (D105), so "make my own copy" opens the text the user just read rather than a blank
# page. A provider prompt also needs `name` (the chosen provider). The core raises
# bad_request for `project` with no open project or a bad provider name — but the relevant
# control is disabled/validated here, so those are safety nets, surfaced through the usual
# error path.
proc agent_prompt_open {which {name ""}} {
	set params [dict create which $which]
	if {$name ne ""} { dict set params name $name }
	set resp [rio_call agent.prompt.edit $params]
	if {![dict get $resp ok]} {
		report_error "Could not open the $which prompt:\n[dict get $resp error message]" \
			[dict get $resp error code]
		return
	}
	destroy .agentprompts
	do_open [dict get $resp result path]
}

# Manage the command allow-list (D84): the human-authored rules that let a proposed
# command run without the approval bar. A scope selector (mirroring the Agent Prompts
# dialog) chooses which of the three lists to view/edit — all projects (global), this
# project (.rio/), or a chosen provider — and the box lists that scope's rules, with
# Remove and a one-line Add that splits on whitespace into tokens. All three lists are
# hand-editable on disk too; this is the friendly front door. `::allow_scope` holds the
# selected {scope name}; `::allow_rules` mirrors the shown list so a row maps back to
# its exact token-list for removal.
proc agent_allow_dialog {} {
	set w .agentallow
	destroy $w
	toplevel $w
	wm title $w "Allowed Commands"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set ::allow_scope [list global ""]
	set ::allow_scope_label "All projects  ▾"

	label $w.intro -anchor w -justify left -font RioUIFont -wraplength 380 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text "Commands whose start matches a rule below run without asking. A one-word rule (pytest) trusts every run of that program; more words (git status) trust only commands that start that way. Each scope is its own list; a command is trusted if any active scope allows it. Removing a rule makes it ask again."

	# Scope selector: which of the three lists this dialog shows (global / project /
	# per-provider), mirroring the Agent Prompts dialog's provider chooser.
	set pr [rio_result project.get {}]
	set haveproj [expr {$pr ne "" && [dict get $pr root] ne ""}]
	agent_providers_refresh
	frame $w.scope -background [dict get $c ui.bg]
	label $w.scope.lbl -text "Scope:" -font RioUIFont -anchor w \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	menubutton $w.scope.sel -textvariable ::allow_scope_label -menu $w.scope.sel.m \
		-font RioUIFont -anchor w -relief raised -borderwidth 1 -highlightthickness 0 -padx 6 -pady 1 \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	menu $w.scope.sel.m -tearoff 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c editor.selection] -activeforeground [dict get $c ui.fg]
	$w.scope.sel.m add command -label "All projects" \
		-command [list agent_allow_set_scope $w global "" "All projects"]
	$w.scope.sel.m add command -label "This project" \
		-state [expr {$haveproj ? "normal" : "disabled"}] \
		-command [list agent_allow_set_scope $w project "" "This project"]
	set anyprov 0
	foreach p $::agent_providers {
		if {[dict get $p name] eq "echo"} continue
		set anyprov 1
		set pl [agent_provider_label [dict get $p name]]
		$w.scope.sel.m add command -label "$pl only" \
			-command [list agent_allow_set_scope $w provider [dict get $p name] "$pl only"]
	}
	if {$anyprov} { $w.scope.sel.m insert 2 separator }
	pack $w.scope.lbl -side left -padx {0 6}
	pack $w.scope.sel -side left

	frame $w.l -background [dict get $c ui.bg]
	listbox $w.l.box -height 8 -width 46 -font RioUIFont -activestyle none \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-selectbackground [dict get $c editor.selection] -selectforeground [dict get $c editor.fg] \
		-yscrollcommand [list $w.l.sb set]
	scrollbar $w.l.sb -command [list $w.l.box yview]
	pack $w.l.box -side left -fill both -expand 1
	pack $w.l.sb -side right -fill y
	frame $w.add -background [dict get $c ui.bg]
	entry $w.add.e -font RioUIFont -width 34 \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor]
	ctx_bind_input $w.add.e   ;# (D115)
	button $w.add.b -text "Add" -font RioUIFont -command [list agent_allow_add_from_entry $w]
	bind $w.add.e <Return> [list agent_allow_add_from_entry $w]
	pack $w.add.e -side left -fill x -expand 1 -padx {0 6}
	pack $w.add.b -side left
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.rm -text "Remove" -font RioUIFont -command [list agent_allow_remove_selected $w]
	button $w.btns.close -text "Close" -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right -padx 3
	pack $w.btns.rm -side right -padx 3

	grid $w.intro -row 0 -column 0 -sticky we -padx 8 -pady {8 6}
	grid $w.scope -row 1 -column 0 -sticky w  -padx 8 -pady {0 4}
	grid $w.l     -row 2 -column 0 -sticky we -padx 8 -pady 3
	grid $w.add   -row 3 -column 0 -sticky we -padx 8 -pady 3
	grid $w.btns  -row 4 -column 0 -sticky we -padx 5 -pady {6 8}
	agent_allow_refresh $w
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.add.e
}

# Switch the manager to another scope and reload its list.
proc agent_allow_set_scope {w scope name label} {
	set ::allow_scope [list $scope $name]
	set ::allow_scope_label "$label  ▾"
	agent_allow_refresh $w
}

# Repopulate the manager's listbox from the selected scope's allow-list.
proc agent_allow_refresh {w} {
	if {![winfo exists $w]} return
	lassign $::allow_scope scope name
	set res [rio_result agent.allow.list [dict create scope $scope name $name]]
	set ::allow_rules [expr {$res ne "" ? [dict get $res rules] : {}}]
	$w.l.box delete 0 end
	foreach rule $::allow_rules { $w.l.box insert end [join $rule " "] }
}

# Add the rule typed in the entry (whitespace-split into tokens) to the selected scope.
proc agent_allow_add_from_entry {w} {
	set toks [regexp -all -inline {\S+} [$w.add.e get]]
	if {![llength $toks]} return
	lassign $::allow_scope scope name
	rio_call agent.allow.add [dict create rule $toks scope $scope name $name]
	$w.add.e delete 0 end
	agent_allow_refresh $w
}

# Remove the selected rule from the selected scope, then refresh.
proc agent_allow_remove_selected {w} {
	set sel [$w.l.box curselection]
	if {![llength $sel]} return
	set rule [lindex $::allow_rules [lindex $sel 0]]
	lassign $::allow_scope scope name
	rio_call agent.allow.remove [dict create rule $rule scope $scope name $name]
	agent_allow_refresh $w
}

proc do_save_as {path} {
	set resp [rio_call file.save [dict create buffer $::cur path $path]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not save $path:\n[dict get $resp error message]"
		return 0
	}
	bufset $::cur path $path
	bufset $::cur gone_ack 0   ;# it is on disk again (D94)
	hl_refresh_buffer $::cur   ;# the new name may pick a highlighter (D112)
	clear_modified
	refresh_dock   ;# the new/renamed file (and its git flag) now shows in the pane
	return 1
}

proc do_save {} {
	if {[bufget $::cur path] eq ""} { return [save_as_dialog] }
	set resp [rio_call file.save [dict create buffer $::cur]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not save:\n[dict get $resp error message]"
		return 0
	}
	bufset $::cur gone_ack 0   ;# a kept-open deleted file has just been recreated (D94)
	clear_modified
	refresh_dock   ;# saved edits are now on disk — repaint so the git flag appears
	return 1
}

proc do_undo {} {
	set res [rio_result edit.undo [dict create buffer $::cur]]
	if {$res ne "" && [dict get $res changed]} { mark_modified 1 }
}
proc do_redo {} {
	set res [rio_result edit.redo [dict create buffer $::cur]]
	if {$res ne "" && [dict get $res changed]} { mark_modified 1 }
}

# ---------------------------------------------------------------------------
# Find / Replace (AGENTS.md D36). The bar is a thin view: the MATCHING runs in
# the core (buffer.find / buffer.matches — the core owns the canonical text,
# D3), and the bar carries only the frontend-local state those ops are
# stateless about (D22): the needle, the options, and the caret it passes as
# `from`. Replace is the existing edit path — a found range plus a
# buffer.replace; Replace All is one op and ONE undo step. The bar always acts
# on the FOCUSED group; matches are painted with the `findmatch` tag
# (editor.findmatch role, D24), the current match with the native selection.
# ---------------------------------------------------------------------------
set ::find_shown   0  ;# find bar visible? (Ctrl+F / Ctrl+H; Esc hides it)
set ::find_case    0  ;# Match case checkbox (off = fold case, the familiar default)
set ::find_word    0  ;# Whole word checkbox (off = substring; on = word-bounded, D51)
set ::find_regex   0  ;# Regex checkbox (on = needle is a Tcl-ARE pattern, D52 Phase C)
set ::find_starts  {} ;# match starts from the last find_update ("i of n" lookup)
set ::find_pending 0  ;# a coalesced find_update is queued (see apply_change)

# Show the bar (packing it above the status bar), with or without the Replace
# row — Ctrl+F and Ctrl+H open the same bar in the two shapes. A single-line
# editor selection pre-fills the needle (the 90s convention); the needle entry
# gets focus with its text selected, so typing starts a fresh search.
proc find_open {withReplace} {
	set ::find_shown 1
	pack .find -after .status -side bottom -fill x
	if {$withReplace} {
		grid .find.rl ; grid .find.re ; grid .find.rep ; grid .find.repall
	} else {
		grid remove .find.rl .find.re .find.rep .find.repall
	}
	set t [gw $::focus]
	if {![catch {$t get sel.first sel.last} s] && $s ne "" \
			&& [string first "\n" $s] < 0} {
		.find.e delete 0 end
		.find.e insert 0 $s
	}
	focus .find.e
	.find.e selection range 0 end
	.find.e icursor end
	find_update
}

# Hide the bar, clear the match paint everywhere, and hand focus back.
proc find_close {} {
	if {!$::find_shown} return
	set ::find_shown 0
	pack forget .find
	foreach g $::groups { [gw $g] tag remove findmatch 1.0 end }
	set ::find_starts {}
	focus [gget $::focus path]
}

# The count/status label at the bar's right ("12 matches", "3 of 12", …).
proc find_status {msg} { .find.count configure -text $msg }

# Recompute the matches for the focused group's buffer: repaint the findmatch
# tag and refresh the count. Runs on every needle keystroke, on the case
# toggle, on a tab switch, and (coalesced) after any buffer change — one
# buffer.matches round-trip, the same cost as one typed character. Painting is
# capped so a one-letter needle in a huge file cannot stall the view; the
# count stays exact.
proc find_update {} {
	set ::find_pending 0
	if {!$::find_shown} return
	set g $::focus ; set t [gw $g]
	$t tag remove findmatch 1.0 end
	set ::find_starts {}
	set needle [.find.e get]
	if {$needle eq ""} { find_status "" ; return }
	set resp [rio_call buffer.matches [dict create buffer [gcur $g] \
		needle $needle nocase [expr {!$::find_case}] wholeword $::find_word regex $::find_regex]]
	if {![dict get $resp ok]} { find_status "" ; return }
	set n [dict get $resp result count]
	set painted 0
	foreach m [dict get $resp result matches] {
		lappend ::find_starts [dict get $m start]
		if {[incr painted] <= 1000} {
			$t tag add findmatch [dict get $m start] [dict get $m end]
		}
	}
	find_status [expr {$n == 0 ? "No matches" : "$n match[expr {$n==1 ? "" : "es"}]"}]
}

# Jump to the next (or previous) match: ask the core for the match after the
# current one — after the selection's edge, else the caret — select it, put
# the caret on its far side, and scroll it into view. Search wraps around; the
# label says so.
proc find_step {backwards} {
	if {!$::find_shown} { find_open 0 ; return }
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	if {$backwards} {
		if {[catch {$t index sel.first} from]} { set from [$t index insert] }
	} else {
		if {[catch {$t index sel.last} from]} { set from [$t index insert] }
	}
	set resp [rio_call buffer.find [dict create buffer [gcur $g] needle $needle \
		from $from nocase [expr {!$::find_case}] backwards $backwards \
		wholeword $::find_word regex $::find_regex]]
	if {![dict get $resp ok]} return
	set r [dict get $resp result]
	if {![dict get $r found]} { find_status "No matches" ; return }
	set s [dict get $r start] ; set e [dict get $r end]
	$t tag remove sel 1.0 end
	$t tag add sel $s $e
	# No expr here: an index like 1.10 would coerce to the float 1.1 (see
	# editor_proxy's delete arm for the original bite of this).
	if {$backwards} { $t mark set insert $s } else { $t mark set insert $e }
	$t see $s
	set i [lsearch -exact $::find_starts $s]
	set n [llength $::find_starts]
	if {$i >= 0} {
		set msg "[expr {$i + 1}] of $n"
		if {[dict get $r wrapped]} { append msg " · wrapped" }
		find_status $msg
	}
}
proc find_next {} { find_step 0 }
proc find_prev {} { find_step 1 }

# Regex supersedes whole-word (a pattern writes its own boundaries), so grey the
# Whole word box while Regex is on, then re-run the search with the new mode.
proc find_regex_changed {} {
	.find.word configure -state [expr {$::find_regex ? "disabled" : "normal"}]
	find_update
}

# Replace the current match, then jump to the next: if the selection IS a
# match of the needle, replace it through the ordinary edit op; otherwise this
# first click just selects the next match and the next click replaces it (the
# classic two-step, so a replace is always visible before it happens).
proc find_replace_one {} {
	if {!$::find_shown} return
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	if {![catch {list [$t index sel.first] [$t index sel.last]} range]} {
		lassign $range s e
		set cur [$t get $s $e]
		# Does the selection stand as a match? Literal: an exact (case-folded) equality.
		# Regex: the whole selection matches the pattern — and the replacement is the
		# regsub of the pattern over the selection, so backreferences resolve against
		# this actual match (a client-side substitution of an already-matched string).
		set newtext [.find.re get]
		if {$::find_regex} {
			set flags {} ; if {!$::find_case} { lappend flags -nocase }
			set same [expr {![catch {regexp {*}$flags -- "^(?:$needle)\$" $cur} m] && $m}]
			if {$same} { catch {regsub {*}$flags -- $needle $cur [.find.re get] newtext} }
		} else {
			set same [expr {$::find_case ? [string equal $cur $needle] \
			                             : [string equal -nocase $cur $needle]}]
		}
		if {$same} {
			if {[dict get [rio_call buffer.replace [dict create buffer [gcur $g] \
				start $s end $e text $newtext]] ok]} { mark_modified 1 }
		}
	}
	find_step 0
}

# Replace every match in one op (buffer.replace_all): one round-trip, one undo
# step. The buffer.changed event repaints the widget before the reply lands
# (events precede replies on the channel), so only the caret needs restoring.
proc find_replace_all {} {
	if {!$::find_shown} return
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	set at [$t index insert]
	set resp [rio_call buffer.replace_all [dict create buffer [gcur $g] \
		needle $needle text [.find.re get] nocase [expr {!$::find_case}] \
		wholeword $::find_word regex $::find_regex]]
	if {![dict get $resp ok]} return
	set n [dict get $resp result count]
	if {$n > 0} { mark_modified 1 }
	catch { $t mark set insert $at ; $t see insert }
	find_update
	find_status "Replaced $n"
}

# ---------------------------------------------------------------------------
# The Search panel (AGENTS.md D52): the grown-up sibling of the inline find bar —
# find across three SCOPES (Current doc / Open docs / Project) in one bottom tool
# window, its results a grouped, navigable list. Two core engines sit behind the
# scope selector, so buffer and project search can never disagree:
#   Project    → project.search  (the on-disk tree; only the core sees it remotely)
#   Open docs  → buffers.search  (every open buffer's LIVE text — unsaved edits too)
#   Current doc→ buffers.search with `only` the focused buffer
# It grew from the D51 find-in-files panel (the `.results` widget paths are kept),
# and is the concrete bottom-site tenant D35 will re-home into its dock. Replace
# (Phase B) and regex (Phase C) are later arcs; the query row leaves room. rl_*
# draws the grouped list; the inline find bar stays the quick in-buffer path (D35 #5).
# ---------------------------------------------------------------------------
set ::search_shown   0        ;# panel visible?
set ::search_case    0        ;# "Match case" (off = case-insensitive, the friendlier first search)
set ::search_word    0        ;# "Whole word" (off = substring; on = word-bounded, D51)
set ::search_scope   "Current doc" ;# default; one of: Project | Open docs | Current doc
set ::search_replace 0        ;# the replace row shown? (Ctrl+H, like the find bar)

# Show the panel (above the find bar / status). `seed` overrides the query text —
# the sentinel __sel__ (the default) seeds from the editor selection like the find
# bar; any other value is used verbatim (the bar handoff passes its needle). Search
# at once if there is a needle. Project scope needs an open folder; the buffer
# scopes search the open documents regardless, so only Project reports "no folder".
proc search_open {{seed __sel__}} {
	set root ""
	catch { set root [dict get [rio_result project.get {}] root] }
	rio::layout::unhide bottom search ; rio::layout::put bottom active search ;# give Search a tab
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	if {$seed eq "__sel__"} {
		catch {
			set sel [[gw $::focus] get sel.first sel.last]
			if {$sel ne "" && [string first "\n" $sel] < 0} {
				.results.hdr.e delete 0 end ; .results.hdr.e insert 0 $sel
			}
		}
	} else {
		.results.hdr.e delete 0 end ; .results.hdr.e insert 0 $seed
	}
	focus .results.hdr.e
	.results.hdr.e selection range 0 end
	.results.hdr.e icursor end
	if {$::search_scope eq "Project" && $root eq ""} {
		search_paint {} ; .results.hdr.count configure -text "open a folder to search"
		return
	}
	if {[string trim [.results.hdr.e get]] ne ""} search_run
}

# Hide the panel and hand focus back to the editor.
proc search_close {} {
	if {![rio::layout::shown search]} return
	rio::layout::hide bottom search
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	focus [gget $::focus path]
}

# Run the query for the current scope and repaint the grouped result list. Empty
# needle clears; the option toggles and the scope selector re-run (their -command).
# One round-trip per Enter/toggle — search walks a tree or every buffer, so it is
# not a per-keystroke live paint like the in-buffer find bar.
proc search_run {} {
	if {!$::search_shown} return
	set needle [.results.hdr.e get]
	if {[string trim $needle] eq ""} { search_paint {} ; .results.hdr.count configure -text "" ; return }
	set nocase [expr {!$::search_case}]
	set rx $::search_regex
	switch -- $::search_scope {
		"Open docs" {
			set resp [rio_call buffers.search [dict create needle $needle \
				nocase $nocase wholeword $::search_word regex $rx]]
		}
		"Current doc" {
			set only ""
			catch { set only [gcur $::focus] }
			set resp [rio_call buffers.search [dict create needle $needle \
				nocase $nocase wholeword $::search_word regex $rx only $only]]
		}
		default {
			set resp [rio_call project.search [dict create needle $needle \
				nocase $nocase wholeword $::search_word regex $rx]]
		}
	}
	if {![dict get $resp ok]} {
		search_paint {} ; .results.hdr.count configure -text [dict get $resp error message]
		return
	}
	set r [dict get $resp result]
	search_paint [dict get $r results]
	set n [dict get $r count] ; set f [dict get $r files]
	if {$n == 0} {
		set msg "No results"
	} else {
		# The container noun follows the scope: on-disk files vs open buffers.
		set unit [expr {$::search_scope eq "Project" ? "file" : "buffer"}]
		set msg "$n [expr {$n == 1 ? {match} : {matches}}] · $f $unit[expr {$f == 1 ? {} : {s}}]"
		if {[dict get $r truncated]} { append msg " (truncated)" }
	}
	.results.hdr.count configure -text $msg
}

# Repaint the rich-list: a non-selectable file-header row then one selectable row
# per matching line ("<line>  <text>"), its payload the location to open. Mirrors
# the git/files panes' rl_* rendering. A file object carries EITHER `rel` (a disk
# path, from project.search) or `name` (an open buffer, from buffers.search) for
# the header, and its rows a `path` (open via do_open) or a `buffer` id (switch via
# activate) — so one render path serves every scope. Every occurrence on a row is
# tinted with the `fimatch` band (D51): the core hands back each hit's 1-based start
# column in `cols` and its char length in the parallel `lens` (so a variable-length
# regex hit sizes correctly, D52 Phase C), offset here by the "<line>  " prefix. `L`
# tracks the text-widget line as rows are appended (header rows count too).
proc search_paint {results} {
	set b .results.well.body
	rl_begin $b
	set L 0
	set isbuf 0
	foreach fdict $results {
		set isbuf [dict exists $fdict buffer]
		set head [expr {$isbuf ? [dict get $fdict name] : [dict get $fdict rel]}]
		$b insert end "$head\n" fifile
		rl_row $b 0 ""
		incr L
		foreach m [dict get $fdict matches] {
			set prefix [format "  %5d  " [dict get $m line]]
			set txt [string trimright [dict get $m text]]
			$b insert end "$prefix$txt\n"
			set loc [dict create line [dict get $m line] col [dict get $m col]]
			if {$isbuf} {
				dict set loc buffer [dict get $fdict buffer]
			} else {
				dict set loc path [dict get $fdict path]
			}
			rl_row $b 1 $loc
			incr L
			set plen [string length $prefix]
			set tend [expr {$plen + [string length $txt]}]
			foreach c [dict get $m cols] len [dict get $m lens] {
				set s [expr {$plen + $c - 1}]
				if {$s >= $tend || $len <= 0} continue   ;# past the trimmed/capped text, or zero-width
				set e [expr {min($s + $len, $tend)}]
				$b tag add fimatch $L.$s $L.$e
			}
		}
	}
	rl_end $b
}

# Activate a result row: go to its location and move the caret to the match. A disk
# hit (payload `path`) opens/switches via do_open; an open-buffer hit (payload
# `buffer`) switches to that tab via activate. The index is built as a string, not
# through expr, so a column like 10 isn't coerced to a float (the editor_proxy /
# buffer.find float trap, met again).
proc search_activate {payload} {
	if {[dict exists $payload buffer]} {
		set id [dict get $payload buffer]
		if {![dict exists $::buffers $id]} return   ;# a buffer the GUI no longer tracks
		activate $id
	} else {
		if {![do_open [dict get $payload path]]} return
	}
	set t [gw $::focus]              ;# widget COMMAND for the subcommands below…
	catch {
		$t mark set insert "[dict get $payload line].[expr {[dict get $payload col] - 1}]"
		$t see insert
	}
	curline_update $::focus          ;# the jump landed after activate's refresh_status
	focus [gget $::focus path]       ;# …but focus takes the window PATH (the gutter-bug trap)
}

# Escalate from the inline find bar into the Search panel (Ctrl+Shift+F while the
# bar is focused): carry the bar's needle + options across and widen to Project
# scope (the point of escalating). If the bar was in Replace mode, carry the
# replacement text and open the panel's replace row too. The panel then owns the query.
proc search_from_bar {} {
	set ::search_case  $::find_case
	set ::search_word  $::find_word
	set ::search_regex $::find_regex
	set ::search_scope "Project"
	search_regex_sync
	if {[llength [grid info .find.rep]] > 0} {
		.results.rep.e delete 0 end ; .results.rep.e insert 0 [.find.re get]
		search_show_replace 1
	}
	search_open [.find.e get]
}

# Regex supersedes whole-word in the panel too: grey the panel's Whole word box
# while Regex is on. `search_regex_changed` also re-runs the query (the checkbox's
# -command); `search_regex_sync` only reflects the state (used on a handoff).
proc search_regex_sync {} {
	.results.hdr.word configure -state [expr {$::search_regex ? "disabled" : "normal"}]
}
proc search_regex_changed {} { search_regex_sync ; search_run }

# Show or hide the replace row (D52 Phase B) — the find bar's Ctrl+H, brought to the
# panel. Packed -side bottom so it lands just ABOVE the bottom-anchored query row (a
# later -side bottom slave stacks above the earlier one), keeping the query field
# pinned to the bottom edge when the replace row appears/disappears.
proc search_show_replace {on} {
	set ::search_replace $on
	if {$on} {
		pack .results.rep -side bottom -fill x
		focus .results.rep.e
	} else {
		pack forget .results.rep
	}
}

# Replace every match for the current scope (D52 Phase B). Buffer scopes go through
# buffer.replace_all — one undo step per buffer, the change UNSAVED — with each
# touched buffer flagged modified. Project goes through the destructive, confirm-
# gated project.replace: open files are edited in their buffers (undoable), closed
# files rewritten on disk. The old hit locations are stale afterwards, so the list
# is cleared and the count line reports what changed (mirroring the find bar).
proc search_replace_all {} {
	if {!$::search_shown} return
	set needle [.results.hdr.e get]
	if {[string trim $needle] eq ""} { focus .results.hdr.e ; return }
	set repl   [.results.rep.e get]
	set nocase [expr {!$::search_case}]
	set ww     $::search_word
	set rx     $::search_regex
	switch -- $::search_scope {
		"Current doc" {
			set resp [rio_call buffer.replace_all [dict create buffer [gcur $::focus] \
				needle $needle text $repl nocase $nocase wholeword $ww regex $rx]]
			set n [expr {[dict get $resp ok] ? [dict get $resp result count] : 0}]
			if {$n > 0} { mark_modified 1 }
			set msg "Replaced $n"
		}
		"Open docs" {
			set n 0 ; set touched 0
			foreach id [dict keys $::buffers] {
				set resp [rio_call buffer.replace_all [dict create buffer $id \
					needle $needle text $repl nocase $nocase wholeword $ww regex $rx]]
				if {[dict get $resp ok] && [dict get $resp result count] > 0} {
					incr n [dict get $resp result count] ; incr touched
					bufset $id modified 1
				}
			}
			if {$touched > 0} refresh_all
			set msg "Replaced $n · $touched buffer[expr {$touched == 1 ? {} : {s}}]"
		}
		default {
			# Project: destructive on disk for closed files — count, then confirm.
			set sresp [rio_call project.search [dict create needle $needle \
				nocase $nocase wholeword $ww regex $rx]]
			set cnt [expr {[dict get $sresp ok] ? [dict get $sresp result count] : 0}]
			if {$cnt == 0} { search_paint {} ; .results.hdr.count configure -text "No results" ; return }
			set ans [tk_messageBox -icon warning -type yesno -title "Replace in Project" \
				-message "Replace all $cnt occurrence[expr {$cnt == 1 ? {} : {s}}] of \"$needle\" across the project?\n\nOpen documents are edited in the editor (undoable); files not open are written to disk and cannot be undone."]
			if {$ans ne "yes"} return
			set resp [rio_call project.replace [dict create needle $needle text $repl \
				nocase $nocase wholeword $ww regex $rx]]
			if {![dict get $resp ok]} {
				.results.hdr.count configure -text [dict get $resp error message] ; return
			}
			set r [dict get $resp result]
			foreach id [dict get $r bufferids] {
				if {[dict exists $::buffers $id]} { bufset $id modified 1 }
			}
			if {[llength [dict get $r bufferids]] > 0} refresh_all
			set nb [llength [dict get $r bufferids]] ; set nf [dict get $r files]
			set msg "Replaced [dict get $r count] · $nf file[expr {$nf == 1 ? {} : {s}}], $nb buffer[expr {$nb == 1 ? {} : {s}}]"
		}
	}
	search_paint {}
	.results.hdr.count configure -text $msg
}

# Close the active buffer of the focused group; guard unsaved changes. If this empties
# one of two groups, the group collapses (unsplit); the sole group instead keeps at
# least one tab by minting a scratch (D33).
proc do_close {} {
	if {![maybe_discard]} return
	set g $::focus
	set victim $::cur
	set idx [lsearch -exact [gorder $g] $victim]
	close_buffer $victim
	set order [gorder $g]
	if {![llength $order]} {
		if {[llength $::groups] >= 2} { collapse_group $g } else { do_new }
	} else {
		set ni [expr {$idx >= [llength $order] ? [llength $order] - 1 : $idx}]
		activate [lindex $order $ni] $g
	}
	session_save   ;# the open-file set changed — record it for resume (D31)
}
# Close any tab (the × button): activate it in its group first so a discard prompt is
# in context and do_close acts on the right group.
proc close_tab {id {g ""}} { activate $id $g ; do_close }

proc cycle {dir} {
	set g $::focus
	set order [gorder $g]
	if {[llength $order] < 2} return
	set i [lsearch -exact $order $::cur]
	activate [lindex $order [expr {($i + $dir) % [llength $order]}]] $g
}

# ---------------------------------------------------------------------------
# Editor split (AGENTS.md D33): create/destroy the second group and move tabs across.
# v1 is at most two groups; ids are the free slot in {0,1} so a collapsed group's slot
# is reused on the next split.
# ---------------------------------------------------------------------------
# The other group (v1: at most two), or "" if `g` is the only one.
proc other_group {g} {
	foreach o $::groups { if {$o ne $g} { return $o } }
	return ""
}

# Which group's pane does widget `w` live under? Walk up from `w` to a group frame
# (.eg<g>) and return its id, or "" if `w` is outside every group. `group_at` layers
# the screen-coordinate lookup on top for drag-and-drop; the widget walk is split out
# so it can be unit-tested without real pointer geometry (split.tcl).
proc group_of_widget {w} {
	while {$w ne ""} {
		foreach g $::groups { if {$w eq [gget $g frame]} { return $g } }
		set w [winfo parent $w]
	}
	return ""
}
proc group_at {X Y} { group_of_widget [winfo containing $X $Y] }

# Tear down group `g`'s widgets and its leftover proxy proc, and drop it from ::grp.
# (Destroying the frame removes the real widget command; the proxy at .eg<g>.t is a
# plain proc, so it must be renamed away or the slot can't be rebuilt on a re-split.)
proc destroy_editor_group {g} {
	set path [gget $g path] ; set w [gw $g]
	set ::tabstrip_w [dict remove $::tabstrip_w $g]  ;# forget the strip's cached width (D57)
	catch {destroy [gget $g frame]}
	catch {rename $path ""}
	catch {rename $w ""}
	dict unset ::grp $g
}

# Bring up an empty second editor group in the free slot, styled and wrap-synced to
# match. Returns its id. Callers give it a buffer (split_editor) or move one in.
proc add_group {} {
	set g [expr {[lsearch -exact $::groups 0] < 0 ? 0 : 1}]
	make_editor_group $g
	lappend ::groups $g
	relayout_groups
	restyle_group $g
	apply_wrap          ;# sync the new group's wrap mode + horizontal scrollbar
	apply_line_numbers  ;# sync the new group's gutter to ::line_numbers
	# The shared RioMode tag already covers the new widget's keys; re-attaching
	# (idempotent by contract, D38) lets the active mode set up its per-group
	# state too — vi's cursor shape and normal/insert state for the new half.
	if {$::editmode_active ne ""} { catch {rio::modes::attach $::editmode_active RioMode} }
	after idle even_split   ;# a new split opens 50/50; later user sash drags are kept
	return $g
}

# Fold group `g` into the other one: its tabs move over (appended), its widgets are
# destroyed, and focus lands on the survivor. Never collapses the sole group.
proc collapse_group {g} {
	set o [other_group $g]
	if {$o eq ""} return
	foreach id [gorder $g] { gset $o order [linsert [gorder $o] end $id] }
	set ::groups [lsearch -all -inline -not -exact $::groups $g]
	destroy_editor_group $g
	relayout_groups
	set ::focus $o
	set ::cur [gcur $o]
	refresh_all
}

# Split the editor: open a second group with a fresh scratch buffer and focus it. A
# no-op if already split. (Use Move Tab to Other Group to send an open file across.)
proc split_editor {} {
	if {[llength $::groups] >= 2} return
	set g [add_group]
	set res [rio_result buffer.new {}]
	if {$res eq ""} { collapse_group $g ; return }
	register_buffer [dict get $res buffer] "" {} $g
	activate [dict get $res buffer] $g
	prefs_save
}

# Unsplit: fold the second group back into the first.
proc unsplit_editor {} {
	if {[llength $::groups] < 2} return
	collapse_group [lindex $::groups end]
	prefs_save
}

# View ▸ Split / Unsplit toggle (Ctrl+\).
proc toggle_split {} {
	if {[llength $::groups] >= 2} { unsplit_editor } else { split_editor }
}

# Move buffer `id` out of group `src` into the other group (creating the split if
# needed) and follow it there. If `src` empties it collapses — so moving the only tab
# is a harmless no-op round-trip, and peeling one off a multi-tab group gives a real
# side-by-side (D33: a buffer lives in exactly one group). `id` need not be src's
# active tab (the context menu can move any tab).
proc move_buffer_to_other {id src} {
	if {[lsearch -exact [gorder $src] $id] < 0} return
	if {[llength $::groups] < 2} { add_group }
	set dst [other_group $src]
	gset $src order [lsearch -all -inline -not -exact [gorder $src] $id]
	gset $dst order [linsert [gorder $dst] end $id]
	if {![llength [gorder $src]]} {
		set ::groups [lsearch -all -inline -not -exact $::groups $src]
		destroy_editor_group $src
		relayout_groups
	} elseif {[gcur $src] eq $id} {
		# the moved buffer was src's active tab — pick a new active for src
		gset $src cur [lindex [gorder $src] 0]
		load_buffer $src
	}
	activate $id $dst
	prefs_save
}

# View ▸ Move Tab to Other Group (Ctrl+]): move the focused group's active buffer.
proc move_tab_other {} {
	if {[gcur $::focus] ne ""} { move_buffer_to_other [gcur $::focus] $::focus }
}

# A protocol-native remote file/folder browser (AGENTS.md D29/D30). In remote mode
# the filesystem of record is the CORE's, but tk_getOpenFile / tk_getSaveFile /
# tk_chooseDirectory browse the CLIENT's disk — wrong for a remote core. So those
# choosers give way to this browser, which walks the REMOTE tree over `fs.list` —
# the very op the docked file pane uses (populate_nav) — point-and-click, not typed.
# An editable Location bar still lets you jump straight to a known path, so it also
# subsumes the old typed-path prompt (remote_path_dialog).
#
#   mode = open -> pick an existing file    -> returns its abs path
#          save -> pick a dir + type a name -> returns dir/name
#          dir  -> pick a directory         -> returns the shown dir
#
# Returns the chosen absolute path, or "" if cancelled.

# The row model for one remote directory: a ".." row (unless at "/"), then dirs,
# then files — each {type abspath display}, already dictionary-sorted by the core.
# Split out from the widget code so the fs.list walk is testable headlessly.
proc rbrowse_rows_for {dir} {
	set resp [rio_call fs.list [dict create path $dir]]
	if {![dict get $resp ok]} {
		return [dict create ok 0 error [dict get $resp error message]]
	}
	set abs [dict get $resp result path]   ;# the core's normalized dir
	set rows {}
	# At a filesystem root there is no parent to offer. Asking whether the dirname is
	# the path itself, rather than testing `$abs ne "/"`, is what makes this right off
	# POSIX: a Windows root is "C:/", whose dirname is itself, so the literal put a
	# "../" row there that navigated straight back to the same directory. $abs is the
	# CORE's normalized path, so this holds for a remote core too.
	if {[file dirname $abs] ne $abs} { lappend rows [list dir [file dirname $abs] "../"] }
	foreach grp {dir file} {
		foreach e [dict get $resp result entries] {
			if {[dict get $e type] ne $grp} continue
			set name [dict get $e name]
			lappend rows [list $grp [file join $abs $name] \
				[expr {$grp eq "dir" ? "$name/" : "  $name"}]]
		}
	}
	return [dict create ok 1 dir $abs rows $rows]
}

# Is $p absolute AS THE CORE SEES IT? `file pathtype` answers with the CLIENT's rules,
# which is wrong the moment the two platforms differ: a Windows client calls the Linux
# core's "/home/jka" *volumerelative*, not absolute — so a remote path typed into the
# browser was treated as relative and joined onto the current directory, and a remote
# seed never opened in its own folder. Judge by shape instead — a leading "/" (POSIX,
# and UNC as "//") or an "X:" drive prefix — which reads correctly for either core from
# either client. Deliberately NOT [file normalize]: on a Windows client that rewrites a
# core path like "/home/jka" to "C:/home/jka".
proc core_path_absolute {p} {
	return [expr {[string match "/*" $p] || [regexp {^[A-Za-z]:[/\\]} $p]}]
}

# Where the browser opens: the seed's directory if it names an absolute path, else
# the open project's root, else the CORE's filesystem root — which the core told us at
# session.hello rather than the GUI assuming "/" (right for a POSIX core, unlistable on
# a Windows one). The Location bar reaches anywhere from there.
proc rbrowse_start {seed} {
	if {$seed ne "" && [core_path_absolute $seed]} {
		return [file dirname $seed]
	}
	set root [dict get [rio_call project.get {}] result root]
	return [expr {$root ne "" ? $root : $::core_fsroot}]
}

# Re-list $dir into the browser: fill the Location bar and the listbox from
# rbrowse_rows_for, dropping files in dir mode. A bad path just beeps (the old
# listing stays), so a mistyped Location can't strand the dialog.
proc rbrowse_go {dir} {
	set info [rbrowse_rows_for $dir]
	# rbrowse_rows_for pumps the event loop (an fs.list round-trip). If the dialog was
	# cancelled meanwhile — Escape, WM close, a slow remote listing the user gave up on
	# — its widgets are gone; bail rather than crash on a stale ".rbrowse.loc".
	if {![winfo exists .rbrowse.loc]} return
	if {![dict get $info ok]} { bell ; return }
	set ::rbrowse_dir [dict get $info dir]
	.rbrowse.loc delete 0 end
	.rbrowse.loc insert end $::rbrowse_dir
	.rbrowse.body.list delete 0 end
	set ::rbrowse_rows {}
	foreach row [dict get $info rows] {
		lassign $row type abs display
		if {$::rbrowse_mode eq "dir" && $type eq "file"} continue
		.rbrowse.body.list insert end $display
		lappend ::rbrowse_rows $row
	}
}

# Double-click / Enter a row: descend into a dir; on a file, choose it (open mode)
# or copy its name into the Name field (save mode).
proc rbrowse_activate {} {
	set sel [.rbrowse.body.list curselection]
	if {$sel eq ""} return
	lassign [lindex $::rbrowse_rows $sel] type abs display
	if {$type eq "dir"} { rbrowse_go $abs ; return }
	switch -- $::rbrowse_mode {
		open { set ::rbrowse_result $abs ; destroy .rbrowse }
		save { .rbrowse.name delete 0 end ; .rbrowse.name insert end [file tail $abs] }
	}
}

# The Choose button: a directory (dir mode), the shown dir + typed Name (save), or
# the selected file (open). An empty Name / no file selection just beeps.
proc rbrowse_choose {} {
	switch -- $::rbrowse_mode {
		dir {
			# Open the HIGHLIGHTED folder if a row is selected — the intuitive "click a folder,
			# press Open" that a bare tk_chooseDirectory denies (it returns only the folder you
			# have entered, not the one clicked). With nothing selected, fall back to the folder
			# currently shown, so you can still open a folder by navigating into it. In dir mode
			# only dirs and the "../" parent are listed, so a selection is always a directory.
			set sel [.rbrowse.body.list curselection]
			if {$sel ne ""} {
				set ::rbrowse_result [lindex [lindex $::rbrowse_rows $sel] 1]
			} else {
				set ::rbrowse_result $::rbrowse_dir
			}
		}
		save {
			set name [string trim [.rbrowse.name get]]
			if {$name eq ""} { bell ; return }
			set ::rbrowse_result [expr {[core_path_absolute $name] \
				? $name : [file join $::rbrowse_dir $name]}]
		}
		open {
			set sel [.rbrowse.body.list curselection]
			if {$sel eq ""} { bell ; return }
			lassign [lindex $::rbrowse_rows $sel] type abs display
			if {$type ne "file"} { bell ; return }
			set ::rbrowse_result $abs
		}
	}
	if {$::rbrowse_result ne ""} { destroy .rbrowse }
}

proc remote_browse_dialog {title mode {seed ""}} {
	set w .rbrowse
	destroy $w
	toplevel $w
	wm title $w $title
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	# Location bar — the current remote dir, editable to jump anywhere.
	label $w.loclbl -anchor w -font RioUIFont -text "Location:" \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	entry $w.loc -font RioUIFont -width 54
	ctx_bind_input $w.loc   ;# (D115)
	bind $w.loc <Return> { rbrowse_go [string trim [.rbrowse.loc get]] }

	# The listing (an auto-hiding scrollbar, like the dock file pane).
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.rbrowse.body.list yview}
	listbox $w.body.list -height 16 -width 54 -activestyle none -exportselection 0 \
		-borderwidth 0 -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] \
		-selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .rbrowse.body.sb .rbrowse.body.list}
	pack $w.body.list -side left -fill both -expand 1

	frame $w.btns -background [dict get $c ui.bg]
	set oklbl [dict get {open Open save {Save here} dir {Choose folder}} $mode]
	button $w.btns.ok     -text $oklbl -font RioUIFont -command rbrowse_choose
	button $w.btns.cancel -text Cancel -font RioUIFont \
		-command {set ::rbrowse_result "" ; destroy .rbrowse}
	pack $w.btns.cancel $w.btns.ok -side right -padx 3

	grid $w.loclbl -row 0 -column 0 -sticky w    -padx 8 -pady {8 0}
	grid $w.loc    -row 1 -column 0 -sticky we   -padx 8
	grid $w.body   -row 2 -column 0 -sticky nsew -padx 8 -pady 4
	set btnrow 3
	if {$mode eq "save"} {
		label $w.namelbl -anchor w -font RioUIFont -text "Name:" \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		entry $w.name -font RioUIFont -width 54
		ctx_bind_input $w.name   ;# (D115)
		$w.name insert end [file tail $seed]
		grid $w.namelbl -row 3 -column 0 -sticky w  -padx 8
		grid $w.name    -row 4 -column 0 -sticky we -padx 8
		set btnrow 5
	}
	grid $w.btns -row $btnrow -column 0 -sticky e -padx 5 -pady {2 8}
	grid rowconfigure $w 2 -weight 1
	grid columnconfigure $w 0 -weight 1

	bind $w.body.list <Double-Button-1> rbrowse_activate
	bind $w.body.list <Return>          rbrowse_activate
	bind $w <Escape> {set ::rbrowse_result "" ; destroy .rbrowse}

	set ::rbrowse_mode   $mode
	set ::rbrowse_result ""
	set ::rbrowse_rows   {}
	rbrowse_go [rbrowse_start $seed]

	# The first rbrowse_go may have been cancelled mid-flight (an Escape during its
	# fs.list), taking the dialog with it — only grab/focus/wait if it's still here.
	if {[winfo exists $w]} {
		catch {grab $w}
		focus $w.body.list
		tkwait window $w
	}
	return $::rbrowse_result
}

# --- dialog wrappers ---------------------------------------------------------
# Each picks a path then calls a do_* action. The native chooser browses the local
# disk; when the core is remote (its FS isn't ours) it gives way to the remote file
# browser (remote_browse_dialog), which walks the server's tree over fs.list.
proc open_dialog {} {
	if {$::core_remote} {
		# The remote browser is a single-select tree (fs.list, one pick); open just it.
		set p [remote_browse_dialog "Open file (remote)" open]
		if {$p ne ""} { do_open $p }
		return
	}
	# -multiple 1 lets the native chooser Ctrl/Shift-select several files; the result
	# is then a LIST of paths (empty on cancel). Open each in order — do_open dedups
	# and activates, so the last selected file ends up focused.
	foreach p [tk_getOpenFile -title "Open file" -multiple 1] {
		if {$p ne ""} { do_open $p }
	}
}
proc save_as_dialog {} {
	if {$::core_remote} {
		set p [remote_browse_dialog "Save as (remote)" save [bufget $::cur path]]
	} else {
		set p [tk_getSaveFile -title "Save as"]
	}
	if {$p eq ""} { return 0 }
	return [do_save_as $p]
}
# Returns 1 if it is safe to close the active buffer. On a modified buffer we ask
# to save (Yes), not to discard: Yes saves then closes (abort if the save fails),
# No closes without saving, Cancel keeps the buffer open.
proc maybe_discard {} {
	if {![bufget $::cur modified]} { return 1 }
	switch -- [tk_messageBox -icon question -type yesnocancel -default yes -title rio \
			-message "[tab_name $::cur] has unsaved changes. Save before closing?"] {
		yes    { return [do_save] }
		no     { return 1 }
		cancel { return 0 }
	}
}
proc do_quit {} {
	prefs_save      ;# persist view state + the workspace before we go (D31)
	session_save
	foreach id [dict keys $::buffers] {
		if {[bufget $id modified]} {
			activate $id
			if {![maybe_discard]} return
		}
	}
	# Close the channel so a spawned child core sees EOF on stdin and exits with us
	# (a daemon socket just drops the connection); then go.
	catch {close $::core_chan}
	exit 0
}

# ---------------------------------------------------------------------------
# Connect to a remote (listening) rio-core over a socket — the daemon mode of the
# one channel transport (AGENTS.md D30). The core there is loopback-bound, so this
# is normally the local end of an `ssh -L` tunnel. Reached from File ▸ Connect to
# Remote Core…. By default THIS window rewires to the remote core; ticking "Open in
# a new window" launches a second rio-gui instead, leaving this session untouched.
# ---------------------------------------------------------------------------

# Validate a "host:port" string. Returns {host port}, or "" if malformed (same rule
# the --connect startup path uses).
proc parse_endpoint {hp} {
	lassign [split $hp :] host port
	if {$host eq "" || ![string is integer -strict $port]} { return "" }
	return [list $host $port]
}

# The endpoint prompt: a host:port entry + an "open in a new window" checkbox.
# Returns {hostport newwin}, or "" if cancelled. A themed modal like the others.
proc connect_remote_dialog {} {
	set w .connd
	destroy $w
	toplevel $w
	wm title $w "Connect to remote core"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.prompt -anchor w -font RioUIFont -text "Remote core address (host:port):" \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	entry $w.e -width 40 -font RioUIFont
	ctx_bind_input $w.e   ;# (D115)
	$w.e insert end [expr {$::last_connect ne "" ? $::last_connect : "127.0.0.1:7711"}]
	set ::connd_new 0
	checkbutton $w.new -text "Open in a new window (keep this session)" \
		-variable ::connd_new -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -selectcolor [dict get $c ui.bg]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.ok     -text Connect -font RioUIFont \
		-command {set ::connd_result [list [.connd.e get] $::connd_new] ; destroy .connd}
	button $w.btns.cancel -text Cancel  -font RioUIFont \
		-command {set ::connd_result "" ; destroy .connd}
	pack $w.btns.cancel $w.btns.ok -side right -padx 3
	grid $w.prompt -row 0 -column 0 -sticky we -padx 8 -pady {8 2}
	grid $w.e      -row 1 -column 0 -sticky we -padx 8
	grid $w.new    -row 2 -column 0 -sticky w  -padx 8 -pady {4 0}
	grid $w.btns   -row 3 -column 0 -sticky e  -padx 5 -pady {2 8}
	bind $w.e <Return> {set ::connd_result [list [.connd.e get] $::connd_new] ; destroy .connd}
	bind $w <Escape>   {set ::connd_result "" ; destroy .connd}
	set ::connd_result ""
	catch {grab $w}
	focus $w.e
	tkwait window $w
	if {$::connd_result eq ""} return
	lassign $::connd_result hp newwin
	if {[parse_endpoint $hp] eq ""} {
		report_error "Expected host:port, e.g. 127.0.0.1:7711 — got '$hp'." bad_request
		return
	}
	if {$newwin} { spawn_remote_window $hp } else { reconnect_remote $hp }
}

# Editor-font picker (D56). A themed modal like the others: a family list (every
# monospaced-or-not family the system reports, de-duplicated), a size spinner, and a
# live preview in the chosen font. OK pins the choice as the override; "Use Theme
# Font" clears it so the document view follows the theme again. Seeded from the
# current effective font (override if set, else the theme's).
proc editor_font_preview_update {w} {
	if {![winfo exists $w]} return
	set sel [$w.body.fam.list curselection]
	if {$sel ne ""} { set ::efont_family [$w.body.fam.list get $sel] }
	set sz $::efont_size
	if {![string is integer -strict $sz] || $sz < 5 || $sz > 72} { set sz [editor_font_size_now] }
	catch {$w.preview configure -font [list $::efont_family $sz]}
}

proc editor_font_dialog {} {
	set w .efont
	destroy $w
	toplevel $w
	wm title $w "Editor Font"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	set bg [dict get $c ui.bg] ; set fg [dict get $c ui.fg]
	$w configure -background $bg
	# The family to pre-select: the user's override if any, else the CONCRETE family the
	# editor is wearing. The theme records a logical alias (`monospace`) that `font
	# families` never lists, so matching that against the listbox found nothing and left
	# the current font unmarked — `font actual` resolves the alias to the real family.
	set ::efont_family [expr {$::editor_font_family ne "" \
		? $::editor_font_family : [font actual RioEditorFont -family]}]
	set ::efont_size   [editor_font_size_now]

	frame $w.body -background $bg
	frame $w.body.fam -background $bg
	label $w.body.fam.l -text "Family" -anchor w -font RioUIFont -background $bg -foreground $fg
	listbox $w.body.fam.list -height 12 -width 30 -font RioUIFont -exportselection 0 \
		-activestyle none -yscrollcommand [list $w.body.fam.sb set]
	scrollbar $w.body.fam.sb -orient vertical -command [list $w.body.fam.list yview]
	grid $w.body.fam.l    -row 0 -column 0 -columnspan 2 -sticky w
	grid $w.body.fam.list -row 1 -column 0 -sticky nsew
	grid $w.body.fam.sb   -row 1 -column 1 -sticky ns
	set fams [lsort -unique [font families]]
	foreach fam $fams { $w.body.fam.list insert end $fam }
	set idx [lsearch -exact $fams $::efont_family]
	if {$idx < 0} { set idx [lsearch -nocase $fams $::efont_family] }
	if {$idx >= 0} { $w.body.fam.list selection set $idx ; $w.body.fam.list see $idx }

	frame $w.body.sz -background $bg
	label $w.body.sz.l -text "Size" -anchor w -font RioUIFont -background $bg -foreground $fg
	spinbox $w.body.sz.v -from 5 -to 72 -width 5 -font RioUIFont -textvariable ::efont_size \
		-command [list editor_font_preview_update $w]
	grid $w.body.sz.l -row 0 -column 0 -sticky w
	grid $w.body.sz.v -row 1 -column 0 -sticky w
	grid $w.body.fam -row 0 -column 0 -sticky nsew -padx {8 6} -pady 8
	grid $w.body.sz  -row 0 -column 1 -sticky nw   -padx {0 8} -pady 8

	label $w.preview -text "AaBbCc 0123  — the quick brown fox" -anchor w \
		-relief sunken -borderwidth 1 -padx 6 -pady 6 \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
	frame $w.btns -background $bg
	button $w.btns.ok    -text OK     -font RioUIFont -command [list editor_font_apply_dialog $w]
	button $w.btns.theme -text "Use Theme Font" -font RioUIFont -command [list editor_font_reset_dialog $w]
	button $w.btns.cancel -text Cancel -font RioUIFont -command [list destroy $w]
	pack $w.btns.cancel $w.btns.ok -side right -padx 3
	pack $w.btns.theme -side left -padx 3

	grid $w.body    -row 0 -column 0 -sticky nsew
	grid $w.preview -row 1 -column 0 -sticky ew -padx 8 -pady {0 6}
	grid $w.btns    -row 2 -column 0 -sticky ew -padx 5 -pady {0 8}

	bind $w.body.fam.list <<ListboxSelect>> [list editor_font_preview_update $w]
	bind $w.body.sz.v <KeyRelease> [list editor_font_preview_update $w]
	bind $w <Escape> [list destroy $w]
	editor_font_preview_update $w
	catch {grab $w}
	focus $w.body.fam.list
}

# OK: pin the picked family and size as the persisted override, apply live.
proc editor_font_apply_dialog {w} {
	set sel [$w.body.fam.list curselection]
	if {$sel ne ""} { set ::editor_font_family [$w.body.fam.list get $sel] }
	set sz $::efont_size
	if {[string is integer -strict $sz] && $sz >= 5 && $sz <= 72} { set ::editor_font_size $sz }
	destroy $w
	apply_editor_font
	prefs_save
}

# "Use Theme Font": clear both overrides so the document view follows the theme again.
proc editor_font_reset_dialog {w} {
	set ::editor_font_family ""
	set ::editor_font_size 0
	destroy $w
	apply_editor_font
	prefs_save
}

# Launch a second rio-gui already attached to the remote core (reuses the --connect
# startup path). This session is left running and untouched.
proc spawn_remote_window {hp} {
	set ::last_connect $hp
	if {[catch {exec [info nameofexecutable] $::rio_self --connect $hp &} err]} {
		report_error "Could not launch a new window: $err"
	}
}

# Rewire THIS window to a remote core. Order is chosen for safety: open the new
# socket FIRST, then save-check the outgoing tabs — only once both succeed do we
# drop the current (local) core and swap. A failure or a cancel at either earlier
# step leaves the existing session fully intact.
proc reconnect_remote {hp} {
	lassign [parse_endpoint $hp] host port
	# 1. Open the new channel first, so a failed connect never costs us the core.
	if {[catch {socket $host $port} newchan]} {
		report_error "Cannot reach a rio core at $hp.\nIs one listening there — and, if it's remote, is the SSH tunnel up?" disconnected
		return
	}
	# 2. Offer to save unsaved work on the outgoing session; Cancel aborts cleanly.
	foreach id [dict keys $::buffers] {
		if {[bufget $id modified]} {
			activate $id
			if {![maybe_discard]} { catch {close $newchan} ; return }
		}
	}
	# 3. Commit: drop the old channel (a spawned child core sees EOF and exits), swap.
	catch {fileevent $::core_chan readable {}}
	catch {close $::core_chan}
	set ::core_chan $newchan
	set ::core_remote 1
	set ::core_endpoint $hp
	set ::last_connect $hp
	fconfigure $::core_chan -buffering line -blocking 0 -translation lf -encoding utf-8
	fileevent $::core_chan readable core_reader
	watch_start ;# a fresh socket link — re-arm the stale-link watchdog (D37)
	reset_session_state
}

# Reset all per-session view state and rebuild from whatever core ::core_chan now
# points at (used after an in-place reconnect). Mirrors the startup tail: the new
# core owns its own buffers, project, and conversation, so we forget ours and adopt.
proc reset_session_state {} {
	if {$::compare_shown} { compare_close }
	catch {pack forget .chat.approve}
	set ::pending_turn ""
	set ::chat_turn_open 0
	# Collapse any split back to a single group — the new core is a fresh session — then
	# forget the old buffers/tabs and blank the surviving group; the new core has its own.
	while {[llength $::groups] > 1} {
		set g [lindex $::groups end]
		set ::groups [lrange $::groups 0 end-1]
		destroy_editor_group $g
	}
	relayout_groups
	set ::focus [lindex $::groups 0]
	set ::buffers {}
	gset $::focus order {} ; gset $::focus cur ""
	[gw $::focus] delete 1.0 end
	set ::cur ""
	# Project/panes: the new core starts with no folder open unless it reports one.
	set ::nav_root ""
	set ::nav_expanded [dict create]
	rl_reset .pfiles.well.body
	rl_reset .pgit.well.body
	# A different core means a fresh conversation — clear the transcript.
	.chat.log configure -state normal
	.chat.log delete 1.0 end
	.chat.log configure -state disabled
	# Rebuild exactly as at startup. hello_core also gates liveness (bounded): if the
	# new core is silent (a stale tunnel), it has already told the user — stop here
	# rather than hang the next op, leaving a blank-but-responsive session to retry.
	if {![hello_core]} return    ;# a daemon can be any age — check protocol + reachability
	adopt_initial_buffers
	show_pane $::dock_pane
	apply_wrap
	adopt_agent_status           ;# take the new core's provider/auto-accept, don't reset it
	refresh_all
}

# ---------------------------------------------------------------------------
# Modified flag, title, status, and the tab bar.
# ---------------------------------------------------------------------------
proc mark_modified {m} {
	if {$::cur eq ""} return
	set was [bufget $::cur modified]
	bufset $::cur modified $m
	if {$m != $was} { refresh_tabs ; refresh_title }
	refresh_status
}
proc clear_modified {} { bufset $::cur modified 0 ; refresh_all }

# The bare display name of a buffer — no modified marker. The unsaved-changes
# dot (●, D27) is a rendering concern added by the tab strip and the title only;
# keeping it out of here means the compare picker and the save prompt show a
# clean filename.
proc tab_name {id} {
	set p [bufget $id path]
	return [expr {$p eq "" ? "untitled" : [file tail $p]}]
}
# The ● (U+25CF) unsaved marker, or "" — appended after the name in the tab and
# the window title (D27).
proc tab_dot {id} {
	return [expr {[bufget $id modified] ? " ●" : ""}]
}
proc refresh_all   {} { refresh_tabs ; refresh_title ; refresh_status }
proc refresh_title {} {
	set suffix [expr {$::core_remote ? " — $::core_endpoint" : ""}]
	wm title . "rio — [tab_name $::cur][tab_dot $::cur]$suffix"
}
proc refresh_status {} {
	set p    [bufget $::cur path]
	set name [expr {$p eq "" ? "untitled" : $p}]
	set meta [bufget $::cur meta]
	set enc  [expr {[dict exists $meta encoding] ? [dict get $meta encoding] : "utf-8"}]
	set eol  [expr {[dict exists $meta eol] ? [dict get $meta eol] : "lf"}]
	set lang [expr {[gget $::focus hl_lang] ne "" ? [gget $::focus hl_lang] : "plain text"}]
	set mode ""   ;# the editing mode's segment (vi's "-- INSERT --"), when it has one
	if {$::editmode_status ne ""} { set mode "      $::editmode_status" }
	.status configure -text [format "%s      %s  %s%s      %s      %s      %d buffer(s)%s" \
		$name $enc $eol [expr {[bufget $::cur modified] ? {      modified} : {}}] \
		$lang [cursor_status] [dict size $::buffers] $mode]
	# The focused group's caret may have moved by a route with no KeyRelease (open /
	# tab switch / goto / reload all land here via refresh_all) — re-band it too.
	if {$::focus ne "" && [dict exists $::grp $::focus]} { curline_update $::focus }
}
# The compact cursor-position segment for the status bar: "Ln 12, Col 5" for the
# focused group's insert mark. Tk indexes columns from 0, so Col is char+1 to match
# the 1-based feel VSCode/editors show. Guarded so an early or focus-less call is a
# harmless "" rather than an error.
proc cursor_status {} {
	if {$::focus eq "" || ![dict exists $::grp $::focus]} { return "" }
	if {[catch {[fgw] index insert} idx]} { return "" }
	lassign [split $idx .] line char
	return [format "Ln %d, Col %d" $line [expr {$char + 1}]]
}
# Put text on the clipboard (a no-op for empty text). The one clipboard idiom the
# context menus share.
proc rio_copy_clip {text} {
	if {$text eq ""} return
	clipboard clear
	clipboard append $text
}
# Copy a tab's file path to the clipboard (context menu). A no-op for an untitled
# buffer, which has no path — the menu disables the item in that case.
proc tab_copy_path {id} {
	rio_copy_clip [bufget $id path]
}

# Right-click a tab handle: a context menu of actions ABOUT THIS TAB (id, g) — nothing
# about other tabs or regions (D33; the UI-design bar: a tab's menu stays scoped to
# that tab). Rebuilt on each popup so Copy Path reflects the current state. "Move to
# Other Group" is one label in both states: with one group the move creates the other
# group, so the label still describes what happens — no context-sensitive wording.
proc tab_context_menu {g id X Y} {
	catch {destroy .tabmenu}
	menu .tabmenu -tearoff 0
	.tabmenu add command -label "Move to Other Group" -command [list move_buffer_to_other $id $g]
	if {[bufget $id path] ne ""} {
		.tabmenu add command -label "Copy Path" -command [list tab_copy_path $id]
	} else {
		.tabmenu add command -label "Copy Path" -state disabled
	}
	.tabmenu add separator
	.tabmenu add command -label "Close" -command [list close_tab $id $g]
	tk_popup .tabmenu $X $Y
}

# The tab strips (D33): each group draws its OWN tabs into its own strip
# (.eg<g>.tabs). A tab's group is where it lives, so clicking it activates that buffer
# IN that group and focuses the group. The focused group's active tab is emphasised
# with the accent colour, so which pane has focus is visible at a glance. Right-click
# a tab for a context menu (move to the other group / close).
# Drag a tab (AGENTS.md D33 follow-on) — a second input gesture onto the move/reorder
# paths. Press a tab and drag it: onto the OTHER group's pane it moves across (the same
# path as the context menu's "Move to Other Group"); back onto its OWN pane it reorders,
# dropping into the slot under the pointer. Below a ~5px threshold it stays a plain click
# (activate). Tk's implicit pointer grab keeps motion/release flowing to the origin tab
# while the button is down, so `winfo containing` sees across both panes. Feedback while
# dragging: the held tab gets a pressed accent look (mark_dragged) and the cursor becomes
# a hand, and a cross-group drag also tints the OTHER group's tab strip.
proc tab_drag_start {id g X Y} {
	set ::tabdrag [dict create id $id g $g x $X y $Y active 0 tint ""]
}
proc tab_drag_motion {X Y} {
	if {![info exists ::tabdrag]} return
	if {![dict get $::tabdrag active]} {
		if {abs($X - [dict get $::tabdrag x]) < 5 && abs($Y - [dict get $::tabdrag y]) < 5} return
		dict set ::tabdrag active 1
		. configure -cursor hand2
		mark_dragged [dict get $::tabdrag g] [dict get $::tabdrag id]
	}
	set src  [dict get $::tabdrag g]
	set over [group_at $X $Y]
	set want [expr {($over ne "" && $over ne $src) ? $over : ""}]
	set now  [dict get $::tabdrag tint]
	if {$want ne $now} {
		if {$now  ne ""} { tint_strip $now  0 }
		if {$want ne ""} { tint_strip $want 1 }
		dict set ::tabdrag tint $want
	}
}
proc tab_drag_end {id g X Y} {
	if {![info exists ::tabdrag]} { activate $id $g ; return }
	set active [dict get $::tabdrag active]
	set tint   [dict get $::tabdrag tint]
	unset ::tabdrag
	. configure -cursor ""
	if {$tint ne ""} { tint_strip $tint 0 }
	if {!$active} { activate $id $g ; return }   ;# a click, not a drag
	set dst [group_at $X $Y]
	if {$dst eq $g} {
		reorder_tab $g $id $X                    ;# dropped on its own pane -> reorder
	} elseif {$dst ne ""} {
		move_buffer_to_other $id $g              ;# dropped on the other pane -> move across
	}
	refresh_tabs                                 ;# clear the drag mark (no-op if a drop already repainted)
}
# Give the dragged tab a clear "held" look — a pressed (sunken) handle tinted with the
# accent — so an in-group reorder has feedback too (a between-groups drag also tints the
# target strip). One-way styling: the refresh_tabs at drag-end repaints it back to normal.
proc mark_dragged {g id} {
	set w [gget $g tabs].b$id
	if {![winfo exists $w]} return
	set c $::theme_colors
	set a [dict get $c accent] ; set fg [dict get $c tab.active.bg]
	$w configure -relief sunken -background $a
	foreach sub [list $w.l $w.x] { catch {$sub configure -background $a -foreground $fg} }
}
# Highlight (`on`=1) or restore (`on`=0) group `g`'s tab strip as a drop target.
proc tint_strip {g on} {
	set c $::theme_colors
	set bg [expr {$on ? [dict get $c accent] : [dict get $c tab.bar.bg]}]
	catch {[gget $g tabs] configure -background $bg}
}

# Reorder tab `id` within its own group `g` to the slot under pointer-x `X`. The new
# index is "how many OTHER tabs have their centre left of X" — drop-where-the-cursor-is.
# `tab_reorder` does the pure list splice (unit-tested: no geometry); this reads the live
# tab centres and applies. Order is a view concern, so only the strip repaints — the
# active buffer and its text are untouched.
proc reorder_tab {g id X} {
	set centers [dict create]
	foreach t [gorder $g] {
		set w [gget $g tabs].b$t
		if {[winfo exists $w]} { dict set centers $t [expr {[winfo rootx $w] + [winfo width $w] / 2}] }
	}
	set new [tab_reorder [gorder $g] $id $centers $X]
	if {$new eq [gorder $g]} return              ;# dropped in place
	gset $g order $new
	refresh_tabs
	prefs_save
}
# Pure splice: move `id` within `order` to the slot implied by `X` against tab `centers`
# (a dict id->centre-x). Insertion index = count of OTHER tabs whose centre is left of X.
proc tab_reorder {order id centers X} {
	set k 0
	foreach t $order {
		if {$t eq $id} continue
		if {[dict exists $centers $t] && $X > [dict get $centers $t]} { incr k }
	}
	return [linsert [lsearch -all -inline -not -exact $order $id] $k $id]
}

proc refresh_tabs {} {
	set c $::theme_colors
	set fg [dict get $c tab.fg]
	foreach g $::groups {
		set strip [gget $g tabs]
		$strip configure -background [dict get $c tab.bar.bg]
		foreach w [winfo children $strip] { destroy $w }
		set focused [expr {$g eq $::focus}]
		foreach id [gorder $g] {
			set active [expr {$id eq [gcur $g]}]
			set bg [expr {$active ? [dict get $c tab.active.bg] : [dict get $c tab.inactive.bg]}]
			set tfg [expr {$active && $focused ? [dict get $c accent] : $fg}]
			set f [frame $strip.b$id -background $bg -borderwidth 1 \
				-relief [expr {$active ? "raised" : "flat"}]]
			label $f.l -text "[tab_name $id][tab_dot $id]" -background $bg -foreground $tfg \
				-font RioUIFont -padx 6 -pady 1
			label $f.x -text "×" -background $bg -foreground $fg \
				-font RioUIFont -padx 3
			# Press/drag/release on the handle body: a plain click activates, a
			# drag past the threshold moves the tab to the group under the pointer.
			foreach w [list $f $f.l] {
				bind $w <ButtonPress-1>   [list tab_drag_start $id $g %X %Y]
				bind $w <B1-Motion>       [list tab_drag_motion %X %Y]
				bind $w <ButtonRelease-1> [list tab_drag_end $id $g %X %Y]
			}
			bind $f.x <Button-1> [list close_tab $id $g]
			# Right-click anywhere on the handle (frame, label, ×) for the context menu.
			foreach w [list $f $f.l $f.x] {
				bind $w <Button-3> [list tab_context_menu $g $id %X %Y]
			}
			pack $f.l -side left ; pack $f.x -side right
			# The handle FRAME is left unmanaged here — tabstrip_layout decides which
			# tabs are placed, and how (one scrolled row, or wrapped onto many).
		}
		tabstrip_layout $g
	}
}

# ---------------------------------------------------------------------------
# Tab-strip overflow layout (AGENTS.md D57). refresh_tabs builds each group's tab
# HANDLES (the b<id> frames) but leaves them unmanaged; this proc places them, in one
# of two modes the user picks (::tab_layout). It also runs on the strip's <Configure>
# so a window resize re-flows the tabs. Widths are measured analytically from the tab
# text (font measure), not from winfo reqwidth, so the layout is correct synchronously
# — before the handles have been mapped — which keeps it testable without an event loop.
# ---------------------------------------------------------------------------

# The on-screen width of tab handle <id>, mirroring refresh_tabs' construction: frame
# border (bd 1 → 2) + the name label (RioUIFont, -padx 6 → +12) + the × label (-padx 3
# → +6) + the tab's own pack -padx 1 (→ +2). Kept in one place so a padding change here
# and in refresh_tabs stay in step.
proc tab_pixwidth {id} {
	return [expr {[font measure RioUIFont "[tab_name $id][tab_dot $id]"] \
		+ [font measure RioUIFont "×"] + 22}]
}

# The last tab index that still fits when the visible window starts at `off` and has
# `avail` pixels. The first tab (at `off`) always counts, so at least one tab shows even
# in a sliver of space — otherwise a very narrow group could strand every tab.
proc tabstrip_fit_last {ids off avail} {
	set x 0 ; set last $off
	for {set i $off} {$i < [llength $ids]} {incr i} {
		set need [tab_pixwidth [lindex $ids $i]]
		if {$i > $off && $x + $need > $avail} break
		incr x $need ; set last $i
	}
	return $last
}

# Create (once) group `g`'s two scroll arrows in its strip and (re)colour them to the
# theme. refresh_tabs destroys the strip's children each pass, so these are recreated
# on demand; a <Configure>-only layout finds the ones the last refresh_tabs left.
proc tabstrip_ensure_arrows {strip g} {
	set c $::theme_colors
	foreach {name dir glyph} [list al -1 "◂" ar 1 "▸"] {
		set w $strip.$name
		if {![winfo exists $w]} {
			label $w -text $glyph -font RioUIFont -padx 3 -cursor hand2
			bind $w <Button-1> [list tab_scroll $g $dir]
		}
		catch {$w configure \
			-background [dict get $c tab.bar.bg] -foreground [dict get $c tab.fg]}
	}
}

# Create and pack one row container for `multi` mode, spanning the strip width and themed
# to the bar background. The tab handles pack into it left-to-right (`pack -in`), so each
# row huddles at natural widths; tabstrip_layout destroys these `r<n>` frames each pass.
# `pack -in` places the handles geometrically but does NOT reparent them — they stay
# children of the strip, i.e. SIBLINGS of this frame. This frame is created after them, so
# it would stack on top and its background would paint over the tabs (an empty bar); lower
# it beneath them so the handles show. (Re-lowered every pass, since we recreate it.)
proc tabstrip_row {strip row} {
	set w $strip.r$row
	frame $w -background [dict get $::theme_colors tab.bar.bg]
	pack $w -side top -anchor w -fill x
	lower $w
	return $w
}

# Place group `g`'s tab handles. In `multi` mode they wrap across packed per-row frames; in
# `scroll` mode they sit on one row (pack), and when they overflow the strip's width the
# ◂ ▸ arrows appear and only a window of them is shown. `reveal` (default on) pulls that
# window so the active tab is visible — wanted when the active tab changed, suppressed
# by tab_scroll so the arrows can page PAST the active tab to reach a hidden one.
proc tabstrip_layout {g {reveal 1}} {
	set strip [gget $g tabs]
	if {$strip eq "" || ![winfo exists $strip]} return
	tabstrip_ensure_arrows $strip $g
	set ids {}
	foreach id [gorder $g] { if {[winfo exists $strip.b$id]} { lappend ids $id } }
	# Unmanage the arrows and tab handles (they're rebuilt/re-placed below); DESTROY any
	# leftover row containers from a previous multi-mode pass so a re-flow or a mode switch
	# leaves no empty rows behind. `-in` never reparents, so a tab handle survives its
	# row-frame's destruction (it stays a child of the strip) — see the multi branch.
	foreach w [winfo children $strip] {
		if {[string match $strip.r* $w]} { destroy $w ; continue }
		catch {pack forget $w} ; catch {grid forget $w}
	}
	if {[llength $ids] == 0} { gset $g taboff 0 ; return }
	set avail [winfo width $strip]

	if {$::tab_layout eq "multi"} {
		# Flow the handles into one packed row-frame per visual row. Pass 1 assigns tabs to
		# rows, wrapping BEFORE a tab would overrun `avail` (so a row never clips) and keeping
		# at least one tab per row. Not yet realized (width 1 during boot): one row; the
		# <Configure> that arrives with the real width re-flows it.
		set A [expr {$avail <= 1 ? 1000000 : $avail}]
		set rows {} ; set cur {} ; set x 0
		foreach id $ids {
			set need [tab_pixwidth $id]
			if {[llength $cur] && $x + $need > $A} { lappend rows $cur ; set cur {} ; set x 0 }
			lappend cur $id ; incr x $need
		}
		if {[llength $cur]} { lappend rows $cur }
		# Pass 2 places them, JUSTIFIED like a paragraph: every row but the last expands its
		# tabs to fill the strip width (closing the ragged right gap); the last row stays
		# natural/left-aligned (a justified paragraph's last line isn't stretched). pack
		# divides the leftover pixels equally among a row's tabs, and -fill x grows each.
		set nrows [llength $rows]
		for {set r 0} {$r < $nrows} {incr r} {
			set rf [tabstrip_row $strip $r]
			set justify [expr {$r < $nrows - 1}]
			foreach id [lindex $rows $r] {
				if {$justify} {
					pack $strip.b$id -in $rf -side left -padx 1 -pady 1 -expand 1 -fill x
				} else {
					pack $strip.b$id -in $rf -side left -padx 1 -pady 1
				}
			}
		}
		gset $g taboff 0
		return
	}

	# scroll mode: everything on one line.
	set n [llength $ids]
	set total 0 ; foreach id $ids { incr total [tab_pixwidth $id] }
	if {$avail <= 1 || $total <= $avail} {
		# Fits (or not realized yet): show them all, no arrows, window reset to the start.
		gset $g taboff 0
		foreach id $ids { pack $strip.b$id -side left -padx 1 -pady 1 }
		return
	}
	# Overflow: reserve room for the two arrows, then show a scrolled window of tabs.
	set aw [expr {[font measure RioUIFont "▸"] + 8}]
	set availtabs [expr {$avail - 2*$aw - 4}]
	if {$availtabs < 1} { set availtabs 1 }
	set off [gget $g taboff]
	if {$off < 0} { set off 0 } elseif {$off > $n - 1} { set off [expr {$n - 1}] }
	if {$reveal} {
		set ai [lsearch -exact $ids [gcur $g]]
		if {$ai >= 0 && $ai < $off} { set off $ai }
		while {$ai >= 0 && $off < $n - 1} {
			if {$ai <= [tabstrip_fit_last $ids $off $availtabs]} break
			incr off
		}
	}
	gset $g taboff $off
	set last [tabstrip_fit_last $ids $off $availtabs]
	pack $strip.al -side left  -padx 1
	pack $strip.ar -side right -padx 1
	for {set i $off} {$i <= $last} {incr i} {
		pack $strip.b[lindex $ids $i] -side left -padx 1 -pady 1
	}
}

# Page the visible tab window of group `g` by `dir` (-1 left, +1 right). Bound to the
# arrows; suppresses reveal so paging can move past the active tab to a hidden one.
proc tab_scroll {g dir} {
	set n [llength [gorder $g]]
	set off [expr {[gget $g taboff] + $dir}]
	if {$off < 0} { set off 0 } elseif {$off > $n - 1} { set off [expr {$n - 1}] }
	gset $g taboff $off
	tabstrip_layout $g 0
}

# A group's strip changed size (window resize, dock drag): re-flow, but only on an
# actual WIDTH change — multi-mode alters the strip's height as rows come and go, and
# reacting to that would loop. reveal keeps the active tab in view after a resize.
proc tabstrip_on_configure {g} {
	set strip [gget $g tabs]
	if {$strip eq "" || ![winfo exists $strip]} return
	set w [winfo width $strip]
	if {[dict exists $::tabstrip_w $g] && [dict get $::tabstrip_w $g] == $w} return
	dict set ::tabstrip_w $g $w
	tabstrip_layout $g 1
}

# The former top-level Tabs menu (a -postcommand cascade listing every open buffer) was
# retired in D74: reaching a buffer by name is now View ▸ Switch to Tab…, which opens the
# bounded buffer-picker dialog (buffer_pick_rows / buffer_pick_dialog, near compare_open).
# A dialog can't outgrow the screen the way that cascade could on X11, and it shows a path
# hint so same-named tabs are distinguishable.

# The View menu's multi-line toggle changed ::tab_layout: re-flow every group and persist.
proc tab_layout_apply {} {
	foreach g $::groups { tabstrip_layout $g }
	prefs_save
}

# ---------------------------------------------------------------------------
# Theme applier (AGENTS.md D24). The core serves the theme as a role table
# (theme.get); here we map roles onto Tk. NAMED fonts are referenced by name by
# every widget, so reconfiguring one updates them all live; explicit per-widget
# config makes a colour switch live too (the option DB only reaches widgets
# created afterwards). Keeping this Tk mapping here is what lets theme files stay
# dumb data.
# ---------------------------------------------------------------------------
set ::theme_colors {} ;# active colour roles, consulted by refresh_tabs

# Editor font override (D56). RioEditorFont is the theme's named font; the user may
# override its family and/or size (a picked font, or a zoom step). We overlay the
# override onto the theme's own values (editor_theme_*, recorded by apply_theme) and
# reconfigure the one named font — every editor widget references it by name, so the
# change is live everywhere at once. Then repaint the per-group chrome whose geometry
# tracks the font: the gutter width/numbers and the wrap-indent margins both scale
# with the glyph width. A no-op before the first apply_theme created the font.
proc apply_editor_font {} {
	if {[lsearch -exact [font names] RioEditorFont] < 0} return
	set fam [expr {$::editor_font_family ne "" ? $::editor_font_family : $::editor_theme_family}]
	set sz  [expr {$::editor_font_size  > 0  ? $::editor_font_size   : $::editor_theme_size}]
	font configure RioEditorFont -family $fam -size $sz
	foreach g $::groups {
		if {![winfo exists [gget $g path]]} continue
		wrapind_refont [gw $g]
		gutter_redraw $g
	}
}

# The current effective editor size in points — the override if set, else the theme's.
proc editor_font_size_now {} {
	return [expr {$::editor_font_size > 0 ? $::editor_font_size : $::editor_theme_size}]
}

# Zoom the document view by `delta` points (Ctrl+scroll, Ctrl+ +/-). This pins an
# ABSOLUTE size override, clamped to a sane range, so the choice survives a theme
# switch — the user's explicit zoom outranks the theme until they reset it (Ctrl+0).
proc editor_zoom {delta} {
	set sz [expr {[editor_font_size_now] + $delta}]
	if {$sz < 5}  { set sz 5 }
	if {$sz > 72} { set sz 72 }
	if {$sz == [editor_font_size_now] && $::editor_font_size > 0} return
	set ::editor_font_size $sz
	apply_editor_font
	prefs_save
}

# Drop the size override and fall back to the active theme's editor size (Ctrl+0). The
# family override, if any, is left in place — reset zoom means size, not font choice.
proc editor_zoom_reset {} {
	if {$::editor_font_size == 0} return
	set ::editor_font_size 0
	apply_editor_font
	prefs_save
}

proc ensure_fonts {fonts} {
	dict for {name spec} $fonts {
		set opts [list -family [dict get $spec family] -size [dict get $spec size]]
		if {[lsearch -exact [font names] $name] >= 0} {
			font configure $name {*}$opts
		} else {
			font create $name {*}$opts
		}
	}
}

# Apply the active theme's colours/fonts to one editor group: its text surface,
# scrollbar-corner frame, tab strip, and the D32 syntax tags. Shared by apply_theme
# (all groups on a theme switch) and add_group (a freshly-split group). Reads the
# role table from ::theme_colors, which apply_theme sets before calling this.
proc restyle_group {g} {
	set c $::theme_colors
	set t [gw $g]
	$t configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor] \
		-selectbackground [dict get $c editor.selection]
	wrapind_refont $t   ;# the font's column width may have moved — keep margins in step
	[gget $g frame] configure -background [dict get $c editor.bg]
	[gget $g tabs]  configure -background [dict get $c tab.bar.bg]
	[gget $g frame].gutter configure -background [dict get $c editor.bg]
	gutter_redraw $g    ;# gutter.fg / font may have moved — repaint the numbers
	if {[info procs rio::syntax::tokens] ne ""} {
		foreach tok [rio::syntax::tokens] {
			set role syntax.$tok
			set col [expr {[dict exists $c $role] ? [dict get $c $role] : [dict get $c editor.fg]}]
			$t tag configure syn:$tok -foreground $col
		}
	}
	# The find bar's match paint (D36); the selection stays on top so the
	# current match reads over the findmatch band.
	set fm [expr {[dict exists $c editor.findmatch] \
		? [dict get $c editor.findmatch] : [dict get $c editor.selection]}]
	$t tag configure findmatch -background $fm
	# Column/block editing (D40): a width selection reuses the selection colour. The
	# zero-width caret column is drawn as placed blinking bars (col_bars_draw), not a
	# tag, so it needs no tag config here. Raised above the syntax colours.
	$t tag configure coltag -background [dict get $c editor.selection]
	# Caret-line band (D60): the editor.currentline role, or a faint blend of the surface
	# toward the foreground for a theme predating it. Lowered to the bottom so syntax text
	# (fg only) reads over it and selection / find bands paint above it.
	set cl [expr {[dict exists $c editor.currentline] \
		? [dict get $c editor.currentline] \
		: [blend_hex [dict get $c editor.bg] [dict get $c editor.fg] 8]}]
	$t tag configure curline -background $cl
	$t tag lower curline
	$t tag raise sel
	$t tag raise coltag
}

proc apply_theme {theme} {
	set c [dict get $theme colors]
	set ::theme_colors $c
	ensure_fonts [dict get $theme fonts]
	# Record the theme's own editor font, then overlay the user's font override (D56)
	# back on top of it — otherwise a theme switch would silently discard a picked font
	# or an active zoom. apply_editor_font reconfigures RioEditorFont before the restyle
	# loop below measures it for the gutter and wrap-indent geometry.
	set _ef [dict get $theme fonts RioEditorFont]
	set ::editor_theme_family [dict get $_ef family]
	set ::editor_theme_size   [dict get $_ef size]
	apply_editor_font
	# Editor surface — every group's widget, frame, tab strip, and syntax tags (D33).
	# Reconfiguring here recolours existing highlighting live on a theme switch; the
	# highlight passes raise the sel tag so a selection stays legible over the colours.
	foreach _g $::groups { restyle_group $_g }
	# Chrome: status bar + dock divider. The tab strips live inside each group and are
	# recoloured by refresh_tabs (called at the end of apply_theme).
	.status configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.sash configure -background [dict get $c tab.bar.bg]   ;# the dock divider/grip
	.bsash configure -background [dict get $c tab.bar.bg]  ;# the bottom-dock height grip
	# The dock sites + the file/git panes: reuse the UI role (no dedicated sidebar
	# role yet); list selections borrow the editor's selection colour so the panes
	# match the surface. Each site's tab strip is coloured by restyle_tabs (below).
	foreach w {.siteleft .siteleft.tabs .siteleft.body .siteright .siteright.tabs .siteright.body \
	           .sitebottom .sitebottom.tabs .sitebottom.body \
	           .pfiles .pfiles.hdr .pgit .pgit.hdr} {
		$w configure -background [dict get $c ui.bg]
	}
	foreach w {.pfiles.hdr.head .pfiles.hdr.refresh .pfiles.hdr.hidden \
	           .pgit.hdr.branch .pgit.hdr.refresh .pgit.hdr.discard} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	# The rich-list panes (D42/D43): a white content "well" (editor surface) with a
	# full-width selection band (the editor selection colour jka already likes) and a
	# subtler hover band blended toward it. selrow raised above hoverrow so the
	# selection wins under the pointer. The file and git lists share this chrome.
	set fbg [dict get $c editor.bg]
	foreach well {.pfiles.well .pgit.well} {
		$well configure -background $fbg
		set body $well.body
		$body configure -font RioUIFont -background $fbg -foreground [dict get $c ui.fg]
		$body tag configure selrow   -background [dict get $c editor.selection]
		$body tag configure hoverrow -background [blend_hex $fbg [dict get $c editor.selection] 25]
		$body tag raise selrow
	}
	# The navigator's glyph + git-flag colours (D43): navicon tints the type glyph a
	# muted foreground; the flag letters borrow the diff/accent roles by kind (added
	# green, deleted red, modified accent) and the dir rollup dot a muted accent.
	.pfiles.well.body tag configure navicon  -foreground [blend_hex [dict get $c ui.fg] $fbg 35]
	.pfiles.well.body tag configure navadd   -foreground [dict get $c diff.added]
	.pfiles.well.body tag configure navdel   -foreground [dict get $c diff.removed]
	.pfiles.well.body tag configure navmod   -foreground [dict get $c accent]
	.pfiles.well.body tag configure navdirty -foreground [blend_hex [dict get $c accent] $fbg 40]
	# The git list's two status chars share the same kind->colour mapping.
	.pgit.well.body tag configure gitadd -foreground [dict get $c diff.added]
	.pgit.well.body tag configure gitdel -foreground [dict get $c diff.removed]
	.pgit.well.body tag configure gitmod -foreground [dict get $c accent]
	# The diff area is code, so it takes the editor surface.
	.pgit.diff configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
	# The commit bar (D45): UI chrome like the header; the summary entry on the editor
	# surface like the find entry so it reads as a place to type.
	.pgit.commit configure -background [dict get $c ui.bg]
	.pgit.commit.go configure -font RioUIFont
	.pgit.commit.msg configure -font RioUIFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor]
	# The placeholder hint: on the entry surface, in a muted grey blended toward it.
	.pgit.commit.msg.ph configure -font RioUIFont \
		-background [dict get $c editor.bg] \
		-foreground [blend_hex [dict get $c editor.fg] [dict get $c editor.bg] 50]
	# The ＋ toggle is chrome; the description body reads like the summary (editor surface),
	# with its own placeholder muted the same way.
	.pgit.commit.more configure -font RioUIFont
	.pgit.commit.body configure -font RioUIFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor]
	.pgit.commit.body.ph configure -font RioUIFont \
		-background [dict get $c editor.bg] \
		-foreground [blend_hex [dict get $c editor.fg] [dict get $c editor.bg] 50]
	# The agent chat pane (D26): the chat.* roles + RioChatFont; accent on labels.
	.chat configure -background [dict get $c chat.bg]
	.chat.hdr configure -background [dict get $c chat.bg]
	.chat.hdr.title configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.hdr.clear configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c accent]
	.chat.hdr.mode configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c accent]
	.chat.hdr.mode.m configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.chat.log configure -font RioChatFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.input configure -font RioChatFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg] \
		-insertbackground [dict get $c chat.fg]
	.chat.send configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	# The bottom strip: the agent selector is a CONTROL, so it takes the accent the
	# pane's other controls take (D68 — static text is muted, interactive text is not),
	# while the working indicator beside it stays quiet chrome.
	.chat.status configure -background [dict get $c tab.bar.bg]
	.chat.status.sel configure -font RioUIFont \
		-background [dict get $c tab.bar.bg] -foreground [dict get $c accent]
	.chat.status.sel.m configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.chat.status.busy configure -font RioUIFont \
		-background [dict get $c tab.bar.bg] -foreground [dict get $c ui.fg]
	# Speaker headers get a full-width highlight band so each turn is easy to find in
	# the log (diffs, tool lines, replies). The label's trailing newline is in the tag
	# range, so the background fills to the right edge. Two tints keep You vs Agent apart.
	.chat.log tag configure agent-label -font RioUIFont -foreground [dict get $c accent] \
		-background [dict get $c ui.bg] -spacing1 4 -spacing3 2
	.chat.log tag configure you-label   -font RioUIFont -foreground [dict get $c chat.fg] \
		-background [dict get $c editor.selection] -spacing1 4 -spacing3 2
	.chat.log tag configure error-label -font RioUIFont -foreground [dict get $c error]
	.chat.log tag configure tool        -font RioUIFont -foreground [dict get $c gutter.fg]
	.chat.log tag configure tool-error  -font RioUIFont -foreground [dict get $c error]
	.chat.log tag configure diff-add    -font RioUIFont -foreground [dict get $c diff.added]
	.chat.log tag configure diff-del    -font RioUIFont -foreground [dict get $c diff.removed]
	.chat.approve configure -background [dict get $c chat.bg]
	.chat.approve.lbl configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.approve.yes configure -font RioUIFont
	.chat.approve.no  configure -font RioUIFont
	.chat.approve.cmp configure -font RioUIFont
	.chat.approve.plan configure -font RioUIFont
	.chat.approve.always configure -font RioUIFont
	.chat.approve.always.m configure -font RioUIFont
	.csash configure -background [dict get $c tab.bar.bg]
	.chat.isash configure -background [dict get $c tab.bar.bg]
	# The find/replace bar (D36): UI chrome, entries on the editor surface.
	.find configure -background [dict get $c ui.bg]
	foreach w {.find.fl .find.rl .find.count .find.close .find.case .find.word .find.regex} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	foreach w {.find.case .find.word .find.regex} {
		$w configure -activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	}
	foreach w {.find.next .find.prev .find.rep .find.repall} {
		$w configure -font RioUIFont
	}
	foreach w {.find.e .find.re} {
		$w configure -font RioChatFont \
			-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
			-insertbackground [dict get $c editor.cursor]
	}
	# The Search panel (D52): chrome like the find bar, the query entry on the editor
	# surface (a place to type), the well + rich-list like the dock panes. The
	# file/buffer-header rows take the accent; the match rows the editor foreground.
	foreach w {.results .results.hdr .results.rep} { $w configure -background [dict get $c ui.bg] }
	foreach w {.results.hdr.l .results.hdr.count .results.hdr.close .results.hdr.case .results.hdr.word .results.hdr.regex .results.rep.l} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	.results.rep.all configure -font RioUIFont
	foreach w {.results.hdr.case .results.hdr.word .results.hdr.regex} {
		$w configure -activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	}
	# The scope option menu (menubutton + its dropdown) takes the UI chrome.
	.results.hdr.scope configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	.results.hdr.scope.menu configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c editor.selection] -activeforeground [dict get $c ui.fg]
	foreach w {.results.hdr.e .results.rep.e} {
		$w configure -font RioChatFont \
			-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
			-insertbackground [dict get $c editor.cursor]
	}
	.results.well configure -background [dict get $c editor.bg]
	set rbody .results.well.body
	$rbody configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
	$rbody tag configure selrow   -background [dict get $c editor.selection]
	$rbody tag configure hoverrow -background [blend_hex [dict get $c editor.bg] [dict get $c editor.selection] 25]
	$rbody tag configure fifile -foreground [dict get $c accent]
	# The per-match band: the theme's diff-added green (light green on light themes,
	# a dark green on dark ones — always readable under editor.fg, D51). Raised above
	# the selection band so a hit stays visible on the selected row.
	$rbody tag configure fimatch -background [dict get $c diff.added.bg]
	$rbody tag raise selrow
	$rbody tag raise fimatch
	# The compare/diff view (D28): the panes take the editor surface, the headers the
	# UI chrome (like the dock); row tags tint removed/added lines and grey the
	# fillers so a changed line reads as a coloured band (VSCode-style).
	foreach w {.cmp.l.hdr .cmp.r.hdr} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	foreach w {.cmp.l.t .cmp.r.t} {
		$w configure -font RioEditorFont \
			-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
		$w tag configure del    -background [dict get $c diff.removed.bg] -foreground [dict get $c diff.removed]
		$w tag configure add    -background [dict get $c diff.added.bg] -foreground [dict get $c diff.added]
		$w tag configure filler -background [dict get $c ui.bg]
	}
	.cmp.sb configure -background [dict get $c ui.bg]
	.cmp.bar configure -background [dict get $c ui.bg]
	.cmp.bar.close configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	restyle_tabs
	help_restyle   ;# the help viewer, if it is open — it outlives a theme change (D99)
	plan_restyle   ;# and the plan view, which outlives one the same way (D101)
	# Named-font defaults for widgets created later (dialogs, the future chat pane).
	option add *Text.font RioEditorFont
	option add *Label.font RioUIFont
	if {[dict size $::buffers]} refresh_tabs
}

# Switch themes live (View menu): re-fetch from the core and re-apply.
proc do_theme {name} {
	set resp [rio_call theme.get [dict create name $name]]
	if {[dict get $resp ok]} {
		set ::theme_name $name
		set ::theme_choice $name
		apply_theme [dict get $resp result]
		prefs_save
	} else {
		# The switch failed, so snap the tracked choice back to the theme still
		# applied — it drives the Preferences button's label, which must never
		# claim a theme the editor isn't wearing.
		set ::theme_choice $::theme_name
		report_error "Theme '$name': [dict get $resp error message]" \
			[dict get $resp error code]
	}
}

# The themes the core can load, as picker rows {name label} — so a theme installed from
# a repository (D39) appears with no wiring of its own. Built on demand rather than
# cached into a widget: this is the only reader, and an install/removal is then live
# with nothing to refill. An older remote core without theme.list keeps the shipped four.
proc theme_pick_rows {} {
	set names {default solarized-dark solarized-light acme}
	set resp [rio_call theme.list {}]
	if {[dict get $resp ok]} { set names [dict get $resp result themes] }
	set rows {}
	foreach name $names { lappend rows [list $name [theme_label $name]] }
	return $rows
}

# View ▸ Theme… and the Preferences ▸ View theme button (D92): pick a theme from the
# bounded list instead of a cascade that grows with every installed theme. This was the
# last data-driven, unbounded menu in rio — the standing X11 over-tall-menu caveat — and
# it retires the same way the Tabs cascade did in D74, through pick_dialog. Opening on
# the theme in use makes the dialog show the current value, the job the cascade's radio
# checkmark used to do.
proc theme_pick_dialog {} {
	set name [pick_dialog "Theme" [theme_pick_rows] $::theme_name]
	if {$name ne "" && $name ne $::theme_name} { do_theme $name }
}

# "solarized-dark" -> "Solarized Dark": menu labels derive from theme file names.
proc theme_label {name} {
	set words {}
	foreach w [split $name -] { lappend words [string totitle $w] }
	return [join $words " "]
}

# ---------------------------------------------------------------------------
# Syntax highlighting (AGENTS.md D32). Highlighting is PRESENTATION, so the GUI
# owns it: pure, swappable per-line scanner modules live in syntax/ (Tk-free — a
# future TUI reuses them), and the GUI is the *applier*. It maps each token TYPE
# onto the theme's syntax.* colour role as a text tag (apply_theme), and re-tokenises
# the active buffer after edits.
#
# Re-highlighting is INCREMENTAL. After an edit (hl_edit) only the changed line's state
# can differ, so hl_incremental re-scans from the first dirty line DOWNWARD and stops as
# soon as a line's freshly-computed entry state matches the cached one (past the edit) —
# the state has re-converged, so every line below is unchanged. Typing thus re-tags a
# handful of lines, not the whole file, while multi-line context (open comments, script
# bodies, quoted values that carry state across lines) stays correct. Edits are coalesced
# on the idle handler so a burst of keystrokes paints once.
#
# Highlighting is also VIEWPORT-SCOPED (D126). Painting the whole buffer on open cost
# ~1.35 seconds per megabyte and was 81% of the price of opening a large file — the
# reason D125 had to make an 8 MB file a question at all. Two pieces of state replace
# the whole-buffer pass, and the trick is that the first one is the OLD cache, weakened:
#
#   hl_enter      — the SCAN FRONTIER. Still the scan state entering each line, index
#                   i-1 for line i, still exact; it just stops at some line E <= the
#                   line count instead of covering the file. Below E nothing is claimed.
#   hl_lo, hl_hi  — the PAINTED INTERVAL: the lines that actually carry syn:* tags.
#                   0 0 means none. Always within the frontier (hl_hi <= E).
#
# Weakening "exact everywhere" to "exact up to E" is what makes this small: the splice
# in hl_edit, the convergence early-out in hl_incremental and the cache's indexing all
# work unchanged on a shorter list, and truncating the frontier is always a legal thing
# to do because the frontier never promises anything below itself. On a file that fits
# on screen the frontier IS the whole file and the painted interval IS every line, so
# small files run exactly the code they ran before.
#
# hl_ensure is the one entry point: it grows the frontier toward the visible window (in
# hl_chunk-sized pieces that yield to the event loop, so a jump to the end of a huge
# file streams colour in rather than freezing) and paints only what is newly exposed,
# never re-tagging a line that is already correct. Scrolling reaches it through
# edscroll, i.e. through Tk's -yscrollcommand, which is also how the wheel, the
# scrollbar, `see`, vi's jumps and find's step all arrive — one seam, not five.
#
# What stays whole-buffer on purpose: entry states are exact, never guessed from a
# bounded back-scan, so reaching line N still means having scanned the N-1 lines above
# it. That work is real but it is chunked, off the blocking path, and paid once.
# ---------------------------------------------------------------------------

# Load the tokeniser modules: the registry (the contract) then every language
# module. Shipped modules load first, then the user's own from
# $XDG_CONFIG_HOME/rio/syntax/, so a drop-in file re-registering an extension
# replaces the shipped highlighter (the same override idea as user themes, D24). A
# broken module is reported, not fatal — it must never stop the editor from starting.
proc hl_load {} {
	set base [file join $::rio_dir .. syntax]
	if {[catch {source [file join $base registry.tcl]} err]} {
		puts stderr "rio-gui: syntax registry failed to load: $err" ; return
	}
	foreach dir [list $base [hl_user_dir]] {
		if {$dir eq "" || ![file isdirectory $dir]} continue
		foreach f [lsort [glob -nocomplain -directory $dir *.tcl]] {
			if {[file tail $f] eq "registry.tcl"} continue
			if {[catch {source $f} err]} {
				puts stderr "rio-gui: syntax module [file tail $f] failed to load: $err"
			}
		}
	}
}

# The user's drop-in highlighter dir (beside the user themes dir, D21 locations).
proc hl_user_dir {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio syntax]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio syntax]
	}
	return ""
}

# ---------------------------------------------------------------------------
# Editing modes (AGENTS.md D38, D41): the core ships the Windows mode only; emacs
# and vi install as extensions into the user drop-in dir. Loaded exactly like the
# syntax highlighters — registry first, shipped modules, then user drop-ins that
# shadow by re-registering. The active mode lives on the shared RioMode bind tag,
# which make_editor_group slots between each text widget and Tk's Text class:
#
#     .eg<g>.t   RioMode   Text   .   all
#
# so the precedence is fixed by construction: app keymap chords (on the widget
# path, D23) always beat the mode; mode bindings that `break` beat Tk's Text
# defaults; mode bindings that don't fall through to them.
# ---------------------------------------------------------------------------
proc modes_load {} {
	set base [file join $::rio_dir .. modes]
	if {[catch {source [file join $base registry.tcl]} err]} {
		puts stderr "rio-gui: modes registry failed to load: $err" ; return
	}
	foreach dir [list $base [modes_user_dir]] {
		if {$dir eq "" || ![file isdirectory $dir]} continue
		foreach f [lsort [glob -nocomplain -directory $dir *.tcl]] {
			if {[file tail $f] eq "registry.tcl"} continue
			if {[catch {source $f} err]} {
				puts stderr "rio-gui: mode module [file tail $f] failed to load: $err"
			}
		}
	}
}

# The user's drop-in modes dir (a sibling of the syntax and themes dirs, D21).
proc modes_user_dir {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio modes]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio modes]
	}
	return ""
}

# The one applier for ::edit_mode (the D31 pattern: menu radio and boot both land
# here). Detach the outgoing mode, wipe the tag centrally — a mode can never leak
# a binding — then attach the new one. A persisted mode that no longer exists
# falls back to the default rather than erroring at startup (same spirit as the
# theme fallback).
proc apply_editmode {} {
	if {[info commands rio::modes::exists] eq ""} return
	if {![rio::modes::exists $::edit_mode]} {
		if {![rio::modes::exists windows]} return
		set ::edit_mode windows
	}
	if {$::editmode_active ne ""} {
		catch { rio::modes::detach $::editmode_active RioMode }
	}
	catch { col_clear }   ;# column editing (D40) is windows-only; drop any live selection
	foreach seq [bind RioMode] { bind RioMode $seq "" }
	set ::editmode_status ""
	rio::modes::attach $::edit_mode RioMode
	set ::editmode_active $::edit_mode
	sync_column_edit_menu
	refresh_status
	prefs_save
}

# Column editing rearranges text in a way that only the windows mode's caret model
# makes sense of — vi and emacs carry their own block/rectangle notions — so the
# Settings toggle is greyed out (whatever its stored value) unless windows mode is
# active. apply_editmode calls this on every mode switch; boot calls it once.
proc sync_column_edit_menu {} {
	if {![winfo exists .m.settings]} return
	set state [expr {$::edit_mode eq "windows" ? "normal" : "disabled"}]
	catch { .m.settings entryconfigure "Column Editing*" -state $state }
}

# Fill the Settings ▸ Editing Mode cascade from the registry — one radio per
# registered mode, so a user drop-in shows up with no menu wiring of its own.
proc modes_menu_fill {} {
	if {![winfo exists .m.settings.editmode]} return
	.m.settings.editmode delete 0 end
	if {[info commands rio::modes::names] eq ""} return
	foreach name [rio::modes::names] {
		.m.settings.editmode add radiobutton -label [rio::modes::label $name] \
			-variable ::edit_mode -value $name -command apply_editmode
	}
}

# Pick the scanner for group `g`'s active buffer ("" = no highlighter, e.g. a scratch
# buffer or a plain-text file). Runs on open / switch. A language the user picked by
# hand (the buffer's `lang`, D112) wins; otherwise the file name decides. A picked
# language that is no longer registered (its extension removed) falls back to the file
# name rather than erroring. The scanner + language name live in the group's cache, one
# per editor widget (D33).
proc hl_select {g} {
	gset $g hl_scan "" ; gset $g hl_lang ""
	if {[info procs rio::syntax::for_path] eq ""} return
	set id [gcur $g]
	if {$id eq "" || ![dict exists $::buffers $id]} return
	set lang [expr {[dict exists $::buffers $id lang] ? [bufget $id lang] : ""}]
	if {$lang eq "plain"} return
	if {$lang ne "" && [rio::syntax::for_lang $lang] ne ""} {
		gset $g hl_scan [rio::syntax::for_lang $lang]
		gset $g hl_lang $lang
		return
	}
	set path [bufget $id path]
	if {$path ne ""} {
		gset $g hl_scan [rio::syntax::for_path $path]
		gset $g hl_lang [rio::syntax::lang_for_path $path]
	}
}

# Re-pick and repaint the highlighter in every group showing buffer `id` — after its
# path changed (Save As, a rename) or its language was picked by hand (D112).
proc hl_refresh_buffer {id} {
	foreach g $::groups {
		if {[gcur $g] eq $id} { hl_select $g ; hl_reset $g }
	}
}

# Set buffer `id`'s language by hand (D112): "" = detect by file name, "plain" = no
# highlighting, else a registered language name. View state only, like `modified`.
proc set_buffer_lang {id lang} {
	if {![dict exists $::buffers $id]} return
	bufset $id lang $lang
	hl_refresh_buffer $id
	refresh_status
}

# View ▸ Language… (D112): pick the current buffer's highlighter by hand, for pasted
# code in an untitled buffer or a file the name guesses wrong. The shared bounded picker,
# not a cascade — the list grows with every installed syntax extension (D92). Payloads
# are never "" because pick_dialog returns "" on Cancel.
proc language_pick_rows {} {
	set p [bufget $::cur path]
	set detected [expr {$p ne "" ? [rio::syntax::lang_for_path $p] : ""}]
	if {$detected eq ""} { set detected "plain text" }
	set rows [list [list auto "Auto-detect ($detected)"] [list plain "Plain Text"]]
	foreach name [rio::syntax::names] { lappend rows [list lang:$name $name] }
	return $rows
}
proc language_pick_dialog {} {
	if {$::cur eq "" || [info procs rio::syntax::names] eq ""} { bell ; return }
	set lang [bufget $::cur lang]
	set initial [expr {$lang eq "" ? "auto" : $lang eq "plain" ? "plain" : "lang:$lang"}]
	set pick [pick_dialog "Language" [language_pick_rows] $initial]
	switch -glob -- $pick {
		""      { return }
		auto    { set_buffer_lang $::cur "" }
		plain   { set_buffer_lang $::cur plain }
		lang:*  { set_buffer_lang $::cur [string range $pick 5 end] }
	}
}

# Widget `t`'s current line count (1-based; a Tk text widget always has at least line
# 1). A group's hl_enter is kept the same length, so index i-1 is line i's state.
proc hl_linecount {t} {
	return [lindex [split [$t index "end-1c"] .] 0]
}

# Re-tag one line L of widget `t` with scanner `scan`, from its already-known entry
# `state`/`param`: scan it, clear the old syntax tags on just that line, repaint, and
# return the state ENTERING line L+1. `clear` is 0 when the caller has already cleared
# a whole range in one go (hl_paint_range) — that per-line removal is 13 widget calls
# and most of the cost of painting, so a range pass hoists it out of the loop.
proc hl_paint_line {t scan L state param {clear 1}} {
	set line [$t get $L.0 "$L.0 lineend"]
	lassign [rio::syntax::scan_line $scan $line $state $param] spans state param
	if {$clear} {
		foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok $L.0 "$L.0 lineend" }
	}
	foreach {c0 c1 type} $spans { $t tag add syn:$type $L.$c0 $L.$c1 }
	return [list $state $param]
}

# The lines group `g` wants highlighted: what is on screen, plus ::hl_margin above and
# below so an ordinary scroll usually finds its new lines already painted. Asks the
# WIDGET via @0,y rather than doing pixel arithmetic, exactly as gutter_redraw does —
# so a wrapped logical line occupying several display rows is counted once and -wrap
# word needs no special case. A group whose window has not been mapped yet reports a
# height of 1; fall back to its configured -height rather than a degenerate window.
proc hl_window {g nlines} {
	set t [gw $g]
	set h [winfo height [gget $g path]]
	set top [expr {int([$t index @0,0])}]
	if {$h < 2} {
		set bot [expr {$top + [$t cget -height]}]
	} else {
		set bot [expr {int([$t index @0,[expr {$h - 1}]])}]
	}
	set w0 [expr {$top - $::hl_margin}]
	set w1 [expr {$bot + $::hl_margin}]
	if {$w0 < 1} { set w0 1 }
	if {$w1 > $nlines} { set w1 $nlines }
	return [list $w0 $w1]
}

# Grow group `g`'s scan frontier toward line `target`, at most ::hl_chunk lines per
# call. This SCANS without painting — roughly 23 us a line against 56 for a painted
# one — because all we need from the lines above the viewport is the state they hand
# down. If the target is still out of reach the pass re-arms itself; the continuation
# re-enters hl_ensure rather than this proc, so if the user scrolled somewhere else in
# the meantime the next chunk aims at the new window instead of the stale one.
proc hl_extend {g target nlines} {
	set t [gw $g] ; set scan [gget $g hl_scan]
	set enter [gget $g hl_enter]
	set E [llength $enter]
	if {$E == 0} {
		lassign [rio::syntax::start] state param
		lappend enter [list $state $param]          ;# state entering line 1
		set E 1
	} else {
		lassign [lindex $enter end] state param
	}
	if {$target > $nlines} { set target $nlines }
	set budget $::hl_chunk
	while {$E < $target && $budget > 0} {
		lassign [rio::syntax::scan_line $scan [$t get $E.0 "$E.0 lineend"] $state $param] \
			_ state param
		lappend enter [list $state $param]          ;# state entering line E+1
		incr E ; incr budget -1
	}
	gset $g hl_enter $enter
	if {$E < $target} { hl_vmark $g 0 }
}

# Paint lines a..b of group `g` from the entry states already cached for them. One tag
# removal for the whole range instead of one per line; the caller guarantees a..b lies
# within the frontier (hl_paint_range clamps rather than trusting that blindly).
proc hl_paint_range {g a b} {
	set t [gw $g] ; set scan [gget $g hl_scan]
	set enter [gget $g hl_enter]
	if {$a < 1} { set a 1 }
	if {$b > [llength $enter]} { set b [llength $enter] }
	if {$b < $a} return
	foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok $a.0 "$b.0 lineend" }
	lassign [lindex $enter [expr {$a - 1}]] state param
	for {set L $a} {$L <= $b} {incr L} {
		lassign [hl_paint_line $t $scan $L $state $param 0] state param
	}
}

# Make sure group `g`'s visible window is highlighted. Idempotent and cheap when there
# is nothing to do, which is the common case — it runs on every scroll.
proc hl_ensure {g} {
	gset $g hl_vpending 0
	if {![dict exists $::grp $g]} return
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	if {[gget $g hl_scan] eq ""} return
	# An edit is queued: its incremental pass owns the frontier and may truncate it, so
	# let that run first. Idle handlers fire in order, so re-arming on idle puts us
	# behind the hl_schedule that hl_edit already queued.
	if {[gget $g hl_pending] || [gget $g hl_dirty] > 0} { hl_vmark $g ; return }
	set t [gw $g]
	set nlines [hl_linecount $t]
	lassign [hl_window $g $nlines] w0 w1
	if {[llength [gget $g hl_enter]] < $w1} {
		hl_extend $g $w1 $nlines
		set E [llength [gget $g hl_enter]]
		if {$w1 > $E} { set w1 $E }   ;# paint only as far as we can vouch for
	}
	if {$w1 < $w0} return
	set lo [gget $g hl_lo] ; set hi [gget $g hl_hi]
	if {$hi > $nlines} { set hi $nlines }
	if {$lo == 0 || $w1 < $lo - 1 || $w0 > $hi + 1} {
		# A jump: the new window is disjoint from what is painted. Everything painted
		# is off-screen by construction, so wiping it cannot flicker.
		foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok 1.0 end }
		hl_paint_range $g $w0 $w1
		gset $g hl_lo $w0 ; gset $g hl_hi $w1
		return
	}
	# An ordinary scroll: paint only the strip that just came into range, so a line
	# that is already correct is never re-tagged.
	if {$w0 < $lo} { hl_paint_range $g $w0 [expr {$lo - 1}] ; gset $g hl_lo $w0 }
	if {$w1 > $hi} { hl_paint_range $g [expr {$hi + 1}] $w1 ; gset $g hl_hi $w1 }
}

# Queue a coalesced hl_ensure on group `g`. `now` picks a timer over an idle handler,
# which is what the chunked frontier scan wants: a self-re-registering IDLE handler can
# be serviced again in the same event-loop pass and starve window events, while a timer
# is unambiguously behind them, so the UI stays live while a long prefix builds.
proc hl_vmark {g {now 0}} {
	if {[gget $g hl_vpending]} return
	gset $g hl_vpending 1
	if {$now} {
		after 0 [list hl_ensure $g]
	} else {
		after idle [list hl_ensure $g]
	}
}

# Drop group `g`'s highlight state and start again from the visible window: on open, on
# a tab switch, and whenever the scanner itself changes (Save As, View ▸ Language…, a
# reloaded syntax extension). Reads text from the widget, which already holds the
# canonical content — no core call.
#
# The first paint is SYNCHRONOUS rather than deferred to the idle handler, so opening a
# file never shows a frame of unhighlighted text and a caller that inspects tags right
# away sees them.
proc hl_reset {g} {
	gset $g hl_pending 0 ; gset $g hl_dirty 0 ; gset $g hl_lastchanged 0
	gset $g hl_enter {} ; gset $g hl_lo 0 ; gset $g hl_hi 0
	set t [gw $g]
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok 1.0 end }
	if {[gget $g hl_scan] eq ""} return
	hl_ensure $g
}

# Record an edit in group `g` for its next incremental pass. The core echoes every
# change as {start end text}; from that we know the first line touched (sl) and the net
# change in line count (delta). We splice the group's hl_enter by delta so the cached
# entry states BELOW the edit stay index-aligned with the widget — that alignment is
# what lets hl_incremental trust the cache when testing for state convergence. Then we
# widen the dirty range and queue a coalesced pass.
#
# The painted interval is spliced by the same delta, and that is load-bearing rather
# than tidiness: Tk anchors tags to characters, so the correct tags below an edit ride
# the text as it moves. Without the splice every keystroke would look like a jump and
# repaint the whole window instead of a line or two.
proc hl_edit {g p} {
	set scan [gget $g hl_scan] ; set enter [gget $g hl_enter]
	if {$scan eq ""} return
	if {$enter eq ""} { hl_vmark $g ; return }   ;# nothing scanned yet — not a cache miss
	set sl [lindex [split [dict get $p start] .] 0]
	set el [lindex [split [dict get $p end]   .] 0]
	set added [expr {[llength [split [dict get $p text] "\n"]] - 1}]
	set delta [expr {$added - ($el - $sl)}]
	set n [llength $enter]
	# Entirely below the frontier: nothing is cached or painted down there, and the
	# frontier makes no claim about it. Let hl_ensure pick it up if it scrolls into view.
	if {$sl > $n} { hl_vmark $g ; return }
	if {$delta > 0} {
		set pad {} ; for {set i 0} {$i < $delta} {incr i} { lappend pad [list "\xEF\xBF\xBFdirty" ""] }
		set enter [linsert $enter $sl {*}$pad]
	} elseif {$delta < 0} {
		# Clamp to the frontier: a deletion reaching past it just truncates the prefix.
		set last [expr {$sl - $delta - 1}]
		if {$last > $n - 1} { set last [expr {$n - 1}] }
		if {$last >= $sl} { set enter [lreplace $enter $sl $last] }
	}
	gset $g hl_enter $enter
	set lo [gget $g hl_lo] ; set hi [gget $g hl_hi]
	if {$hi > 0} {
		if {$hi >= $sl} { set hi [expr {max($sl - 1, $hi + $delta)}] }
		if {$lo >  $sl} { set lo [expr {max($sl,     $lo + $delta)}] }
		if {$hi < $lo}  { set lo 0 ; set hi 0 }
		gset $g hl_lo $lo ; gset $g hl_hi $hi
	}
	set dirty [gget $g hl_dirty]
	if {$dirty < 1 || $sl < $dirty} { gset $g hl_dirty $sl }
	set lc [expr {$sl + $added}]
	if {$lc > [gget $g hl_lastchanged]} { gset $g hl_lastchanged $lc }
	hl_schedule $g
}

# Incremental re-highlight of group `g` (the idle handler). Re-scan from the first
# dirty line down, repainting each line and updating its cached entry state, and stop
# as soon as — past the edited region — a line's fresh entry state matches the one
# already cached: the scan state has re-converged, so everything below is unaffected.
#
# The pass runs to the frontier, not to the end of the buffer, and only lines inside
# the painted interval are actually re-tagged; outside it we scan for the state alone.
# An edit that never re-converges (typing "<!--" at the top of a huge file) is capped
# at ::hl_chunk lines: rather than carry resumable state, the frontier is TRUNCATED to
# where the pass got to. That is always legal — the frontier promises nothing below
# itself — and it is what keeps this proc free of continuation bookkeeping.
proc hl_incremental {g} {
	gset $g hl_pending 0
	set t [gw $g]
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	set scan [gget $g hl_scan]
	if {$scan eq ""} { gset $g hl_dirty 0 ; return }
	set enter [gget $g hl_enter]
	set start [gget $g hl_dirty] ; set last [gget $g hl_lastchanged]
	gset $g hl_dirty 0 ; gset $g hl_lastchanged 0
	if {$start < 1} return
	set nlines [hl_linecount $t]
	if {$start > $nlines} return
	set E [llength $enter]
	if {$E > $nlines} { set E $nlines }
	if {$start > $E} { hl_vmark $g ; return }      ;# below the frontier
	set lo [gget $g hl_lo] ; set hi [gget $g hl_hi]
	set scanned 0
	set budget $::hl_chunk
	lassign [lindex $enter [expr {$start - 1}]] state param
	for {set L $start} {$L <= $E} {incr L} {
		if {$lo > 0 && $L >= $lo && $L <= $hi} {
			lassign [hl_paint_line $t $scan $L $state $param] state param
		} else {
			lassign [rio::syntax::scan_line $scan [$t get $L.0 "$L.0 lineend"] \
				$state $param] _ state param
		}
		incr scanned
		if {[incr budget -1] <= 0 && $L < $E} {
			set enter [lrange $enter 0 [expr {$L - 1}]]
			foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok [expr {$L + 1}].0 end }
			if {$lo > $L} { set lo 0 ; set hi 0 } elseif {$hi > $L} { set hi $L }
			gset $g hl_lo $lo ; gset $g hl_hi $hi
			hl_vmark $g 0
			break
		}
		if {$L == $E} break                  ;# no cached line below to carry state into
		set next [list $state $param]
		set old [lindex $enter $L]           ;# cached state entering line L+1
		lset enter $L $next
		if {$L >= $last && $next eq $old} break   ;# past the edit and re-converged
	}
	gset $g hl_enter $enter
	gset $g hl_scanned $scanned
	hl_vmark $g   ;# the edit may have exposed lines the window now wants painted
}

# Queue a coalesced incremental pass on group `g`'s idle handler, so a run of
# keystrokes triggers a single re-scan rather than one pass per character.
proc hl_schedule {g} {
	if {[gget $g hl_pending]} return
	gset $g hl_pending 1
	after idle [list hl_incremental $g]
}

# ---------------------------------------------------------------------------
# Sessions & preferences (AGENTS.md D31). Two halves, split by owner:
#
#   * PREFERENCES — how the editor looks: theme, wrap, dock side/pane, chat
#     visibility. Pure view state the core knows nothing about, so the GUI owns it,
#     in $XDG_CONFIG_HOME/rio/prefs.json (beside the user themes dir). Plain JSON
#     data, parsed never executed (D21); loaded at startup, saved on each change.
#
#   * WORKSPACE — which files were open in a project + the active tab. Document
#     state, so the CORE owns it (workspace.* ops, keyed by project root, kept OUT
#     OF TREE under its data dir). That is why a resume Just Works over a remote
#     core: the session lives WITH the project, on the server (D30/D31).
#
# Neither ever holds a secret (the API key stays in the 0600 store, D26). Writes are
# gated on ::rio_started so the appliers that also run during boot don't persist the
# defaults back over what was just loaded.
# ---------------------------------------------------------------------------
proc prefs_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio prefs.json]
}

# Read a whole UTF-8 text file, ALWAYS closing the channel — the `finally` is the
# point. Each config reader below parses inside a catch that tolerates a corrupt
# file; written as one `open … ; parse ; close` chain, a throwing parse skips the
# close and leaks the channel. That is invisible on POSIX but not on Windows, where
# an open handle makes the file undeletable: one corrupt prefs.json or keys.json
# locked it for the life of the process, so rio could never rewrite or reset it.
proc slurp_utf8 {path} {
	set f [open $path r]
	try {
		fconfigure $f -encoding utf-8
		return [::read $f]
	} finally {
		close $f
	}
}

# Load saved preferences over the defaults. A missing or corrupt file leaves the
# defaults intact — a bad prefs file must never stop the editor starting. Only known
# keys with valid values are honoured; anything else is ignored.
proc prefs_load {} {
	set path [prefs_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {set d [json::json2dict [slurp_utf8 $path]]}]} return
	if {[dict exists $d theme]}      { set ::theme_name [dict get $d theme] }
	if {[dict exists $d wrap]}       { set ::wrap_lines [expr {[dict get $d wrap] ? 1 : 0}] }
	if {[dict exists $d wrap_indent]} { set ::wrap_indent [expr {[dict get $d wrap_indent] ? 1 : 0}] }
	if {[dict exists $d line_numbers]} { set ::line_numbers [expr {[dict get $d line_numbers] ? 1 : 0}] }
	if {[dict exists $d highlight_current_line]} { set ::highlight_current_line [expr {[dict get $d highlight_current_line] ? 1 : 0}] }
	if {[dict exists $d relative_line_numbers]} { set ::relative_line_numbers [expr {[dict get $d relative_line_numbers] ? 1 : 0}] }
	if {[dict exists $d show_hidden]} { set ::show_hidden [expr {[dict get $d show_hidden] ? 1 : 0}] }
	if {[dict exists $d column_edit]} { set ::col_on [expr {[dict get $d column_edit] ? 1 : 0}] }
	if {[dict exists $d check_updates]} { set ::ext_check_updates [expr {[dict get $d check_updates] ? 1 : 0}] }
	if {[dict exists $d allow_unverified_repos]} { set ::repo_allow_unverified [expr {[dict get $d allow_unverified_repos] ? 1 : 0}] }
	if {[dict exists $d agent_selection_menu]} { set ::agent_selection_menu [expr {[dict get $d agent_selection_menu] ? 1 : 0}] }
	if {[dict exists $d tab_layout]} {
		set tl [dict get $d tab_layout]
		if {$tl eq "scroll" || $tl eq "multi"} { set ::tab_layout $tl }
	}
	# Editor font override (D56). Applied by the first apply_theme after boot, which
	# overlays these onto the theme's font. A bad size is ignored, keeping the theme's.
	if {[dict exists $d font_family]} { set ::editor_font_family [dict get $d font_family] }
	if {[dict exists $d font_size]} {
		set s [dict get $d font_size]
		if {[string is integer -strict $s] && $s >= 5 && $s <= 72} { set ::editor_font_size $s }
	}
	# The dock layout (D35 step b): adopt a persisted `layout` object, or migrate the
	# pre-step-(b) flat keys (dock_side/dock_pane/chat_shown) forward. normalize repairs
	# either into a well-formed layout (and boots the Search strip hidden).
	if {[dict exists $d layout]} {
		set ::layout [rio::layout::boot [dict get $d layout]]
	} else {
		set ::layout [rio::layout::boot [rio::layout::migrate $d]]
	}
	if {[dict exists $d editmode]} { set ::edit_mode [dict get $d editmode] }
	# The last folder opened on a local core (D88). Stashed only — the project can't be
	# reopened until the channel is up; reopen_last_project does that during boot.
	if {[dict exists $d project]} { set ::last_project [dict get $d project] }
}

# Persist the current preferences. Called from each view-state applier (do_theme,
# apply_wrap, apply_layout, show_pane) — the single choke point per setting — so any
# menu or keyboard toggle records itself. Scalars are flat strings (rio::wire::obj);
# the dock arrangement rides as the nested `layout` object (D35 step b), which
# replaced the old dock_side/dock_pane/chat_shown flags outright (clean cut,
# decision 3). 0/1 flags read back cleanly through expr.
proc prefs_save {} {
	if {!$::rio_started} return
	set path [prefs_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set scalars [rio::wire::obj [dict create \
			theme       $::theme_name \
			wrap        $::wrap_lines \
			wrap_indent $::wrap_indent \
			line_numbers $::line_numbers \
			highlight_current_line $::highlight_current_line \
			relative_line_numbers $::relative_line_numbers \
			show_hidden $::show_hidden \
			column_edit $::col_on \
			check_updates $::ext_check_updates \
			allow_unverified_repos $::repo_allow_unverified \
			agent_selection_menu $::agent_selection_menu \
			tab_layout  $::tab_layout \
			font_family $::editor_font_family \
			font_size   $::editor_font_size \
			editmode   $::edit_mode \
			project    $::last_project]]
		# scalars minus its trailing brace, then the layout member and a final closing
		# brace (backslash-escaped so this literal brace does not end the catch body).
		set json "[string range $scalars 0 end-1],\"layout\":[rio::layout::json]\}"
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f $json ; close $f
	}
}

# Save the open project's workspace: the paths of the open tabs (untitled/unsaved
# tabs, which have no path, are omitted), the active tab's path, and the file tree's
# unfolded-dir set (D89). The core keys it by the open project root and no-ops when
# none is open, so this is safe to call unconditionally. `open` and `expanded` ride the
# wire as newline-joined strings (workspace.*). Unlike D88's project pointer, the tree
# shape lives in the core session, so it follows the project onto a remote host too.
proc session_save {} {
	if {!$::rio_started} return
	set paths {}
	foreach id [dict keys $::buffers] {
		set p [bufget $id path]
		if {$p ne ""} { lappend paths $p }
	}
	set active [expr {$::cur ne "" ? [bufget $::cur path] : ""}]
	catch {rio_call workspace.save [dict create open [join $paths "\n"] active $active \
		expanded [join [dict keys $::nav_expanded] "\n"]]}
}

# Reopen the folder open at the last launch (D88), so a bare `rio` resumes where you
# left off instead of a blank pane. The core keeps "which folder is open" in memory only
# (rio::project — reset on a fresh process), so the GUI persists the path (prefs.json) and
# reopens it here, which is also what points workspace.get at the right per-project session
# below. Runs during boot before session_restore, only when nothing else already opened a
# project (an argv folder or an adopted core project wins). Local cores only: ::last_project
# is never set from a remote (server) root, and open_folder would report_error on a path the
# local core can't see. A folder that has since vanished is skipped silently.
proc reopen_last_project {} {
	if {$::nav_root ne "" || $::core_remote} return
	# The core owns "which folder is open": a persistent local daemon may already hold one,
	# so adopt that rather than overriding it with the remembered path (this also fills the
	# pane in the adopted-project case). Only when the core has none do we reopen last time's.
	set root [dict get [rio_call project.get {}] result root]
	if {$root ne ""} { on_project_opened [dict create root $root] ; return }
	if {$::last_project eq ""} return
	if {![file isdirectory $::last_project]} {
		# The remembered folder is gone from disk (deleted since we last ran). Stop pointing
		# launches at a dead path (D89) — the in-memory clear persists on the next prefs_save.
		set ::last_project ""
		return
	}
	open_folder $::last_project
}

# Restore the open project's workspace: reopen each saved file (the core has already
# pruned any that vanished) and focus the saved active tab. do_open dedups against
# open tabs and prunes the empty scratch buffer, so restoring onto a fresh launch
# leaves exactly the saved set. Runs during boot only, while ::rio_started is still 0
# — so the do_opens here don't each trigger a save.
proc session_restore {} {
	set resp [rio_call workspace.get {}]
	if {![dict get $resp ok]} return
	set res [dict get $resp result]
	foreach p [dict get $res open] { do_open $p }
	set active [dict get $res active]
	if {$active ne ""} {
		foreach id [dict keys $::buffers] {
			if {[bufget $id path] eq $active} { activate $id ; break }
		}
	}
	# Restore the file tree's unfolded shape (D89), now the project is open so this keys on
	# the right session. The core pruned any dir that has since vanished. on_project_opened
	# reset the set to empty when the folder opened; this refills it and repaints. Only with a
	# project actually open — the anonymous (no-folder) session has no tree.
	if {$::nav_root ne ""} {
		set ::nav_expanded [dict create]
		foreach d [dict get $res expanded] { dict set ::nav_expanded $d 1 }
		if {[dict size $::nav_expanded]} { populate_nav }
	}
}

# ---------------------------------------------------------------------------
# Extension repositories (AGENTS.md D39). The apt-sources model, over plain
# HTTP: sources.list holds base URLs, each pointing at a webdir that hosts
# rio-repository.conf (the marker+manifest), an optional `index`, and one
# subdirectory per extension carrying rio-extension.conf + its payload files.
# No central index, no accounts — provenance (source URL + version) is
# recorded per installed extension in a local ledger, and same-name extensions
# from different sources coexist in listings for the USER to choose between.
#
# The split of labour: the CORE fetches (repo.fetch — bounded, plain http, so
# a remote core uses ITS network) and stores themes (theme.put/delete — theme
# files are the core's to read); the GUI interprets — parses manifests (conf
# DATA, never executed), asks consent, installs syntax/mode payloads into its
# own drop-in dirs (they run in the FRONTEND), and keeps the ledger. Remote
# caveat, recorded honestly: the ledger says "this GUI installed X onto its
# core" — a second frontend on the same daemon doesn't see it (ROADMAP).
#
# Every REMOTE-SUPPLIED name (extension dir, name, kind, payload filename)
# must pass ext_safe_name before it is joined into a URL or a path — that one
# rule kills traversal and percent-encoding games at the format level.
# ---------------------------------------------------------------------------

set ::ext_ledger {}     ;# "kind/name" -> {source dir version files installed ?anysource?} (ledger_load)
set ::provider_api_max 1 ;# highest provider-api the core loads (provider.list; D66)
# Highest mode-api THIS GUI implements (D123, modes/registry.tcl). A literal, not a
# core round-trip like provider_api_max above: a provider is sourced into the core, so
# the core is the party that knows its ceiling, but a mode is sourced into the FRONTEND
# — this file is the one that knows.
set ::mode_api_max 1
set ::repo_variants {}  ;# every installable variant found by the last scan
set ::repo_dead {}      ;# {url error code} per unreachable/non-repository source
set ::repo_srcinfo {}   ;# source url -> {name description} from its manifest
set ::ext_core_providers {} ;# name -> {version source} from provider.list (D107)
set ::ext_installed {} ;# "kind/name" -> {version source} — what is installed, ledger + core
set ::ext_updates {}   ;# "kind/name" -> {from to variant} — what a source now offers (D107)

proc ext_safe_name {s} {
	return [regexp {^[A-Za-z0-9][A-Za-z0-9._-]*$} $s]
}

# --- versions: semver, and compared (AGENTS.md D107) ---------------------------
# D39 froze `version` as an opaque string rio never compares, which left the user
# to eyeball "is mine still current?". D107 replaces that with a published rule —
# an extension version is semver (semver.org) — and this comparator.
#
# The parse is deliberately LENIENT about the one thing the spec is strict on:
# 1-3 numeric core components, missing ones zero, so `1.1` reads as `1.1.0`. The
# rule is new and every version installed anywhere predates it (rio's own
# extensions shipped as `1.0`/`1.1`); refusing those would blind the feature on
# exactly the installs it exists for. Everything else follows the spec: an
# optional `-prerelease` of dot-separated identifiers, `+build` ignored.
#
# Returns {core {maj min patch} pre {id …}} or "" — and "" is a real answer, for
# `2026-07-17`, `v2-final`, anything not following the rule. Such an extension
# still lists, still installs, and simply never carries an update claim: D39's
# opacity survives precisely where the rule isn't followed.
proc ext_ver_parse {s} {
	set s [string trim $s]
	if {$s eq ""} { return "" }
	set plus [string first + $s]
	if {$plus >= 0} { set s [string range $s 0 $plus-1] }   ;# build metadata: ignored
	set pre {}
	set dash [string first - $s]
	if {$dash >= 0} {
		set pre [split [string range $s $dash+1 end] .]
		set s [string range $s 0 $dash-1]
		if {![llength $pre]} { return "" }
		foreach id $pre {
			if {![regexp {^[0-9A-Za-z-]+$} $id]} { return "" }
		}
	}
	set parts [split $s .]
	if {[llength $parts] < 1 || [llength $parts] > 3} { return "" }
	# The short-form allowance is for `1.1` and nothing else. Combined with a
	# pre-release it starts reading strings that are not versions at all as if they
	# were — `2026-07-17` would parse as 2026.0.0-07-17 — so a pre-release requires
	# the full three-component core the spec asks for.
	if {[llength $pre] && [llength $parts] != 3} { return "" }
	set core {}
	foreach p $parts {
		# `string is integer` would accept 0x10 and a leading +/-; a version component
		# is digits, nothing else.
		if {![regexp {^[0-9]+$} $p]} { return "" }
		lappend core [scan $p %d]   ;# scan, not expr: 010 is ten, not an octal error
	}
	while {[llength $core] < 3} { lappend core 0 }
	return [dict create core $core pre $pre]
}

# Compare two version STRINGS: -1 / 0 / 1, or "" when either side doesn't parse.
# Callers must treat "" as "no claim can be made" — never as equality.
proc ext_ver_cmp {a b} {
	set pa [ext_ver_parse $a]
	set pb [ext_ver_parse $b]
	if {$pa eq "" || $pb eq ""} { return "" }
	foreach x [dict get $pa core] y [dict get $pb core] {
		if {$x < $y} { return -1 }
		if {$x > $y} { return 1 }
	}
	set ra [dict get $pa pre]
	set rb [dict get $pb pre]
	# A pre-release ranks BELOW the release it leads to: 1.0.0-beta < 1.0.0.
	if {![llength $ra] && ![llength $rb]} { return 0 }
	if {![llength $ra]} { return 1 }
	if {![llength $rb]} { return -1 }
	foreach x $ra y $rb {
		# `foreach` over uneven lists pads with "" — the shorter list runs out first,
		# and a version with FEWER identifiers ranks lower (1.0.0-alpha < 1.0.0-alpha.1).
		if {$x eq ""} { return -1 }
		if {$y eq ""} { return 1 }
		set nx [regexp {^[0-9]+$} $x]
		set ny [regexp {^[0-9]+$} $y]
		if {$nx && $ny} {
			set x [scan $x %d] ; set y [scan $y %d]
			if {$x < $y} { return -1 }
			if {$x > $y} { return 1 }
		} elseif {$nx} {
			return -1              ;# numeric identifiers rank below alphanumeric ones
		} elseif {$ny} {
			return 1
		} else {
			set c [string compare $x $y]
			if {$c != 0} { return [expr {$c < 0 ? -1 : 1}] }
		}
	}
	return 0
}

# --- sources.list -------------------------------------------------------------
proc sources_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio sources.list]
}

# One base URL per line, # comments — hand-editable; the Repositories… editor
# writes the same format back.
proc sources_load {} {
	set path [sources_path]
	if {$path eq "" || ![file exists $path]} { return {} }
	set urls {}
	if {[catch {set text [slurp_utf8 $path]}]} { return {} }
	foreach line [split $text "\n"] {
		set t [string trim $line]
		if {$t eq "" || [string index $t 0] eq "#"} continue
		if {$t ni $urls} { lappend urls $t }
	}
	return $urls
}

proc sources_save {urls} {
	set path [sources_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts $f "# rio extension repositories — one http:// or https:// base URL per line (D39, D109)."
		foreach u $urls { puts $f $u }
		close $f
	}
}

# The repository rio ships pre-configured (D39): the project's own extension repo, so a
# fresh install has something to browse in the Extensions window out of the box. Seeded into
# sources.list ONLY on a true first run — when the file does not yet exist — so a user who
# removes it in Repositories… (which leaves a header-only file behind) is never re-seeded.
# No trailing slash: repo_source_scan appends "/rio-repository.conf" to the base.
set ::default_repo "http://rio.skylm.org/extensions"
proc sources_seed_default {} {
	set path [sources_path]
	if {$path eq "" || [file exists $path]} return
	sources_save [list $::default_repo]
}

# --- signing: which key speaks for a repository (AGENTS.md D118, D119) ---------
#
# D39 keeps plain http first-class, which means anyone on the path between a user
# and a repository can rewrite a payload in flight. A signature over the repository
# is what makes that fail without a registry or an account: the publisher signs one
# root SHA256SUMS with an ssh key (their SIGNING.md), rio checks that signature and
# then checks every file it fetches against those hashes.
#
# TRUSTED WHEN THE USER SAYS SO, with a seed (D119). A repository publishes its
# public key in rio-repository.conf. The first scan that verifies against it does NOT
# record it: it refuses the source as `key_unconfirmed` and offers the fingerprint,
# the way ssh prints one and waits for `yes`. Once confirmed, that key — and only that
# key — speaks for that source; a different key later is refused as `key_changed`
# until the user trusts that one too (D111's shape for a changed certificate). The
# default source ships with the project's own key already trusted, so a fresh rio is
# not asked a question it has no way to answer; the keys window can withdraw even
# that.
#
# WHAT CONFIRMING CANNOT DO, said plainly: an attacker already on the path the very
# first time still gets to offer a marker, a SHA256SUMS and a signature made by their
# own key, and rio has nothing to compare it against. What it buys is that they must
# now get a human to accept a fingerprint the publisher's own page contradicts,
# instead of winning silently and permanently.
#
# The keys live GUI-SIDE, beside sources.list: the sources list is the trust list
# (D39), and a key is a property of an entry in it. The verifying is the CORE's
# (sig.verify), because ssh-keygen must be on the host that has the tool — the same
# split as tcltls and https (D109).

set ::repo_keys {}   ;# scheme-less source -> {key <type+base64> trusted <date> forgotten <date>}
set ::repo_sig  {}   ;# source -> {state signed|unsigned|unverified signer <fp> sums {path hash …}}

# May a repository rio CANNOT check be used anyway? Off by default, and it buys
# exactly one thing: a source whose key is trusted, on a host with no ssh-keygen to
# check it with, lists and installs — marked `unverified` in every place a signed one
# would say `signed`, and named as such in the install consent. It does NOT touch a
# bad signature, a changed key or a mismatched hash: those are refusals whatever this
# says. The same shape as D114's switch for an https that can't check host names —
# fail closed, with one explicit way out that never hides which way was taken.
# (Prefs, not the core's conf, because unlike D114 this governs nothing but the
# Extensions window; the agent's transport is not involved.)
set ::repo_allow_unverified 0   ;# the preference (prefs.json `allow_unverified_repos`)

# The key rio trusts for its own repository out of the box. Published as the `key =`
# line of http://rio.skylm.org/extensions/rio-repository.conf; fingerprint
# SHA256:ThigJDQbjz1G8yvZMJ7grlLlcOA6uS+ZDWvJdJPVfG0, which is the one to confirm
# out of band. A stored entry always wins over this, so trusting a rotation by hand
# is never undone by the seed.
set ::default_repo_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOzSB7e8mVA9R+JndUZAIliRW2sxKlUD5P4AMoZuIzLV"

proc repo_keys_path {} {
	set p [sources_path]
	if {$p eq ""} { return "" }
	return [file join [file dirname $p] repository-keys.conf]
}

# `[<scheme-less source>]` sections carrying `key` and `trusted` — rio's own conf
# format (D21), hand-editable on purpose: deleting a section is how a user takes a
# trust decision back, and is exactly what repo_keys_forget does for them.
#
# A section with NO `key` is meaningful and is kept (D119): it says rio knows this
# source and trusts no key for it. That is the only way to withdraw the key rio ships
# with for its own repository, which is a fallback rather than a stored entry — so
# `forgotten = <date>` beats the seed, and repo_key_of stops falling back to it.
proc repo_keys_load {} {
	set ::repo_keys {}
	set path [repo_keys_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {rio::conf::parse [slurp_utf8 $path]} conf]} return
	dict for {section kv} $conf {
		if {$section eq ""} continue
		dict set ::repo_keys $section [dict create \
			key [expr {[dict exists $kv key] ? [string trim [dict get $kv key]] : ""}] \
			trusted [expr {[dict exists $kv trusted] ? [dict get $kv trusted] : ""}] \
			forgotten [expr {[dict exists $kv forgotten] ? [dict get $kv forgotten] : ""}]]
	}
}

proc repo_keys_save {} {
	set path [repo_keys_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts $f "# Signing keys rio trusts for extension repositories (D118, D119). One section"
		puts $f "# per repository, written when you confirmed that repository's key."
		puts $f "#"
		puts $f "# Delete a section to forget that key: rio then asks again the next time"
		puts $f "# that repository is scanned, and installs nothing from it until you say"
		puts $f "# yes. A section with no key at all means the opposite of trust - rio"
		puts $f "# trusts no key here, not even one it ships with. The same edits are one"
		puts $f "# click in Preferences > Extensions > Repository signing keys..."
		dict for {src e} $::repo_keys {
			puts $f ""
			puts $f "\[$src\]"
			if {[dict get $e key] ne ""} {
				puts $f "key = [dict get $e key]"
				if {[dict get $e trusted] ne ""} { puts $f "trusted = [dict get $e trusted]" }
			} elseif {[dict get $e forgotten] ne ""} {
				puts $f "forgotten = [dict get $e forgotten]"
			}
		}
		close $f
	}
}

# The key trusted for a source, or "". Scheme-less, like source_same: moving a
# repository from http:// to https:// (D109) is a change of route, not of publisher,
# and must not read as a rotated key.
#
# A stored section answers even when it carries no key: "" then means rio trusts
# nothing here, and the seed below is NOT reached — that is what makes the built-in
# key withdrawable (D119).
proc repo_key_of {source} {
	set key [source_key $source]
	dict for {src e} $::repo_keys {
		if {$src eq $key} { return [dict get $e key] }
	}
	if {[source_same $source $::default_repo]} { return $::default_repo_key }
	return ""
}

proc source_key {source} {
	regsub -nocase {^https?://} [string trimright $source /] {} s
	return $s
}

proc repo_key_trust {source key} {
	dict set ::repo_keys [source_key $source] [dict create \
		key $key trusted [clock format [clock seconds] -format %Y-%m-%d] \
		forgotten ""]
	repo_keys_save
}

# The verify seam: sig.verify through the core, never throwing. `datahash` is the
# hash the core itself reported for those bytes when it fetched them, which lets the
# core tell a lost byte apart from a bad signature. Tests stub THIS proc.
proc sig_verify {data sig key principal {datahash ""}} {
	set params [dict create data $data sig $sig key $key principal $principal \
		namespace rio-repository]
	if {$datahash ne ""} { dict set params sha256 $datahash }
	set resp [rio_call sig.verify $params]
	if {![dict get $resp ok]} {
		return [dict create available 0 verified 0 signer "" fingerprint "" \
			reason [dict get $resp error message]]
	}
	return [dict get $resp result]
}

# SHA256SUMS -> {path hash …}. The format `sha256sum` and OpenBSD's `sha256 -r`
# print: a hex digest, whitespace, then the path — with the optional `*` that marks
# a binary-mode hash, and a leading `./` some publishers' `find` leaves behind. A
# line that isn't that shape is skipped: it was signed along with everything else,
# it simply names no file rio will ever fetch.
proc repo_sums_parse {text} {
	set out {}
	foreach line [split $text "\n"] {
		if {![regexp {^([0-9a-fA-F]{64})[ \t]+\*?(.+)$} [string trimright $line "\r"] -> h path]} continue
		set path [string trimleft [string trim $path] "./"]
		if {$path ne ""} { dict set out $path [string tolower $h] }
	}
	return $out
}

# The one-word mark a variant carries in the window: what rio knows about where
# these bytes came from. Deliberately said in all three cases, including the boring
# one — "signed" means nothing to a user who has never seen rio say "unsigned".
proc sig_mark {state} {
	switch -- $state {
		signed     { return "signed" }
		unverified { return "unverified" }
	}
	return "unsigned"
}

# The line above "From:" in the install consent — the same three cases, at the
# length a decision deserves.
proc ext_consent_sig_line {source} {
	set sig [repo_sig_of $source]
	switch -- [dict get $sig state] {
		signed {
			return "Signed by [dict get $sig signer], and every file was checked against that signature."
		}
		unverified {
			return "SIGNED, BUT NOT CHECKED: this repository publishes a signature, and the core's host has no ssh-keygen to check it with. You turned that on in Preferences ▸ Extensions."
		}
	}
	return "NOT SIGNED: nothing vouches for these files. Over plain http, anyone between you and the server could have changed them."
}

# The hash the core reported for a fetch, or "". A core older than D118 answers
# repo.fetch without one however politely it is asked (D30 lets a GUI attach to any
# core), and that is not a detail to discover through a Tcl error mid-scan: it means
# this core cannot check a signature at all, which is the same situation as having no
# ssh-keygen and is handled in the same place.
proc fetch_hash {r} {
	if {[dict exists $r sha256]} { return [dict get $r sha256] }
	return ""
}

proc repo_sig_of {source} {
	if {[dict exists $::repo_sig $source]} { return [dict get $::repo_sig $source] }
	return [dict create state unsigned signer "" sums {}]
}

# Is `path` (relative to the repository root) allowed to be what we just fetched?
# On an unsigned or unverifiable source there is nothing to check against and the
# answer is yes — that is what those words mean. On a SIGNED one, a file rio fetches
# must be in SHA256SUMS with that hash: a file the sums don't mention is as bad as
# one whose hash differs, because a publisher's SHA256SUMS covers everything served.
proc repo_file_ok {source path hash} {
	set sig [repo_sig_of $source]
	if {[dict get $sig state] ne "signed"} { return 1 }
	if {$hash eq ""} { return 0 }   ;# asked for, not answered: check nothing, trust nothing
	set sums [dict get $sig sums]
	if {![dict exists $sums $path]} { return 0 }
	return [expr {[string tolower $hash] eq [dict get $sums $path]}]
}

# Decide what a source's signature says, BEFORE anything else is fetched from it.
# `markerhash` is the hash of the rio-repository.conf we already have, checked here
# against the sums it must itself be listed in.
#
# Returns {ok 1 state … signer … sums …} or {ok 0 code … error … ?key …?}. Every
# refusal is the WHOLE source: a signed repository is signed as one thing, and
# "most of it verified" is not a state a user can act on.
# "This signature cannot be checked here" — no ssh-keygen, one too old, a core that
# can't hash, or a core that doesn't know sig.verify at all. NOT the same as a
# signature that failed, and never allowed to become it.
#
# A source nobody has trusted yet loses nothing by listing as unsigned: rio was not
# going to check anything for it either way. One whose key IS trusted would lose the
# whole point of having trusted it, so it is refused — unless the user turned the
# switch on, and then it lists loudly as `unverified`.
proc _sig_cant_check {trusted why} {
	if {$trusted eq ""} {
		return [dict create ok 1 state unsigned signer "" sums {}]
	}
	if {$::repo_allow_unverified} {
		return [dict create ok 1 state unverified signer "" sums {}]
	}
	return [dict create ok 0 code sig_no_tool \
		error "rio can't check this repository's signature: $why. Fix that on the core's host — openssh 8.0 or newer, and a rio core new enough to hash what it fetches — or, to use the repository unchecked, turn on Preferences ▸ Extensions ▸ \"Use repositories rio can't check\"."]
}

proc repo_sig_check {base pubkey markerhash} {
	set trusted [repo_key_of $base]
	if {$pubkey eq "" && $trusted eq ""} {
		return [dict create ok 1 state unsigned signer "" sums {}]
	}
	# No downgrade (D118): a repository that was signed and now isn't is refused,
	# because that is exactly what removing a signature would look like.
	if {$pubkey eq ""} {
		return [dict create ok 0 code sig_dropped \
			error "This repository used to be signed and no longer publishes a key. rio won't quietly stop checking: if the publisher really dropped signing, delete its section from repository-keys.conf."]
	}
	if {$trusted ne "" && $pubkey ne $trusted} {
		return [dict create ok 0 code key_changed key $pubkey \
			error "This repository is now signed by a DIFFERENT key than the one rio trusted. That is what a key rotation looks like — and also what someone impersonating the repository looks like. Review the new key before trusting it."]
	}
	set sr [repo_fetch $base/SHA256SUMS 1]
	set gr [repo_fetch $base/SHA256SUMS.sig]
	set have [expr {[dict get $sr ok] && [dict get $sr status] == 200
		&& [dict get $gr ok] && [dict get $gr status] == 200}]
	if {!$have} {
		if {$trusted eq ""} {
			# Nothing was trusted here yet and there is no signature to trust: the
			# publisher announced a key and published nothing to check with it.
			return [dict create ok 1 state unsigned signer "" sums {}]
		}
		return [dict create ok 0 code sig_missing \
			error "This repository is signed, but SHA256SUMS or SHA256SUMS.sig couldn't be fetched from it. A publish that uploaded the payloads and not the signature looks exactly like this."]
	}
	# A core older than D118 hashes nothing, however it is asked: no hash, no way to
	# check a single file even if the signature itself verified. Same situation as no
	# ssh-keygen, so the same answer — and found HERE, rather than as a Tcl error at
	# the first file compared.
	if {$markerhash eq "" || [fetch_hash $sr] eq ""} {
		return [_sig_cant_check $trusted \
			"the core this GUI is attached to is older than rio's repository signing and can't hash what it fetches"]
	}
	set v [sig_verify [dict get $sr text] [dict get $gr text] $pubkey $base [fetch_hash $sr]]
	if {![dict get $v available]} {
		return [_sig_cant_check $trusted [dict get $v reason]]
	}
	if {![dict get $v verified]} {
		return [dict create ok 0 code sig_bad \
			error "The signature on this repository doesn't verify: [dict get $v reason]. Until it does, rio won't install anything from it — the files may have been altered after they were published."]
	}
	set sums [repo_sums_parse [dict get $sr text]]
	# The marker carried the key, so it must be covered by the sums it pointed at —
	# checked AFTER verification, and before the key is trusted for the first time.
	if {![dict exists $sums rio-repository.conf]
			|| [dict get $sums rio-repository.conf] ne [string tolower $markerhash]} {
		return [dict create ok 0 code hash_mismatch \
			error "The signature verifies, but rio-repository.conf isn't the file it vouches for. The repository's SHA256SUMS is out of date, or these files are not the ones that were signed."]
	}
	# First sight (D119). The signature verifies and the marker is the file it vouches
	# for — so there IS a key worth confirming, and rio can show a fingerprint that
	# means something. It still refuses until the user says yes, the way ssh does:
	# recording it here would hand a first-scan impostor a permanent trust decision the
	# user never took, and rio would then defend that key faithfully forever.
	if {$trusted eq ""} {
		return [dict create ok 0 code key_unconfirmed key $pubkey \
			error "This repository signs with a key rio has never been told to trust. Nothing is installed or listed from it until you confirm that key — review its fingerprint, and check it against the publisher's own page before you accept."]
	}
	return [dict create ok 1 state signed signer [dict get $v signer] sums $sums]
}

# --- the provenance ledger ----------------------------------------------------
proc ledger_path {} {
	if {[info exists ::env(XDG_DATA_HOME)] && $::env(XDG_DATA_HOME) ne ""} {
		set base $::env(XDG_DATA_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .local share]
	} else { return "" }
	return [file join $base rio extensions.json]
}

# Machine-written JSON: {"kind/name": {source, dir, version, installed,
# files:[…], ?anysource?}, …}. Corrupt or missing -> an empty ledger, never fatal
# — the worst outcome is "rio forgot where an extension came from", not a crash.
# `anysource` (D107) is NOT in the required set: it arrived later, and every
# ledger written before it must keep loading. Absent means 0.
proc ledger_load {} {
	set ::ext_ledger {}
	set path [ledger_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {
		set d [json::json2dict [slurp_utf8 $path]]
		dict for {key e} $d {
			foreach k {source dir version files installed} {
				if {![dict exists $e $k]} { error "entry $key missing $k" }
			}
		}
		set ::ext_ledger $d
	}]} { set ::ext_ledger {} }
}

proc ledger_entry_json {e} {
	set parts {}
	foreach k {source dir version installed} {
		lappend parts "[rio::wire::str $k]:[rio::wire::str [dict get $e $k]]"
	}
	lappend parts "\"files\":[rio::wire::strarr [dict get $e files]]"
	# Written only when SET, so an untouched ledger keeps its pre-D107 shape.
	if {[dict exists $e anysource] && [dict get $e anysource]} {
		lappend parts "\"anysource\":\"1\""
	}
	# The key that vouched for these files, when there was one (D118) — same rule.
	if {[dict exists $e signed_by] && [dict get $e signed_by] ne ""} {
		lappend parts "\"signed_by\":[rio::wire::str [dict get $e signed_by]]"
	}
	return "{[join $parts ,]}"
}

proc ledger_save {} {
	set path [ledger_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f [rio::wire::objmap $::ext_ledger ledger_entry_json]
		close $f
	}
}

# --- fetching & scanning ------------------------------------------------------

# The one fetch seam: repo.fetch through the core, never throwing — the return
# is {ok 1 status <n> text <t> ?sha256 <hex>?} or {ok 0 error <msg> code <code>}.
# `code` is the taxonomy's (D11) — untrusted_cert is the one the window acts on
# (D111). `hash` asks the core for the hash of the bytes it received (D118), which
# is the only place that hash can honestly be taken: the text here has been decoded
# and re-encoded on its way through the wire. Tests stub THIS proc with a fixture
# table (no network in tests, D39).
proc repo_fetch {url {hash 0}} {
	set params [dict create url $url]
	if {$hash} { dict set params sha256 1 }
	set resp [rio_call repo.fetch $params]
	if {[dict get $resp ok]} {
		set out [dict create ok 1 status [dict get $resp result status] \
			text [dict get $resp result text]]
		if {[dict exists $resp result sha256]} {
			dict set out sha256 [dict get $resp result sha256]
		}
		return $out
	}
	return [dict create ok 0 error [dict get $resp error message] \
		code [dict get $resp error code]]
}

# The `index` file: one extension-subdir name per line, # comments. A line
# that fails the safe-name rule is skipped, not fatal — one bad entry must not
# hide the rest of a repository.
proc repo_parse_index {text} {
	set dirs {}
	foreach line [split $text "\n"] {
		set t [string trim $line]
		if {$t eq "" || [string index $t 0] eq "#"} continue
		if {[ext_safe_name $t] && $t ni $dirs} { lappend dirs $t }
	}
	return $dirs
}

# The autoindex fallback: when a repository omits `index`, the server's own
# directory listing stands in. One tolerant pass — every href ending in "/"
# whose name passes the safe-name rule is a candidate subdirectory; that one
# filter drops ../, absolute URLs, query links (Apache's ?C=N;O=D), and any
# percent-encoded name in a single stroke. Verified against canned Apache,
# nginx, and OpenBSD-httpd listings in the test suite.
proc repo_parse_autoindex {html} {
	set dirs {}
	foreach {m name} [regexp -all -inline -nocase {href="([^"]+)/"} $html] {
		if {[ext_safe_name $name] && $name ni $dirs} { lappend dirs $name }
	}
	return $dirs
}

# Scan ONE source: the marker manifest (required — anything without a parseable
# rio-repository.conf carrying name= is "not a rio repository"), then its signature
# if it has one (D118), then the extension list (index, else autoindex), then each
# extension's manifest.
# Returns {ok 1 name <n> description <d> sig <state> signer <fp> sums {…}
# exts {<variant>…}} or {ok 0 error <e> ?code <c>?}; a malformed extension manifest
# skips that extension, never the source — but a file that fails its signed hash
# takes the whole source down, because a signed repository is signed as one thing.
# A variant dict: {source dir name kind version author description files sig signer}.
proc repo_source_scan {base} {
	set base [string trimright $base /]
	set r [repo_fetch $base/rio-repository.conf 1]
	if {![dict get $r ok]} {
		return [dict create ok 0 error [dict get $r error] \
			code [expr {[dict exists $r code] ? [dict get $r code] : ""}]]
	}
	if {[dict get $r status] != 200
			|| [catch {rio::conf::parse [dict get $r text]} conf]
			|| ![dict exists $conf "" name]} {
		return [dict create ok 0 error "not a rio repository (no usable rio-repository.conf)"]
	}
	set srcname [dict get $conf "" name]
	set srcdesc [expr {[dict exists $conf "" description] ? [dict get $conf "" description] : ""}]
	# What this source's signature says, before a single payload is considered. The
	# answer is recorded in ::repo_sig FIRST, because repo_file_ok reads it there for
	# every file fetched below.
	set sig [repo_sig_check $base \
		[expr {[dict exists $conf "" key] ? [string trim [dict get $conf "" key]] : ""}] \
		[expr {[dict exists $r sha256] ? [dict get $r sha256] : ""}]]
	if {![dict get $sig ok]} {
		dict unset ::repo_sig $base
		return [dict create ok 0 error [dict get $sig error] code [dict get $sig code] \
			newkey [expr {[dict exists $sig key] ? [dict get $sig key] : ""}]]
	}
	dict set ::repo_sig $base [dict create state [dict get $sig state] \
		signer [dict get $sig signer] sums [dict get $sig sums]]
	set signed [expr {[dict get $sig state] eq "signed"}]
	set dirs {}
	set ir [repo_fetch $base/index $signed]
	if {[dict get $ir ok] && [dict get $ir status] == 200} {
		if {$signed && ![repo_file_ok $base index [fetch_hash $ir]]} {
			return [repo_hash_refusal $base index]
		}
		set dirs [repo_parse_index [dict get $ir text]]
	} else {
		# The autoindex is the SERVER's own listing, not a file of the repository, so
		# there is nothing it could be checked against. It costs nothing: every
		# directory it names still has to produce a manifest the sums vouch for.
		set ar [repo_fetch $base/]
		if {[dict get $ar ok] && [dict get $ar status] == 200} {
			set dirs [repo_parse_autoindex [dict get $ar text]]
		}
	}
	set exts {}
	foreach d $dirs {
		set mr [repo_fetch $base/$d/rio-extension.conf $signed]
		if {![dict get $mr ok] || [dict get $mr status] != 200} continue
		if {$signed && ![repo_file_ok $base $d/rio-extension.conf [fetch_hash $mr]]} {
			return [repo_hash_refusal $base $d/rio-extension.conf]
		}
		if {[catch {rio::conf::parse [dict get $mr text]} mc]} continue
		set top [expr {[dict exists $mc ""] ? [dict get $mc ""] : {}}]
		set ok 1
		foreach k {name kind version files} {
			if {![dict exists $top $k]} { set ok 0 }
		}
		if {!$ok} continue
		set name [dict get $top name]
		set kind [dict get $top kind]
		if {![ext_safe_name $name] || ![ext_safe_name $kind]} continue
		set files {}
		foreach f [split [dict get $top files]] {
			if {$f eq ""} continue
			if {![ext_safe_name $f]} { set ok 0 ; break }
			lappend files $f
		}
		if {!$ok || ![llength $files]} continue
		set variant [dict create \
			source $base dir $d name $name kind $kind \
			sig [dict get $sig state] signer [dict get $sig signer] \
			version [dict get $top version] \
			author [expr {[dict exists $top author] ? [dict get $top author] : "unknown"}] \
			description [expr {[dict exists $top description] ? [dict get $top description] : ""}] \
			files $files manifest [dict get $mr text]]
		# A kind whose surface carries a VERSIONED contract declares which level it
		# needs, and is greyed when that is past what this rio implements (D66, D123).
		# ext_kind_api knows the manifest key and the ceiling per kind; a kind with no
		# contract (syntax, theme) sets nothing and is never too new.
		set contract [ext_kind_api $kind]
		if {$contract ne ""} {
			lassign $contract key ceiling dflt
			set api [expr {[dict exists $top $key] ? [dict get $top $key] : $dflt}]
			dict set variant api $api
			dict set variant too_new [expr {
				![string is integer -strict $api] || $api > $ceiling}]
		}
		# A provider (D66) installs CORE-side and is sourced into the core, so unlike
		# every other kind it names the one file the core will source.
		if {$kind eq "provider"} {
			dict set variant entry [expr {[dict exists $top entry] ? [dict get $top entry] : ""}]
		}
		lappend exts $variant
	}
	return [dict create ok 1 name $srcname description $srcdesc exts $exts \
		sig [dict get $sig state] signer [dict get $sig signer]]
}

# One wording for "this file is not the file the signature vouches for", wherever it
# is found. It names the file, because "the repository changed" is not actionable and
# "vi/vi.tcl isn't what was signed" is.
proc repo_hash_refusal {base path} {
	dict unset ::repo_sig $base
	return [dict create ok 0 code hash_mismatch \
		error "$path is not the file this repository's signature vouches for. Either it was changed after SHA256SUMS was signed — an upload that didn't re-sign looks like this — or it was changed in transit."]
}

# Scan every configured source into ::repo_variants / ::repo_dead /
# ::repo_srcinfo. A dead source is one honest row, never a failed scan.
# `progress` (optional command prefix) is told each source URL as it starts —
# the Extensions window's status line.
proc repo_scan_all {{progress ""}} {
	set ::repo_variants {}
	set ::repo_dead {}
	set ::repo_srcinfo {}
	set ::repo_sig {}
	repo_keys_load   ;# the file is hand-editable (D118), so re-read it per scan
	set srcs [sources_load]
	set n 0
	foreach src $srcs {
		incr n
		if {$progress ne ""} { {*}$progress $src $n [llength $srcs] }
		set s [repo_source_scan $src]
		if {![dict get $s ok]} {
			lappend ::repo_dead [list $src [dict get $s error] \
				[expr {[dict exists $s code] ? [dict get $s code] : ""}] \
				[expr {[dict exists $s newkey] ? [dict get $s newkey] : ""}]]
			continue
		}
		dict set ::repo_srcinfo $src [dict create \
			name [dict get $s name] description [dict get $s description]]
		foreach v [dict get $s exts] { lappend ::repo_variants $v }
	}
	ext_installed_compute
	ext_updates_compute
}

# --- what is installed, and what is an update (AGENTS.md D107) -----------------

# The installed view: "kind/name" -> {version source}. The ledger is the base —
# but for a PROVIDER the core wins, because a provider installs core-side and
# provider.list reports the store's own truth ({name, version, source}, D66).
# That is D39's recorded ledger caveat answered where it actually bites: a
# provider installed by another frontend, or onto a remote core, still shows its
# real version here and still gets update tracking.
#
# This view is DERIVED and never written back to extensions.json: a GUI that
# talks to two cores in turn would otherwise persist one core's answer as what
# it believes it installed on the other.
proc ext_installed_compute {} {
	set ::ext_installed {}
	dict for {key e} $::ext_ledger {
		dict set ::ext_installed $key [dict create \
			version [dict get $e version] source [dict get $e source]]
	}
	dict for {name p} $::ext_core_providers {
		dict set ::ext_installed provider/$name $p
	}
}

# Ask the core which providers its store holds, at which versions (D66's op, put
# to a second use). Best effort: an old core without provider.list, or a failed
# call, leaves the ledger to speak for providers as it did before.
proc ext_core_providers_refresh {} {
	set ::ext_core_providers {}
	set pr [rio_call provider.list {}]
	if {![dict get $pr ok]} return
	if {[dict exists $pr result api_max]} {
		set ::provider_api_max [dict get $pr result api_max]
	}
	if {![dict exists $pr result providers]} return
	foreach p [dict get $pr result providers] {
		if {![dict exists $p name] || ![dict exists $p version]} continue
		# echo is the built-in stub, not an installed extension — it has no source.
		set src [expr {[dict exists $p source] ? [dict get $p source] : ""}]
		if {$src eq ""} continue
		dict set ::ext_core_providers [dict get $p name] \
			[dict create version [dict get $p version] source $src]
	}
}

# Whether an extension takes updates from repositories OTHER than the one it was
# installed from. Off by default, and that default is the safe direction: with no
# central index nobody is forced to respect a namespace, so `vi` on another host
# may be an entirely different program that merely shares a name (jka, D107).
# Switching to it stays possible — as an INSTALL, with the consent that names the
# new source — it just is not an "update".
proc ext_anysource {key} {
	if {![dict exists $::ext_ledger $key]} { return 0 }
	set e [dict get $::ext_ledger $key]
	return [expr {[dict exists $e anysource] && [dict get $e anysource] ? 1 : 0}]
}

proc ext_anysource_set {key on} {
	if {![dict exists $::ext_ledger $key]} return
	dict set ::ext_ledger $key anysource [expr {$on ? 1 : 0}]
	ledger_save
	ext_updates_compute
}

# Is this variant an update to what is installed? Returns the installed version it
# would replace, or "" for anything that is not an update — not installed, an
# unparseable version on either side (no claim, D107), the same or a lower
# version, a foreign source without the flag, or a variant this rio can't install
# anyway (an unknown kind, a provider needing a newer provider-api: never offer an
# update that would be refused).
proc ext_variant_update {v} {
	set key "[dict get $v kind]/[dict get $v name]"
	if {![dict exists $::ext_installed $key]} { return "" }
	if {[dict exists $v offline]} { return "" }
	if {![ext_variant_installable $v]} { return "" }
	set cur [dict get $::ext_installed $key]
	if {![source_same [dict get $v source] [dict get $cur source]] && ![ext_anysource $key]} { return "" }
	if {[ext_ver_cmp [dict get $v version] [dict get $cur version]] != 1} { return "" }
	return [dict get $cur version]
}

# "kind/name" -> {from to variant}: one pending update per extension, the highest
# on offer when several sources qualify (only possible with anysource set).
proc ext_updates_compute {} {
	set ::ext_updates {}
	foreach v $::repo_variants {
		set from [ext_variant_update $v]
		if {$from eq ""} continue
		set key "[dict get $v kind]/[dict get $v name]"
		if {[dict exists $::ext_updates $key]} {
			set have [dict get [dict get $::ext_updates $key] to]
			if {[ext_ver_cmp [dict get $v version] $have] != 1} continue
		}
		dict set ::ext_updates $key [dict create \
			from $from to [dict get $v version] variant $v]
	}
}

# --- installing & removing ----------------------------------------------------

# The kind -> install-target map: the ONLY version-specific piece of the whole
# format (D39's forward-compatibility contract). A kind not listed here still
# LISTS in the window — greyed "(needs a newer rio)" — it just can't install.
proc ext_kind_known {kind} {
	return [expr {$kind in {syntax mode theme provider}}]
}

proc ext_kind_dir {kind} {
	switch -- $kind {
		syntax { return [hl_user_dir] }
		mode   { return [modes_user_dir] }
	}
	return ""
}

# The VERSIONED CONTRACT a kind binds to, as {manifest-key ceiling default}, or ""
# for a kind that has none (D123). Only a surface that can BREAK gets one: a provider
# is sourced into the core (D66) and a mode into the frontend (modes/registry.tcl), and
# the mode surface is the one ROADMAP says will change. A theme binds to the additive
# D24 role table and syntax is stable today, so a number there would be one nothing
# ever checks.
#
# The DEFAULT is the difference between the two. A provider with no `provider-api` is
# refused outright (the core has required it since providers became installable, so ""
# fails the integer test below and greys the row). A mode with no `mode-api` is read as
# 1: modes have shipped without the key since D38, and making it mandatory now would
# grey `vi` and `emacs` out of the live repository until every manifest is re-signed.
# That is the D19 forward-compatibility rule, and it costs nothing — the key only
# starts carrying weight when there is a mode-api 2.
proc ext_kind_api {kind} {
	switch -- $kind {
		provider { return [list provider-api $::provider_api_max ""] }
		mode     { return [list mode-api     $::mode_api_max     1] }
	}
	return ""
}

# Whether THIS rio can install a given variant. A kind it doesn't know can't be
# installed (forward-compat); nor can one whose declared contract level is past what
# this rio implements (`too_new`, set at scan time by ext_kind_api's ceiling).
proc ext_variant_installable {v} {
	if {![ext_kind_known [dict get $v kind]]} { return 0 }
	if {[dict exists $v too_new] && [dict get $v too_new]} { return 0 }
	return 1
}

# A row is greyed ("needs a newer rio") when none of its variants can be installed
# here — an unknown kind, or one whose every variant needs a newer contract level.
proc ext_row_installable {row} {
	foreach v [dict get $row variants] {
		if {[ext_variant_installable $v]} { return 1 }
	}
	return 0
}

# Does any OTHER ledger entry of this kind own one of these payload filenames?
# Payloads of one kind share a flat drop-in dir, so a name collision would let
# extension B silently overwrite extension A's file — refuse instead.
proc ext_file_owner {kind name files} {
	dict for {key e} $::ext_ledger {
		lassign [split $key /] ekind ename
		if {$ekind ne $kind || $ename eq $name} continue
		foreach f $files {
			if {$f in [dict get $e files]} { return $ename }
		}
	}
	return ""
}

# Install one variant (a dict out of ::repo_variants): consent -> fetch ALL
# payloads -> write -> activate -> ledger. Returns 1 installed / 0 not.
# Nothing is written until every payload arrived intact, and a half-failed
# write rolls the files back — an install is all-or-nothing on disk.
#
# `consented` is set only by Update All (D107), which asked ONCE for the whole
# batch — a summary listing every extension, its version change and its source.
# It suppresses this dialog and nothing else: the collision refusal, the
# fetch-everything-first rule, the rollback and the ledger write are unchanged.
proc ext_install {variant {consented 0}} {
	dict with variant {}  ;# source dir name kind version author description files
	if {![ext_kind_known $kind]} {
		report_error "'$name' has kind '$kind', which this rio doesn't know — it needs a newer rio."
		return 0
	}
	# The contract level, refused HERE and not only greyed in the list (D123). Greying is
	# the UI telling the user; this is the enforcement, and until D123 there was none: a
	# too-new PROVIDER was stopped by the core's own `put`, which is a check a mode — a
	# frontend drop-in with no core in the path — does not get. Refusing at the one place
	# every install funnels through covers both, and any kind that gains a contract later.
	if {[dict exists $variant too_new] && [dict get $variant too_new]} {
		lassign [ext_kind_api $kind] _key ceiling
		report_error "'$name' needs $_key [dict get $variant api], but this rio implements\
			$ceiling — it needs a newer rio."
		return 0
	}
	set key $kind/$name
	# Consent, stated honestly: code is code, data is data, and the source URL
	# is the provenance the user is trusting.
	if {$kind eq "theme"} {
		set what "'$name' is a THEME: colour/font data, parsed and never executed."
	} elseif {$kind eq "provider"} {
		set what "'$name' is an agent PROVIDER: Tcl code that runs inside the rio CORE\
			(which may be a remote or shared host), can receive the API key you enter for\
			it, and makes network requests with it. Install only from a source you trust\
			with your model credentials."
	} else {
		set what "'$name' is Tcl CODE that will run inside your editor with your permissions."
	}
	set msg "Install $kind '$name' $version by $author?\n\n$what\n\nFrom: $source\n[ext_consent_sig_line $source]"
	if {[dict exists $::ext_installed $key]} {
		set old [dict get $::ext_installed $key]
		set msg "$msg\n\nReplaces the installed '$name' [dict get $old version] from [dict get $old source]."
	}
	if {!$consented && [tk_messageBox -icon warning -type yesno -title "rio — install extension" \
			-message $msg] ne "yes"} { return 0 }
	# Payloads of one kind share a flat drop-in dir (syntax/mode) — a name owned by
	# another installed extension would be silently overwritten, so refuse. A
	# provider (D66) lives in its OWN core-side dir, so filenames never collide
	# across providers; the check does not apply to it.
	if {$kind ne "provider"} {
		set owner [ext_file_owner $kind $name $files]
		if {$owner ne ""} {
			report_error "Cannot install '$name': its payload would overwrite files owned by the installed $kind '$owner'."
			return 0
		}
	}
	# Fetch everything first; only then touch disk. On a signed source every payload
	# is checked against the signature's hashes HERE, inside that rule — so a file
	# that isn't what was signed aborts with nothing written, and the repository
	# having changed under a stale scan reads as what it is.
	set signed [expr {[dict get [repo_sig_of $source] state] eq "signed"}]
	set payload {}
	foreach f $files {
		set r [repo_fetch $source/$dir/$f $signed]
		if {![dict get $r ok] || [dict get $r status] != 200} {
			set why [expr {[dict get $r ok] ? "HTTP [dict get $r status]" : [dict get $r error]}]
			report_error "Install of '$name' aborted: $f could not be fetched ($why). Nothing was changed."
			return 0
		}
		if {$signed && ![repo_file_ok $source $dir/$f [fetch_hash $r]]} {
			report_error "Install of '$name' aborted: $dir/$f is not the file this repository's\
				signature vouches for. Refresh the list — if the publisher re-uploaded without\
				re-signing, the list you are looking at is older than the files. Nothing was changed."
			return 0
		}
		dict set payload $f [dict get $r text]
	}
	if {$kind eq "theme"} {
		if {![ext_install_theme $name $payload]} { return 0 }
	} elseif {$kind eq "provider"} {
		if {![ext_install_provider $name $manifest $payload $source]} { return 0 }
	} else {
		if {![ext_install_files $kind $name $payload]} { return 0 }
	}
	# A provider's installed version is read back from the core (ext_installed_compute),
	# and the store just changed under us — record it rather than re-asking, so the row
	# shows the version that was actually written.
	if {$kind eq "provider"} {
		dict set ::ext_core_providers $name [dict create version $version source $source]
	}
	set entry [dict create \
		source $source dir $dir version $version files $files \
		installed [clock format [clock seconds] -format %Y-%m-%d]]
	# The cross-source flag is the USER's setting for this extension, not a property
	# of the payload — an update must not silently reset it (D107).
	if {[ext_anysource $key]} { dict set entry anysource 1 }
	# Provenance now includes WHO vouched for these bytes (D118). Written only when
	# there was a signature, so a ledger that never met one keeps its old shape.
	set sigstate [repo_sig_of $source]
	if {[dict get $sigstate state] eq "signed" && [dict get $sigstate signer] ne ""} {
		dict set entry signed_by [dict get $sigstate signer]
	}
	dict set ::ext_ledger $key $entry
	ledger_save
	ext_installed_compute
	ext_updates_compute
	return 1
}

# Write syntax/mode payloads into the kind's drop-in dir, then reload that
# machinery so the extension is live at once — install is drop-the-file, the
# same act as D32/D38 by hand, just performed by rio. Failure rolls back:
# previously-existing files are restored, fresh ones removed.
proc ext_install_files {kind name payload} {
	set dstdir [ext_kind_dir $kind]
	if {$dstdir eq ""} { report_error "No user $kind directory resolvable (no HOME?)." ; return 0 }
	set undo {}
	if {[catch {
		file mkdir $dstdir
		dict for {f text} $payload {
			set p [file join $dstdir $f]
			if {[file exists $p]} {
				set old [open $p r] ; fconfigure $old -encoding utf-8
				lappend undo restore $p [::read $old] ; close $old
			} else {
				lappend undo delete $p ""
			}
			set out [open $p {WRONLY CREAT TRUNC}] ; fconfigure $out -encoding utf-8
			puts -nonewline $out $text ; close $out
		}
	} err]} {
		foreach {what p text} $undo {
			catch {
				if {$what eq "delete"} { file delete $p } else {
					set out [open $p {WRONLY CREAT TRUNC}] ; fconfigure $out -encoding utf-8
					puts -nonewline $out $text ; close $out
				}
			}
		}
		report_error "Install of '$name' failed writing files: $err. Rolled back."
		return 0
	}
	ext_reload $kind
	return 1
}

# Themes install CORE-side through theme.put — each payload file becomes the
# theme named by its rootname (night.theme -> night), validated by the core
# before anything lands. On a partial failure the already-put files of this
# install are deleted again (best effort — the core validated them going in,
# so in practice the first failure is also the last).
proc ext_install_theme {name payload} {
	set put {}
	dict for {f text} $payload {
		set tname [file rootname $f]
		set resp [rio_call theme.put [dict create name $tname text $text]]
		if {![dict get $resp ok]} {
			foreach t $put { catch {rio_call theme.delete [dict create name $t]} }
			report_error "Install of theme '$name' failed at $f: [dict get $resp error message]" \
				[dict get $resp error code]
			return 0
		}
		lappend put $tname
	}
	ext_reload theme
	return 1
}

# Install a provider CORE-side through provider.put (D66) — like a theme, its code
# is the CORE's (a remote core stores on its own disk), so it lands there, not in
# the frontend's dirs. The core validates the manifest (kind, provider-api, entry,
# every name) before writing. It is NOT sourced now: a provider activates on the
# core's next start (restart-to-activate), so on success we say so plainly.
proc ext_install_provider {name manifest payload source} {
	set resp [rio_call provider.put [dict create \
		name $name manifest $manifest files $payload source $source]]
	if {![dict get $resp ok]} {
		report_error "Install of provider '$name' failed: [dict get $resp error message]" \
			[dict get $resp error code]
		return 0
	}
	tk_messageBox -icon info -type ok -title "rio — provider installed" \
		-message "Installed the agent provider '$name'.\n\nIt becomes available the next\
			time the rio core starts — restart rio to use it."
	return 1
}

# Remove an installed extension by ledger key parts. Files (or core-side
# themes) go first, the ledger entry last — a failed delete leaves the entry,
# so Remove can be retried; a vanished file is already what delete wanted.
proc ext_remove {kind name} {
	set key $kind/$name
	if {![dict exists $::ext_ledger $key]} {
		# A provider the CORE holds but this GUI's ledger doesn't know — installed by
		# another frontend, or onto a shared core (D107). provider.delete takes a name
		# and nothing else, so Remove works without an entry to consult.
		if {$kind eq "provider" && [dict exists $::ext_core_providers $name]} {
			catch {rio_call provider.delete [dict create name $name]}
			dict unset ::ext_core_providers $name
			ext_installed_compute
			ext_updates_compute
			return 1
		}
		return 0
	}
	set e [dict get $::ext_ledger $key]
	if {$kind eq "theme"} {
		foreach f [dict get $e files] {
			catch {rio_call theme.delete [dict create name [file rootname $f]]}
		}
	} elseif {$kind eq "provider"} {
		catch {rio_call provider.delete [dict create name $name]}
		dict unset ::ext_core_providers $name
	} else {
		set dstdir [ext_kind_dir $kind]
		foreach f [dict get $e files] {
			catch {file delete [file join $dstdir $f]}
		}
	}
	dict unset ::ext_ledger $key
	ledger_save
	ext_installed_compute
	ext_updates_compute
	ext_reload $kind
	return 1
}

# Re-arm the machinery a kind plugs into, after an install or a removal:
#   syntax — reload the scanner registry, re-pick and re-paint every group;
#   mode   — reload, refill the menu, re-attach (apply_editmode falls back to
#            windows if the active mode was just removed);
#   theme  — nothing to refill (the picker lists theme.list on open, D92); if the
#            ACTIVE theme changed under us, re-apply it — or fall back to default
#            if it was removed.
proc ext_reload {kind} {
	switch -- $kind {
		syntax {
			hl_load
			foreach g $::groups { hl_select $g ; hl_reset $g }
		}
		mode {
			modes_load
			modes_menu_fill
			apply_editmode
		}
		theme {
			if {$::theme_name ne "default"} {
				set resp [rio_call theme.get [dict create name $::theme_name]]
				if {[dict get $resp ok]} {
					apply_theme [dict get $resp result]
				} else {
					do_theme default
				}
			}
		}
		provider {
			# Nothing to re-arm live: a provider is sourced by the CORE at startup
			# (restart-to-activate, D66). An install/remove changes the store on disk;
			# it takes effect on the core's next start, so there is no reload here.
		}
	}
}

# Update everything ::ext_updates lists, under ONE consent (AGENTS.md D107) —
# apt's shape, and the reasoning is apt's too: you already trusted each of these
# source+extension pairs when you installed them, so an update is not a fresh
# trust decision, and N dialogs for N updates is a prompt people click through.
#
# The exception is spelled out in its own paragraph of the same dialog: an update
# taken from a DIFFERENT repository than the one it was installed from (only
# possible where the user set that extension's cross-source flag) IS a trust
# decision, because nothing makes two repositories agree on what a name means.
#
# ::ext_updates is snapshotted first — each install recomputes it.
proc ext_update_all {} {
	set pending $::ext_updates
	if {![dict size $pending]} { return 0 }
	set same {} ; set foreign {}
	foreach key [lsort [dict keys $pending]] {
		set u [dict get $pending $key]
		lassign [split $key /] kind name
		set v [dict get $u variant]
		set line [format "  %-16s %s → %s   %s (%s)" \
			"$name ($kind)" [dict get $u from] [dict get $u to] \
			[host_of [dict get $v source]] \
			[sig_mark [expr {[dict exists $v sig] ? [dict get $v sig] : "unsigned"}]]]
		if {[dict exists $::ext_installed $key]
				&& [source_same [dict get $v source] [dict get [dict get $::ext_installed $key] source]]} {
			lappend same $line
		} else {
			lappend foreign $line
		}
	}
	set msg "Update [dict size $pending] extension(s)?\n"
	if {[llength $same]} {
		append msg "\nFrom the repository each was installed from:\n[join $same "\n"]\n"
	}
	if {[llength $foreign]} {
		append msg "\nFrom a DIFFERENT repository than the one it was installed from —\
			a name is not owned by anyone, so check you mean these:\n[join $foreign "\n"]\n"
	}
	append msg "\nEach is re-installed from its repository. Modes and highlighters are code\
		that runs in your editor; providers are code that runs in your core."
	if {[tk_messageBox -icon warning -type yesno -title "rio — update extensions" \
			-message $msg] ne "yes"} { return 0 }
	set done 0
	foreach key [lsort [dict keys $pending]] {
		if {[ext_install [dict get [dict get $pending $key] variant] 1]} { incr done }
	}
	return $done
}

# ---------------------------------------------------------------------------
# The Extensions window (AGENTS.md D39; moved to Settings in D67): Settings ▸ Extensions… — where the user
# browses every configured repository, chooses BETWEEN same-name extensions
# (different authors, different versions — each variant its own line with its
# provenance), installs, and removes. Naming: the WINDOW is "Extensions" (what
# you browse); the SOURCES are "Repositories" (where they come from) — the
# header's `Repositories…` button edits sources.list.
#
# Deliberately a NON-MODAL toplevel (no grab, no tkwait): browsing repositories
# is a side activity, not a question blocking the editor — and this is rio's
# first D35-style tool window, to be re-hosted into a dock site when D35 lands.
# Non-modal means re-entry is real: ::repo_busy guards it — one scan or install
# at a time, action buttons disabled meanwhile (the sequential core_calls pump
# the event loop, so the editor itself stays live throughout).
#
# The list aggregates ONE row per (kind, name); the detail below it lists every
# VARIANT of the selected row. Unknown kinds are listed greyed ("needs a newer
# rio" — the forward-compat contract), dead sources get one honest `!!` row
# each, and an installed extension whose source vanished is synthesized from
# the ledger so Remove always works.
# ---------------------------------------------------------------------------

set ::repo_busy 0     ;# a scan or install is running: action buttons disabled
set ::extw_rows {}    ;# row dicts, index-aligned with the window's listbox

proc host_of {url} {
	if {[regexp -nocase {^https?://([^/]+)} $url -> h]} { return $h }
	return $url
}

# Are two source URLs the same repository? The scheme is only how it is reached (D109):
# a user who moves http://host/rio to https://host/rio keeps their updates, the
# [installed] mark and the "from the repository it was installed from" grouping,
# instead of every installed extension turning foreign overnight.
proc source_same {a b} {
	regsub -nocase {^https?://} $a {} a
	regsub -nocase {^https?://} $b {} b
	return [expr {$a eq $b}]
}

proc extensions_window {} {
	set w .extw
	if {[winfo exists $w]} { raise $w ; focus $w.body.list ; return }
	toplevel $w
	wm title $w "Extensions"
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	# Header: sources editor, refresh, filter.
	frame $w.hdr -background [dict get $c ui.bg]
	button $w.hdr.repos   -text "Repositories…" -font RioUIFont -command extw_sources_dialog
	button $w.hdr.refresh -text "⟳" -font RioUIFont -command extw_refresh  ;# ⟳ rescan (D27)
	# Update All (D107): apt's `upgrade` beside its `update`. Its label carries the
	# count, and it is disabled at zero — the button itself is the answer to "is
	# anything out of date?", so it must never look clickable when nothing is.
	button $w.hdr.upall -text "Update All" -font RioUIFont -command extw_update_all
	label $w.hdr.flbl -text "Filter:" -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	entry $w.hdr.filter -font RioUIFont -width 18
	ctx_bind_input $w.hdr.filter   ;# (D115)
	pack $w.hdr.repos $w.hdr.refresh $w.hdr.upall -side left -padx {0 4}
	pack $w.hdr.filter $w.hdr.flbl -side right
	bind $w.hdr.filter <KeyRelease> extw_fill

	# The aggregated list: one row per (kind, name), plus the honest failures.
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.extw.body.list yview}
	listbox $w.body.list -height 12 -width 72 -activestyle none -exportselection 0 \
		-borderwidth 0 -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] \
		-selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .extw.body.sb .extw.body.list}
	pack $w.body.list -side left -fill both -expand 1
	bind $w.body.list <<ListboxSelect>> extw_select

	# The detail section: every variant of the selected row, with its own
	# Install/Remove — where the user CHOOSES between authors and versions.
	frame $w.det -background [dict get $c ui.bg]

	frame $w.foot -background [dict get $c ui.bg]
	label $w.foot.status -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	button $w.foot.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.foot.close  -side right
	pack $w.foot.status -side left -fill x -expand 1

	grid $w.hdr  -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body -row 1 -column 0 -sticky nsew -padx 8
	grid $w.det  -row 2 -column 0 -sticky we   -padx 8 -pady 4
	grid $w.foot -row 3 -column 0 -sticky we   -padx 8 -pady {2 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	bind $w <Escape> [list destroy $w]

	extw_refresh
	focus $w.body.list
}

proc extw_status {text} {
	if {[winfo exists .extw.foot.status]} { .extw.foot.status configure -text $text }
}

# Toggle the busy guard: while a scan or install runs, every action button in
# the window is disabled — re-entry through a second click is the non-modal
# window's real hazard, and this is its one gate.
proc extw_busy {on} {
	set ::repo_busy $on
	if {![winfo exists .extw]} return
	set st [expr {$on ? "disabled" : "normal"}]
	foreach b {.extw.hdr.repos .extw.hdr.refresh} { $b configure -state $st }
	extw_upall_sync
	foreach f [winfo children .extw.det] {
		# The cross-source checkbutton sits directly in the detail frame; the
		# Install/Update/Remove buttons sit one level deeper, in a variant's row.
		if {[winfo class $f] eq "Checkbutton"} { $f configure -state $st ; continue }
		foreach ch [winfo children $f] {
			if {[winfo class $ch] eq "Button"} { $ch configure -state $st }
		}
	}
}

# The Update All button's label and state: the count is part of the label, so the
# window answers "anything out of date?" without a selection or a click.
proc extw_upall_sync {} {
	if {![winfo exists .extw.hdr.upall]} return
	set n [dict size $::ext_updates]
	.extw.hdr.upall configure \
		-text [expr {$n ? "Update All ($n)" : "Update All"}] \
		-state [expr {$n && !$::repo_busy ? "normal" : "disabled"}]
}

proc extw_refresh {} {
	if {$::repo_busy} return
	extw_busy 1
	# What the core holds: its provider-api ceiling (D66) — so a repo provider that
	# needs a newer rio greys before an install even reaches the core — and the
	# installed version of each provider in its store, which for a provider outranks
	# this GUI's ledger (D107). Best-effort: an old core with no provider.list leaves
	# the default, and every provider then lists as api 1 (what such a core could
	# load anyway).
	ext_core_providers_refresh
	repo_scan_all {apply {{src n total} {
		extw_status "fetching [host_of $src] ($n/$total)…"
		update idletasks
	}}}
	extw_busy 0
	set msg "[llength $::repo_variants] extension(s) from [dict size $::repo_srcinfo] repositories"
	if {[dict size $::ext_updates]} { append msg " — [dict size $::ext_updates] update(s)" }
	extw_status $msg
	extw_fill
}

# Update All from the window: one consent for the batch (ext_update_all), then a
# rescan — an update can change what a source offers next (a payload list, a
# provider's api), and the row marks must come from fresh manifests, not from the
# ones that were on screen when the button was pressed.
proc extw_update_all {} {
	if {$::repo_busy} return
	if {![dict size $::ext_updates]} return
	set n [dict size $::ext_updates]
	extw_busy 1
	extw_status "updating $n extension(s)…"
	set done [ext_update_all]
	extw_busy 0
	extw_status [expr {$done ? "updated $done of $n extension(s)" : "nothing updated"}]
	if {$done} { extw_refresh } else { extw_fill }
}

# Aggregate the scan + ledger into display rows: one per (kind, name), sorted;
# ledger-only entries (source offline or de-configured) synthesized so Remove
# still works; one `!!` row per dead source at the bottom.
proc extw_rows_build {} {
	set bykey {}
	foreach v $::repo_variants {
		dict lappend bykey "[dict get $v kind]/[dict get $v name]" $v
	}
	# Installed, but no source lists it: the ledger (or, for a provider, the core —
	# D107) speaks for it, so Remove always works even when the repository is gone.
	dict for {key cur} $::ext_installed {
		if {[dict exists $bykey $key]} continue
		lassign [split $key /] kind name
		set e [expr {[dict exists $::ext_ledger $key] ? [dict get $::ext_ledger $key] : {}}]
		dict set bykey $key [list [dict create \
			source [dict get $cur source] \
			dir [expr {[dict exists $e dir] ? [dict get $e dir] : ""}] \
			name $name kind $kind version [dict get $cur version] author "" \
			description "installed; its repository is not configured or unreachable" \
			files [expr {[dict exists $e files] ? [dict get $e files] : {}}] offline 1]]
	}
	set rows {}
	foreach key [lsort [dict keys $bykey]] {
		lassign [split $key /] kind name
		set vars [dict get $bykey $key]
		set desc ""
		foreach v $vars {
			if {[dict get $v description] ne ""} { set desc [dict get $v description] ; break }
		}
		lappend rows [dict create kind $kind name $name key $key \
			variants $vars desc $desc]
	}
	foreach d $::repo_dead {
		lappend rows [dict create dead 1 url [lindex $d 0] error [lindex $d 1] \
			code [lindex $d 2] newkey [lindex $d 3]]
	}
	return $rows
}

# Why a source produced no extensions, in the few words a list row has. Everything
# past `unreachable` is a signature refusal (D118) — the detail pane below carries
# the sentence, and for a key waiting to be confirmed or one that changed (D119) the
# way to act on it.
proc dead_phrase {code} {
	switch -- $code {
		untrusted_cert  { return "certificate not trusted" }
		key_unconfirmed { return "signing key not confirmed" }
		key_changed     { return "signing key changed" }
		sig_bad         { return "signature doesn't verify" }
		sig_missing     { return "signature missing" }
		sig_dropped     { return "no longer signed" }
		sig_no_tool     { return "can't check the signature" }
		hash_mismatch   { return "files don't match the signature" }
	}
	return "unreachable"
}

# Fill the listbox from the rows, applying the filter; keep the selection on
# the same (kind, name) across a refill if it survived it.
proc extw_fill {} {
	if {![winfo exists .extw.body.list]} return
	set filter [string tolower [string trim [.extw.hdr.filter get]]]
	set keep ""
	set sel [.extw.body.list curselection]
	if {$sel ne "" && [dict exists [lindex $::extw_rows $sel] key]} {
		set keep [dict get [lindex $::extw_rows $sel] key]
	}
	set ::extw_rows {}
	.extw.body.list delete 0 end
	set c $::theme_colors
	foreach row [extw_rows_build] {
		if {[dict exists $row dead]} {
			if {$filter ne "" && ![string match *$filter* [string tolower [dict get $row url]]]} continue
			lappend ::extw_rows $row
			.extw.body.list insert end "!! [dict get $row url] — [dead_phrase [dict get $row code]]"
			.extw.body.list itemconfigure end -foreground [dict get $c error]
			continue
		}
		if {$filter ne "" && ![string match *$filter* \
			[string tolower "[dict get $row name] [dict get $row kind] [dict get $row desc]"]]} continue
		lappend ::extw_rows $row
		set vars [dict get $row variants]
		if {[llength $vars] > 1} {
			set from "[llength $vars] sources"
		} else {
			set from [host_of [dict get [lindex $vars 0] source]]
			if {[dict exists [lindex $vars 0] offline]} { append from " (offline)" }
		}
		# The installed mark carries the version comparison (D107): what you have, and
		# what a repository now offers instead. A version that doesn't follow the semver
		# rule says so rather than being silently left out of the comparison.
		set marks ""
		set key [dict get $row key]
		set update [dict exists $::ext_updates $key]
		if {[dict exists $::ext_installed $key]} {
			set cur [dict get [dict get $::ext_installed $key] version]
			if {$update} {
				append marks " \[$cur → [dict get [dict get $::ext_updates $key] to]\]"
			} elseif {[ext_ver_parse $cur] eq ""} {
				append marks " \[installed $cur — version not comparable\]"
			} else {
				append marks " \[installed $cur\]"
			}
		}
		if {![ext_row_installable $row]} { append marks " (needs a newer rio)" }
		.extw.body.list insert end \
			[format "%-16s %-8s %s%s" [dict get $row name] [dict get $row kind] $from $marks]
		if {![ext_row_installable $row]} {
			.extw.body.list itemconfigure end -foreground [dict get $c gutter.fg]
		} elseif {$update} {
			.extw.body.list itemconfigure end -foreground [dict get $c accent]
		}
	}
	if {$keep ne ""} {
		for {set i 0} {$i < [llength $::extw_rows]} {incr i} {
			if {[dict exists [lindex $::extw_rows $i] key]
					&& [dict get [lindex $::extw_rows $i] key] eq $keep} {
				.extw.body.list selection set $i
				break
			}
		}
	}
	extw_upall_sync
	extw_select
}

# Rebuild the detail section for the selected row: the extension's header line,
# then one line per variant — `version by author — source-host` with Install,
# or [installed] + Remove on the variant that is in place. An installed version
# no longer listed by its source gets its own honest line.
#
# D107 adds the version comparison to each variant line: the one that would
# UPDATE what is installed says so and its button reads Update; one that is
# behind says so and keeps a plain Install (a downgrade stays possible, it just
# never happens by accident). Below the header, an installed row carries the
# cross-source checkbutton — the per-extension opt-in that lets a repository
# OTHER than the one it came from count as an update at all.
proc extw_select {} {
	set det .extw.det
	if {![winfo exists $det]} return
	foreach ch [winfo children $det] { destroy $ch }
	set c $::theme_colors
	set sel [.extw.body.list curselection]
	if {$sel eq "" || $sel >= [llength $::extw_rows]} return
	set row [lindex $::extw_rows $sel]
	# Bound long text to the list's width so a wordy description word-wraps rather
	# than stretching this auto-sized window. reqwidth is the list's requested pixel
	# width (from -width 72), stable even before the window is mapped; `wrapb` leaves
	# room for a variant row's Install/Remove button.
	set wrap  [expr {[winfo reqwidth .extw.body.list] - 12}]
	set wrapb [expr {$wrap - 90}]
	if {[dict exists $row dead]} {
		label $det.err -anchor w -justify left -font RioUIFont -wraplength $wrap \
			-text "[dict get $row url]\n[dict get $row error]" \
			-background [dict get $c ui.bg] -foreground [dict get $c error]
		pack $det.err -fill x
		# A refused certificate is the one dead source the user can do something about
		# here: look at it, and accept it if it is theirs (D111). Offered for an https
		# source only — an http one refused on a redirect has no certificate of its own
		# to show, and its message already names the certificate that was refused.
		if {[dict get $row code] eq "untrusted_cert" && [regexp -nocase {^https://} [dict get $row url]]} {
			button $det.review -text "Review certificate…" -font RioUIFont \
				-state [expr {$::repo_busy ? "disabled" : "normal"}] \
				-command [list extw_cert_review [dict get $row url] [dict get $row error]]
			pack $det.review -anchor w -pady {4 0}
		}
		# A signing key waiting to be confirmed (D119) or a rotated one (D118) is the
		# other dead source the user can act on, and the act is the same shape: look at
		# what is being asked for, then say yes to that one thing.
		if {[dict get $row code] in {key_unconfirmed key_changed} && [dict get $row newkey] ne ""} {
			button $det.keyreview -text "Review signing key…" -font RioUIFont \
				-state [expr {$::repo_busy ? "disabled" : "normal"}] \
				-command [list extw_key_review [dict get $row url] [dict get $row newkey]]
			pack $det.keyreview -anchor w -pady {4 0}
		}
		return
	}
	set head "[dict get $row name] — [dict get $row kind]"
	if {[dict get $row desc] ne ""} { append head " — [dict get $row desc]" }
	label $det.head -anchor w -justify left -wraplength $wrap -font RioUIFont -text $head \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	pack $det.head -fill x -pady {0 2}
	set key [dict get $row key]
	set entry ""
	if {[dict exists $::ext_installed $key]} { set entry [dict get $::ext_installed $key] }
	set st [expr {$::repo_busy ? "disabled" : "normal"}]
	# The cross-source opt-in, on installed rows only: it is a statement about THIS
	# extension's identity across repositories, so it belongs on the extension, not in
	# Preferences. Off by default (D107).
	if {$entry ne "" && [dict exists $::ext_ledger $key]} {
		set ::extw_anysource [ext_anysource $key]
		checkbutton $det.anysrc -variable ::extw_anysource -state $st \
			-text "Also accept updates from other repositories" \
			-command [list extw_anysource_toggle $key] \
			-font RioUIFont -anchor w -wraplength $wrap \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
			-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg] \
			-selectcolor [dict get $c ui.bg]
		pack $det.anysrc -fill x -pady {0 2}
	}
	set i 0
	set matched 0
	foreach v [dict get $row variants] {
		set f [frame $det.v$i -background [dict get $c ui.bg]]
		set line "  [dict get $v version]"
		if {[dict get $v author] ne ""} { append line " by [dict get $v author]" }
		append line " — [host_of [dict get $v source]]"
		# Where the choice between two sources is actually made, so the thing that
		# distinguishes them is stated here (D118). An offline row has no source to
		# say anything about.
		if {![dict exists $v offline]} {
			append line " — [sig_mark [expr {[dict exists $v sig] ? [dict get $v sig] : "unsigned"}]]"
		}
		set this_installed [expr {$entry ne "" \
			&& [source_same [dict get $v source] [dict get $entry source]] \
			&& [dict get $v version] eq [dict get $entry version]}]
		# How this variant relates to what is installed. Only ever stated when both
		# versions follow the semver rule — otherwise rio makes no claim (D107).
		set is_update [expr {[ext_variant_update $v] ne ""}]
		if {!$this_installed && !$is_update && $entry ne "" && ![dict exists $v offline]
				&& [source_same [dict get $v source] [dict get $entry source]]
				&& [ext_ver_cmp [dict get $v version] [dict get $entry version]] eq "-1"} {
			append line "  (older than the installed [dict get $entry version])"
		}
		label $f.l -anchor w -justify left -wraplength $wrapb -font RioUIFont -text $line \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		if {$this_installed} {
			set matched 1
			label $f.mark -font RioUIFont -text "\[installed\]" \
				-background [dict get $c ui.bg] -foreground [dict get $c accent]
			button $f.rm -text Remove -font RioUIFont -state $st \
				-command [list extw_remove [dict get $row kind] [dict get $row name]]
			pack $f.rm $f.mark -side right -padx 2
		} elseif {[dict exists $v offline]} {
			button $f.rm -text Remove -font RioUIFont -state $st \
				-command [list extw_remove [dict get $row kind] [dict get $row name]]
			pack $f.rm -side right -padx 2
		} elseif {[ext_variant_installable $v]} {
			# Update, not Install, when this is the newer version of what you already
			# have — same act, but the button says which act it is.
			button $f.in -text [expr {$is_update ? "Update" : "Install"}] \
				-font RioUIFont -state $st -command [list extw_install $sel $i]
			pack $f.in -side right -padx 2
		}
		pack $f.l -side left -fill x -expand 1
		pack $f -fill x
		incr i
	}
	if {$entry ne "" && !$matched && ![dict exists [lindex [dict get $row variants] 0] offline]} {
		set f [frame $det.inst -background [dict get $c ui.bg]]
		label $f.l -anchor w -justify left -wraplength $wrapb -font RioUIFont \
			-text "  installed: [dict get $entry version] — [host_of [dict get $entry source]] (no longer listed there)" \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		button $f.rm -text Remove -font RioUIFont -state $st \
			-command [list extw_remove [dict get $row kind] [dict get $row name]]
		pack $f.rm -side right -padx 2
		pack $f.l -side left -fill x -expand 1
		pack $f -fill x
	}
}

proc extw_install {rowidx vidx} {
	if {$::repo_busy} return
	set row [lindex $::extw_rows $rowidx]
	set v [lindex [dict get $row variants] $vidx]
	extw_busy 1
	extw_status "installing [dict get $row name]…"
	set done [ext_install $v]
	extw_busy 0
	extw_status [expr {$done ? "installed [dict get $row name] [dict get $v version]" : "not installed"}]
	extw_fill
}

# Flip one extension's cross-source flag and repaint: the count in Update All and
# the row's mark both change with it, so the effect of the checkbutton is visible
# in the same window without a rescan (the variants are already in hand).
set ::extw_anysource 0   ;# the detail checkbutton's variable, per selected row
proc extw_anysource_toggle {key} {
	ext_anysource_set $key $::extw_anysource
	extw_fill
}

proc extw_remove {kind name} {
	if {$::repo_busy} return
	extw_busy 1
	extw_status "removing $name…"
	ext_remove $kind $name
	extw_busy 0
	extw_status "removed $name"
	extw_fill
}

# ---------------------------------------------------------------------------
# The start-up check (AGENTS.md D107) — rio's `apt update` at boot, OFF by
# default: a fresh rio makes no network request it was not asked to make, and
# the request is the CORE's anyway (repo.fetch), which on a remote core means
# someone else's machine.
#
# Deferred on a timer, and deferred again while an op is in flight or the
# Extensions window is scanning — the rule fs_changed_settle follows: never
# start a core call from a timer inside another op's round trip. Every failure
# is silent (a dead source is already one honest row in the window); the only
# thing this is allowed to interrupt the user with is a genuine finding.
# ---------------------------------------------------------------------------
set ::ext_check_updates 0    ;# the preference (prefs.json `check_updates`)
set ::ext_check_delay 1500   ;# ms after boot; long enough for the window to settle
set ::ext_check_after ""     ;# pending check timer; "" while none is armed

proc ext_check_arm {} {
	if {!$::ext_check_updates} return
	if {$::ext_check_after ne ""} return
	set ::ext_check_after [after $::ext_check_delay ext_startup_check]
}

proc ext_startup_check {} {
	set ::ext_check_after ""
	if {!$::ext_check_updates} return
	if {[array size ::pending] || $::repo_busy} {
		set ::ext_check_after [after $::ext_check_delay ext_startup_check]
		return
	}
	if {![llength [sources_load]]} return
	set ::repo_busy 1
	catch {
		ext_core_providers_refresh
		repo_scan_all
	}
	set ::repo_busy 0
	if {[dict size $::ext_updates]} { ext_update_dialog }
}

# What the check found. A plain toplevel rather than a tk_messageBox because it
# carries a checkbutton — and "don't ask again" is the honest escape from a
# start-up notification: it turns the preference off, which means checking
# becomes the user's own business in the Extensions window, and says so.
#
# NO grab and no tkwait: this reports, it does not ask. Boot must not block on
# it, and a modal a headless run can reach is exactly the hazard the dialog
# guard at the foot of this file exists to prevent.
proc ext_update_dialog {} {
	set w .extupd
	destroy $w
	toplevel $w
	wm title $w "rio — extension updates"
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set n [dict size $::ext_updates]
	label $w.head -anchor w -justify left -font RioUIFont \
		-text "[expr {$n == 1 ? "One extension has" : "$n extensions have"}] a newer version available:" \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	set lines {}
	foreach key [lsort [dict keys $::ext_updates]] {
		set u [dict get $::ext_updates $key]
		lassign [split $key /] kind name
		lappend lines [format "    %-16s %s → %s    %s" $name \
			[dict get $u from] [dict get $u to] [host_of [dict get [dict get $u variant] source]]]
	}
	label $w.list -anchor w -justify left -font RioUIFont -text [join $lines "\n"] \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	checkbutton $w.stop -variable ::ext_check_updates -onvalue 0 -offvalue 1 \
		-text "Don't check for updates at start-up" -command ext_check_pref_save \
		-font RioUIFont -anchor w \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg] \
		-selectcolor [dict get $c ui.bg]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.ext   -text "Extensions…" -font RioUIFont \
		-command [list apply {{w} { destroy $w ; extensions_window }} $w]
	button $w.btns.close -text "Close" -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	pack $w.btns.ext   -side right -padx {0 4}
	grid $w.head -row 0 -column 0 -sticky we -padx 12 -pady {12 4}
	grid $w.list -row 1 -column 0 -sticky we -padx 12
	grid $w.stop -row 2 -column 0 -sticky w  -padx 12 -pady {10 4}
	grid $w.btns -row 3 -column 0 -sticky we -padx 12 -pady {4 12}
	grid columnconfigure $w 0 -weight 1
	bind $w <Escape> [list destroy $w]
	focus $w.btns.close
}

# The preference is one flag, written through the same prefs.json as every other
# view setting — so both of its doors (this dialog's checkbutton and the
# Preferences pane) record the same thing.
proc ext_check_pref_save {} { prefs_save }

# The compact sources editor behind `Repositories…`: the URLs of sources.list
# in a listbox, Remove for the selected one, an entry + Add below. Writes
# sources.list on every change (it IS the hand-editable file — this dialog is
# just a convenience over it). Modal is fine here: it's a small focused edit,
# not a browsing surface. Closing refreshes the Extensions window's scan.
proc extw_sources_dialog {} {
	set w .extsrc
	destroy $w
	toplevel $w
	wm title $w "Repositories"
	# Reachable from the Extensions window and from Preferences ▸ Extensions (D107),
	# so the master is whichever is actually there.
	wm transient $w [expr {[winfo exists .extw] ? ".extw" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	# Hint text is muted (gutter.fg), so static help never reads as an interactive
	# element; the list below carries a solid border for the same reason — the
	# selectable repository URLs must look distinct from this sentence (AGENTS D68).
	label $w.hint -anchor w -justify left -font RioUIFont \
		-text "Each repository is a plain directory served over http:// or https:// (see CONTRIBUTING.md to host one)." \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.extsrc.body.list yview}
	listbox $w.body.list -height 8 -width 60 -activestyle none -exportselection 0 \
		-borderwidth 1 -relief solid -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] \
		-selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .extsrc.body.sb .extsrc.body.list}
	pack $w.body.list -side left -fill both -expand 1
	frame $w.add -background [dict get $c ui.bg]
	entry $w.add.url -font RioUIFont -width 44
	ctx_bind_input $w.add.url   ;# (D115)
	button $w.add.add -text Add -font RioUIFont -command extw_source_add
	pack $w.add.url -side left -fill x -expand 1
	pack $w.add.add -side left -padx {4 0}
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.rm    -text "Remove selected" -font RioUIFont -command extw_source_remove
	button $w.btns.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	pack $w.btns.rm    -side left
	grid $w.hint -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body -row 1 -column 0 -sticky nsew -padx 8
	grid $w.add  -row 2 -column 0 -sticky we   -padx 8 -pady 4
	grid $w.btns -row 3 -column 0 -sticky we   -padx 8 -pady {2 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	foreach u [sources_load] { $w.body.list insert end $u }
	bind $w.add.url <Return> extw_source_add
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.add.url
	tkwait window $w
	# Only rescan when there is a window to repaint: opened from Preferences, this
	# dialog is a plain edit of sources.list and must not reach for the network.
	if {[winfo exists .extw]} { extw_refresh }
}

proc extw_source_add {} {
	set url [string trim [.extsrc.add.url get]]
	if {$url eq ""} return
	# http and https are both first-class (D109): the scheme is the user's choice, and
	# nothing here nudges one over the other.
	if {![regexp -nocase {^https?://} $url]} {
		report_error "A repository URL starts with http:// or https:// — got: $url"
		return
	}
	set urls [sources_load]
	if {$url ni $urls} {
		lappend urls $url
		sources_save $urls
		.extsrc.body.list insert end $url
	}
	.extsrc.add.url delete 0 end
}

proc extw_source_remove {} {
	set sel [.extsrc.body.list curselection]
	if {$sel eq ""} return
	set url [.extsrc.body.list get $sel]
	sources_save [lsearch -all -inline -not -exact [sources_load] $url]
	.extsrc.body.list delete $sel
}

# --- a certificate that doesn't verify (AGENTS.md D111) ------------------------------------
#
# The browser's "Your connection is not private … Advanced" path. A repository whose
# certificate the core refused lists as "certificate not trusted"; its detail pane offers
# Review certificate…, which asks the CORE for the certificate (tls.inspect — the core's
# network is the one that matters, D30) and shows what is wrong with it in plain words, its
# details, and two buttons: Go Back, the default, and Accept the Risk and Continue.
#
# Accept sends the fingerprint THIS DIALOG SHOWED, never a fresh one: a server that swapped
# certificates between the look and the click would otherwise get the second one accepted.
# Modal, because it asks a question; opened only by the user's click, never by a scan or
# the start-up check — one dialog per refused source is the cumbersome part avoided.

# The inspect seam: tls.inspect through the core, never throwing. Tests stub THIS.
proc tls_inspect {url} {
	set resp [rio_call tls.inspect [dict create url $url]]
	if {[dict get $resp ok]} { return [dict create ok 1 cert [dict get $resp result]] }
	return [dict create ok 0 error [dict get $resp error message]]
}

# The problems tls.inspect reports, as sentences a user can weigh.
proc cert_problem_lines {cert} {
	set host [dict get $cert host]
	set lines {}
	foreach p [dict get $cert problems] {
		switch -- $p {
			changed {
				set lines [linsert $lines 0 "This is NOT the certificate you accepted for $host:[dict get $cert port]. If you didn't replace it on the server, someone may be impersonating it."]
			}
			untrusted {
				lappend lines "It is issued by an authority this system doesn't trust — it is self-signed, or from a private certificate authority."
			}
			expired {
				lappend lines "It expired on [dict get $cert not_after]."
			}
			not_yet_valid {
				lappend lines "It isn't valid until [dict get $cert not_before]."
			}
			name_mismatch {
				set names [join [dict get $cert names] ", "]
				if {$names eq ""} { set names [dict get $cert subject] }
				lappend lines "It was issued for $names, not for $host."
			}
			default {
				lappend lines "It was refused: [join [dict get $cert reasons] {; }]."
			}
		}
	}
	return $lines
}

proc extw_cert_review {url {fetch_error ""}} {
	if {$::repo_busy} return
	extw_busy 1
	extw_status "getting the certificate of [host_of $url]…"
	update idletasks
	set r [tls_inspect $url]
	extw_busy 0
	extw_status ""

	set w .extcert
	destroy $w
	toplevel $w
	wm title $w "Certificate not trusted"
	wm transient $w [expr {[winfo exists .extw] ? ".extw" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set wrap 460
	set ::extw_cert_choice ""
	set cert [expr {[dict get $r ok] ? [dict get $r cert] : {}}]
	set askable [expr {$cert ne "" && [llength [dict get $cert problems]] && ![dict get $cert accepted]}]

	frame $w.btns -background [dict get $c ui.bg]
	if {$askable} {
		set origin "[dict get $cert host]:[dict get $cert port]"
		label $w.head -anchor w -justify left -wraplength $wrap -font RioUIFont \
			-text "rio can't confirm that $origin is the server it claims to be. Someone could be impersonating it — or it is a server whose certificate isn't signed by an authority this system knows, such as your own." \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		pack $w.head -fill x -padx 8 -pady {8 4}
		set i 0
		foreach line [cert_problem_lines $cert] {
			label $w.p$i -anchor w -justify left -wraplength $wrap -font RioUIFont \
				-text "•  $line" -background [dict get $c ui.bg] -foreground [dict get $c error]
			pack $w.p$i -fill x -padx 8 -pady 1
			incr i
		}
		# The details are data to read and compare, so they sit in a bordered box, apart
		# from the sentences around them (D68); selectable, so a fingerprint can be copied.
		text $w.det -height 6 -width 64 -wrap word -font RioUIFont -relief solid \
			-borderwidth 1 -highlightthickness 0 \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		ctx_bind_view $w.det   ;# Copy / Select All: the fingerprint is the point (D115)
		set names [join [dict get $cert names] ", "]
		foreach {k v} [list "Issued to" [dict get $cert subject] "Names" $names \
				"Issued by" [dict get $cert issuer] \
				"Valid" "[dict get $cert not_before] – [dict get $cert not_after]" \
				"SHA-256" [dict get $cert sha256]] {
			if {$v eq ""} continue
			$w.det insert end [format "%-10s %s\n" $k: $v]
		}
		$w.det delete "end-1c" end
		$w.det configure -state disabled
		pack $w.det -fill x -padx 8 -pady {6 4}
		label $w.hint -anchor w -justify left -wraplength $wrap -font RioUIFont \
			-text "Accept only if you know this is the server's own certificate — for example, compare the SHA-256 fingerprint with the one on the server. rio then trusts exactly this certificate for $origin, and asks again if it ever changes. To trust every server of a private certificate authority instead, add it to the certificate store on the core's host." \
			-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
		pack $w.hint -fill x -padx 8 -pady {2 6}
		button $w.btns.back -text "Go Back" -font RioUIFont -default active \
			-command [list destroy $w]
		button $w.btns.accept -text "Accept the Risk and Continue" -font RioUIFont \
			-command [list apply {{w} { set ::extw_cert_choice accept ; destroy $w }} $w]
		pack $w.btns.back -side right
		pack $w.btns.accept -side left
		set focus $w.btns.back
	} else {
		if {$cert eq ""} {
			set msg "rio couldn't get the certificate: [dict get $r error]"
		} elseif {[dict get $cert accepted]} {
			set msg "This certificate is already accepted for [dict get $cert host]:[dict get $cert port]. Refresh the list to fetch from it."
		} else {
			set msg "The certificate of [dict get $cert host]:[dict get $cert port] verifies, so the refused one belongs to another server — perhaps one this repository redirects to — and rio can't show it here."
		}
		if {$fetch_error ne ""} { append msg "\n\n$fetch_error" }
		label $w.head -anchor w -justify left -wraplength $wrap -font RioUIFont -text $msg \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		pack $w.head -fill x -padx 8 -pady {8 6}
		button $w.btns.back -text Close -font RioUIFont -default active -command [list destroy $w]
		pack $w.btns.back -side right
		set focus $w.btns.back
	}
	pack $w.btns -fill x -padx 8 -pady {2 8}
	bind $w <Escape> [list destroy $w]
	bind $w <Return> [list destroy $w]
	catch {grab $w}
	focus $focus
	tkwait window $w

	if {$::extw_cert_choice ne "accept"} return
	set resp [rio_call tls.accept [dict create host [dict get $cert host] \
		port [dict get $cert port] sha256 [dict get $cert sha256] subject [dict get $cert subject]]]
	if {![dict get $resp ok]} {
		report_error "Couldn't accept the certificate: [dict get $resp error message]"
		return
	}
	if {[winfo exists .extw]} { extw_refresh }
}

# --- confirming a signing key (AGENTS.md D118, D119) ---------------------------------
#
# The same act as accepting a certificate, for the other half of the trust model, in
# the two situations that call for it: a repository rio has never had a key for, and
# one whose key is now different. Both are what a legitimate publisher looks like (the
# publisher's own SIGNING.md tells them to expect this dialog on their users' machines)
# and equally what an impersonation looks like, and rio cannot tell them apart — so it
# shows the fingerprints and asks. It never trusts a key because it arrived first.
#
# Trusts the key THIS DIALOG SHOWED, never a freshly fetched one, for the reason
# extw_cert_review gives: a server that swapped keys between the look and the click
# would otherwise get the second one trusted.

# The fingerprint seam: sig.fingerprint through the core, "" when it can't be had.
proc sig_fingerprint {key} {
	set resp [rio_call sig.fingerprint [dict create key $key]]
	if {![dict get $resp ok]} { return "" }
	return [dict get $resp result fingerprint]
}

proc extw_key_review {url newkey} {
	if {$::repo_busy} return
	set old [repo_key_of $url]
	# First sight (D119): there is no trusted key to compare against, so this is the
	# same dialog with one fingerprint instead of two. Not a second window — the act is
	# identical, and the one thing that matters is said in both: confirm it somewhere
	# other than the connection that just offered it.
	set first [expr {$old eq ""}]
	set oldfp [expr {$first ? "" : [sig_fingerprint $old]}]
	set newfp [sig_fingerprint $newkey]
	set when ""
	set sk [source_key $url]
	if {[dict exists $::repo_keys $sk]} { set when [dict get $::repo_keys $sk trusted] }

	set w .extkey
	destroy $w
	toplevel $w
	wm title $w [expr {$first ? "Confirm signing key" : "Signing key changed"}]
	wm transient $w [expr {[winfo exists .extw] ? ".extw" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set wrap 460
	set ::extw_key_choice ""

	if {$first} {
		set headtext "[host_of $url] signs its extensions, and this is the first time rio has seen a key for it. The signature checks out against this key — but that only proves the key signed these files, not that it is the publisher's. Nothing is installed or listed from this repository until you say it is."
	} else {
		set headtext "[host_of $url] is signing its extensions with a different key than the one rio trusted[expr {$when ne "" ? " on $when" : ""}]. If the publisher rotated their key, this is expected — they have no way to tell you inside rio. If they didn't, someone else is answering for this repository."
	}
	label $w.head -anchor w -justify left -wraplength $wrap -font RioUIFont \
		-text $headtext \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	pack $w.head -fill x -padx 8 -pady {8 4}
	# The two fingerprints are data to compare, so they sit in a bordered box, apart
	# from the sentences around them (D68); selectable, because comparing one by eye
	# against a publisher's web page is exactly the intended use.
	text $w.det -height 5 -width 64 -wrap word -font RioUIFont -relief solid \
		-borderwidth 1 -highlightthickness 0 \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	ctx_bind_view $w.det   ;# Copy / Select All: the fingerprint is the point (D115)
	foreach {k v} [list "Repository" $url \
			"Trusted" [expr {$oldfp ne "" ? $oldfp : $old}] \
			"Offered" [expr {$newfp ne "" ? $newfp : $newkey}]] {
		if {$v eq ""} continue
		$w.det insert end [format "%-11s %s\n" $k: $v]
	}
	$w.det delete "end-1c" end
	$w.det configure -state disabled
	pack $w.det -fill x -padx 8 -pady {6 4}
	if {$first} {
		set hinttext "Confirm this fingerprint away from this connection — the publisher's own page, a release note, a message from them. Anyone who can answer for this repository can offer a key that verifies; only the publisher can tell you which one is theirs. rio then trusts exactly this key here, and asks again if it ever changes. Every key it trusts is listed under Preferences ▸ Extensions ▸ Repository signing keys…, where forgetting one puts that repository back to this question."
	} else {
		set hinttext "Trust the new key only if you can confirm it away from this connection — the publisher's own page, a release note, a message from them. rio then trusts exactly this key for this repository, and asks again if it ever changes. Every key it trusts is listed under Preferences ▸ Extensions ▸ Repository signing keys…, where forgetting one puts that repository back to being asked about."
	}
	label $w.hint -anchor w -justify left -wraplength $wrap -font RioUIFont \
		-text $hinttext \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	pack $w.hint -fill x -padx 8 -pady {2 6}
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.back -text "Go Back" -font RioUIFont -default active \
		-command [list destroy $w]
	button $w.btns.trust -text [expr {$first ? "Trust This Key" : "Trust the New Key"}] \
		-font RioUIFont \
		-command [list apply {{w} { set ::extw_key_choice trust ; destroy $w }} $w]
	pack $w.btns.back -side right
	pack $w.btns.trust -side left
	pack $w.btns -fill x -padx 8 -pady {2 8}
	bind $w <Escape> [list destroy $w]
	bind $w <Return> [list destroy $w]
	catch {grab $w}
	focus $w.btns.back
	tkwait window $w

	if {$::extw_key_choice ne "trust"} return
	repo_key_trust $url $newkey
	if {[winfo exists .extw]} { extw_refresh }
}

# Preferences ▸ Network ▸ Accepted certificates…: every exception the core holds, and a
# way to take one back — a browser always offers that, and so does rio (D111). The list is
# the core's certificates.conf, read through tls.accepted each time it is filled.
proc certs_dialog {} {
	set w .certs
	destroy $w
	toplevel $w
	wm title $w "Accepted certificates"
	wm transient $w [expr {[winfo exists .prefs] ? ".prefs" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.hint -anchor w -justify left -wraplength 480 -font RioUIFont \
		-text "Certificates you accepted although they did not verify. Each is trusted only on its own host and port, and only while the server presents that exact certificate. They are kept in certificates.conf on the core's host." \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.certs.body.list yview}
	listbox $w.body.list -height 6 -width 72 -activestyle none -exportselection 0 \
		-borderwidth 1 -relief solid -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] -selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .certs.body.sb .certs.body.list}
	pack $w.body.list -side left -fill both -expand 1
	label $w.status -anchor w -justify left -wraplength 480 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c error]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.rm    -text "Remove selected" -font RioUIFont -command certs_remove
	button $w.btns.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	pack $w.btns.rm    -side left
	grid $w.hint   -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body   -row 1 -column 0 -sticky nsew -padx 8
	grid $w.status -row 2 -column 0 -sticky we   -padx 8
	grid $w.btns   -row 3 -column 0 -sticky we   -padx 8 -pady {4 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	certs_fill
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.body.list
	tkwait window $w
}

set ::certs_rows {}   ;# the exceptions behind .certs.body.list, in its order

proc certs_fill {} {
	if {![winfo exists .certs]} return
	.certs.body.list delete 0 end
	set ::certs_rows {}
	set resp [rio_call tls.accepted {}]
	# The call pumps the event loop, and the dialog may have been closed meanwhile.
	if {![winfo exists .certs]} return
	if {![dict get $resp ok]} {
		.certs.status configure -text "The core couldn't list accepted certificates: [dict get $resp error message]"
		return
	}
	.certs.status configure -text ""
	foreach e [dict get $resp result exceptions] {
		lappend ::certs_rows $e
		set line "[dict get $e host]:[dict get $e port]"
		if {[dict get $e subject] ne ""} { append line "  —  [dict get $e subject]" }
		append line "  —  SHA-256 [string range [dict get $e sha256] 0 22]…"
		if {[dict get $e accepted] ne ""} { append line "  (accepted [dict get $e accepted])" }
		.certs.body.list insert end $line
	}
}

proc certs_remove {} {
	set sel [.certs.body.list curselection]
	if {$sel eq ""} return
	set e [lindex $::certs_rows $sel]
	set resp [rio_call tls.forget [dict create host [dict get $e host] port [dict get $e port]]]
	if {![winfo exists .certs]} return
	if {![dict get $resp ok]} {
		.certs.status configure -text "Couldn't remove it: [dict get $resp error message]"
		return
	}
	certs_fill
}

# Preferences ▸ Extensions ▸ Repository signing keys…: every key the user has
# confirmed, and a way to take one back (D118; deferred with jka when D118 landed,
# built once the mechanism had settled). certs_dialog's counterpart for repositories,
# and deliberately the same window: a list, one line per trust decision, Forget.
#
# One thing differs from the certificates, and it is said in the window rather than
# assumed: the keys are the GUI's own — repository-keys.conf beside sources.list,
# because the sources list IS the trust list (D39) and a key is a property of an entry
# in it, not of a host the core dialled.
#
# Forget means what it says (D119). Since no scan trusts a key by itself, taking one
# back really does put that repository behind the question again — it is refused until
# the user confirms a key for it, which is the same thing deleting the section by hand
# has always done. The built-in row is the exception and writes rather than deletes;
# repo_keys_forget says why there.
proc repo_keys_dialog {} {
	set w .repokeys
	destroy $w
	toplevel $w
	wm title $w "Repository signing keys"
	wm transient $w [expr {[winfo exists .prefs] ? ".prefs" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.hint -anchor w -justify left -wraplength 520 -font RioUIFont \
		-text "The signing key you have confirmed for each extension repository. A repository that later signs with a different key is refused until you review that one too. Forgetting a key does not just clear a note: rio asks about that repository again the next time it is scanned, and installs nothing from it until you answer. The scheme is left off on purpose — moving a repository from http:// to https:// is a change of route, not of publisher. They are kept in repository-keys.conf beside your sources list." \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.repokeys.body.list yview}
	listbox $w.body.list -height 6 -width 72 -activestyle none -exportselection 0 \
		-borderwidth 1 -relief solid -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] -selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .repokeys.body.sb .repokeys.body.list}
	pack $w.body.list -side left -fill both -expand 1
	bind $w.body.list <<ListboxSelect>> repo_keys_sel
	# Muted, not the error colour: what lands here explains a row or reports what
	# Forget just did — the row vanishing is otherwise the only feedback there is.
	label $w.status -anchor w -justify left -wraplength 520 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.rm    -text "Forget selected" -font RioUIFont -command repo_keys_forget
	button $w.btns.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	pack $w.btns.rm    -side left
	grid $w.hint   -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body   -row 1 -column 0 -sticky nsew -padx 8
	grid $w.status -row 2 -column 0 -sticky we   -padx 8 -pady {4 0}
	grid $w.btns   -row 3 -column 0 -sticky we   -padx 8 -pady {4 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	repo_keys_fill
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.body.list
	tkwait window $w
}

set ::repo_keys_rows {}   ;# the keys behind .repokeys.body.list, in its order

proc repo_keys_fill {} {
	if {![winfo exists .repokeys]} return
	.repokeys.body.list delete 0 end
	set ::repo_keys_rows {}
	set rows {}
	dict for {src e} $::repo_keys {
		# A keyless section trusts nothing, so it has no key to list. The one that
		# matters — the withdrawn seed — gets its own row just below.
		if {[dict get $e key] eq ""} continue
		lappend rows [dict create src $src key [dict get $e key] \
			when [dict get $e trusted] builtin 0 withdrawn 0]
	}
	# rio's own key is trusted without ever being written down — it is the seed
	# repo_key_of falls back to, so a scan of that repository finds a key already
	# trusted and never asks. Left out, this window would be empty on a fresh install
	# while rio does trust a key, which is the one thing it exists to show. Only while
	# that repository is still in the sources list, though: a key for a source the user
	# removed speaks for nothing.
	#
	# Withdrawn, it is still shown (D119) — rio would otherwise report nothing at all
	# about the one key it made a decision about on the user's behalf, and the row is
	# where that decision is visible and reversible.
	set seed [source_key $::default_repo]
	set gone [expr {[dict exists $::repo_keys $seed]
		&& [dict get $::repo_keys $seed key] eq ""}]
	if {![dict exists $::repo_keys $seed] || $gone} {
		foreach u [sources_load] {
			if {![source_same $u $::default_repo]} continue
			lappend rows [dict create src $seed key $::default_repo_key \
				when "" builtin 1 withdrawn $gone]
			break
		}
	}
	foreach row $rows {
		# The fingerprint is the core's to compute, and the call pumps the event
		# loop — the window may be gone by the time it answers.
		set fp [sig_fingerprint [dict get $row key]]
		if {![winfo exists .repokeys]} return
		if {$fp eq ""} {
			# No ssh-keygen on the core's host, so no fingerprint to show. The key
			# itself still identifies the row; truncated, because its whole point
			# here is to be compared, and 68 base64 characters are not.
			set k [dict get $row key]
			set fp "[lindex $k 0] [string range [lindex $k 1] 0 15]…"
		}
		set line "[dict get $row src]  —  $fp"
		if {[dict get $row builtin]} {
			append line [expr {[dict get $row withdrawn]
				? "  (built in, withdrawn)" : "  (built in)"}]
		} elseif {[dict get $row when] ne ""} {
			append line "  (trusted [dict get $row when])"
		}
		lappend ::repo_keys_rows $row
		.repokeys.body.list insert end $line
	}
	if {$::repo_keys_rows eq ""} {
		.repokeys.status configure -text "You haven't confirmed a signing key for any repository yet. An unsigned repository has no key to list, and a signed one is refused until its key is confirmed."
	}
}

# What a selected row means, where that isn't the obvious thing. Said on selection
# rather than only when the button is pressed: the built-in row is the one row whose
# Forget does something a user would not predict, and reading about it first is worth
# more than discovering it afterwards.
proc repo_keys_sel {} {
	if {![winfo exists .repokeys]} return
	set sel [.repokeys.body.list curselection]
	set t ""
	if {$sel ne ""} {
		set row [lindex $::repo_keys_rows $sel]
		if {[dict get $row builtin] && [dict get $row withdrawn]} {
			set t "You have withdrawn the key rio ships with for its own repository. rio now asks about that repository's key like any other's — confirming one records it here."
		} elseif {[dict get $row builtin]} {
			set t "rio ships with this key for its own repository, so it is the one key you were never asked about. Forget withdraws it: rio then asks about this repository too, the next time it is scanned."
		}
	}
	.repokeys.status configure -text $t
}

proc repo_keys_forget {} {
	set sel [.repokeys.body.list curselection]
	if {$sel eq ""} return
	set row [lindex $::repo_keys_rows $sel]
	if {[dict get $row builtin]} {
		if {[dict get $row withdrawn]} { repo_keys_sel ; return }
		# Nothing to delete — the seed is a fallback, not an entry — so withdrawing it
		# is the one case that WRITES: a section with no key, which repo_key_of answers
		# with "" instead of falling back (D119).
		dict set ::repo_keys [dict get $row src] [dict create key "" trusted "" \
			forgotten [clock format [clock seconds] -format %Y-%m-%d]]
		repo_keys_save
		repo_keys_fill
		if {![winfo exists .repokeys]} return
		.repokeys.status configure -text "rio has withdrawn its built-in key for [dict get $row src]. The next scan of that repository asks you to confirm whatever key it publishes, and installs nothing from it until you do."
		return
	}
	dict unset ::repo_keys [dict get $row src]
	repo_keys_save
	repo_keys_fill
	if {![winfo exists .repokeys]} return
	.repokeys.status configure -text "rio has forgotten the key for [dict get $row src]. The next scan of that repository asks you to confirm whatever key it publishes then, and installs nothing from it until you do."
}

# ---------------------------------------------------------------------------
# Build the UI. The literal colours/fonts here are just a bootstrap; apply_theme
# (below, fed by the core's theme.get) reconfigures every widget from the role
# table — the default theme reproduces this plain white-bg "90s productivity"
# look (D24), and the View menu switches it live.
# ---------------------------------------------------------------------------
# (Tabs are no longer a single top bar; each editor group draws its own strip, D33.)

# The dock sites (AGENTS.md D35 step c1b). Three tabbed tool-window containers —
# left / right / bottom — each a host-owned tab strip (.tabs) above a body area
# (.body) into which the active panel's body widget is packed via -in. This is the
# Visual-Studio docked-tool-window model: every visible site shows its own tab
# strip (render_tabs, from ::layout), and apply_layout drives all of it. It
# replaces the old hand-packed .dock + Files/Git selector: the files/git dock is
# just the two panels that happen to share a side site, and the selector became
# that site's tab strip. Side sites keep a STABLE width (propagate off) like the
# old dock — otherwise the git pane's diff (editor font) is physically wider than
# the file list at the same column count and the window jumps on switch; the
# bottom site takes its content's natural height (the old .results strip).
foreach {_s _w} {left 220 right 340} {
	frame .site$_s -background "#dddddd" -width $_w
	pack propagate .site$_s 0
	frame .site$_s.tabs -background "#dddddd"
	frame .site$_s.body -background "#dddddd"
	pack .site$_s.tabs -side top -fill x
	pack .site$_s.body -side top -fill both -expand 1
}
# The bottom site keeps a STABLE height (propagate off) like the side sites keep a
# stable width — so switching between its tabs (e.g. a tall git diff and the short
# Search strip) never resizes the dock; only the user's bsash drag does.
frame .sitebottom -background "#dddddd" -height 160
pack propagate .sitebottom 0
frame .sitebottom.tabs -background "#dddddd"
frame .sitebottom.body -background "#dddddd"
pack .sitebottom.tabs -side top -fill x
pack .sitebottom.body -side top -fill both -expand 1

# ---------------------------------------------------------------------------
# Hover tooltips (D63). rio's little header controls are bare glyphs (⟳ refresh, ◉/◌
# hidden toggle, …) with no text label to say what they do; a tooltip names them on hover.
# One shared borderless toplevel (.tt), shown after a short delay below the widget and
# hidden on leave. The classic Windows info-tip look — pale yellow, thin dark border, black
# text — theme-independent momentary chrome (it never has to match the pane behind it).
# `tooltip $w $text` attaches the behaviour; re-calling it just updates the text (so a
# stateful control like the hidden toggle can re-label itself). The text is stashed per
# widget in ::tt_text so an update needs no re-bind churn.
# ---------------------------------------------------------------------------
set ::tt_after ""
proc tooltip {w text} {
	set ::tt_text($w) $text
	bind $w <Enter>      [list tooltip_schedule $w]
	bind $w <Leave>      tooltip_hide
	bind $w <ButtonPress> tooltip_hide   ;# ignored where a more-specific <Button-1> exists; <Leave> covers those
}
proc tooltip_schedule {w} {
	tooltip_cancel
	set ::tt_after [after 600 [list tooltip_show $w]]
}
proc tooltip_cancel {} {
	if {$::tt_after ne ""} { after cancel $::tt_after ; set ::tt_after "" }
}
proc tooltip_hide {} {
	tooltip_cancel
	catch {wm withdraw .tt}
}
proc tooltip_show {w} {
	set ::tt_after ""
	if {![winfo exists $w] || ![info exists ::tt_text($w)]} return
	if {![winfo exists .tt]} {
		toplevel .tt -background black          ;# the 1px border is this bg showing past the label
		wm overrideredirect .tt 1
		wm withdraw .tt
		label .tt.l -background "#ffffe1" -foreground black -font RioUIFont \
			-padx 4 -pady 1 -justify left
		pack .tt.l -padx 1 -pady 1
	}
	.tt.l configure -text $::tt_text($w)
	# Sit just below the control's left edge; nudge left if it would run off the screen.
	update idletasks
	set x [winfo rootx $w]
	set y [expr {[winfo rooty $w] + [winfo height $w] + 2}]
	set over [expr {$x + [winfo reqwidth .tt] - [winfo screenwidth .tt]}]
	if {$over > 0} { set x [expr {$x - $over - 4}] }
	wm geometry .tt +$x+$y
	wm deiconify .tt
	raise .tt
}

# File pane body (D42): a header above a sunken "well" holding the rich-list view —
# a read-only text widget the navigator fills. It is GUI-local CHROME, not a core
# buffer: -state disabled, never renamed/proxied like the editor, never editable.
# The text widget is simply the best stock classic-Tk canvas for per-row glyph icons
# and full-width hover/selection bands (a listbox is text-only, one colour). -width 26
# (cols) keeps the dock's width stable when switching to the git pane (see below).
frame .pfiles -background "#dddddd"
# Files pane header: the project/subdir name (left) + a Refresh glyph (right), the same
# layout as the git pane header so the two panes reload the same way. ⟳ re-lists the
# shown directory and re-reads git flags via populate_nav — the manual counterpart to the
# fs.changed auto-refresh (D47), for changes rio didn't make (an external tool, git pull).
frame .pfiles.hdr -background "#dddddd"
label .pfiles.hdr.head -anchor w -font {monospace 9} -padx 4 -pady 2 \
	-background "#dddddd" -foreground black
label .pfiles.hdr.refresh -text "⟳" -font {monospace 9} -padx 6 \
	-background "#dddddd" -foreground black
label .pfiles.hdr.hidden -text "◌" -font {monospace 9} -padx 6 \
	-background "#dddddd" -foreground black
pack .pfiles.hdr.refresh -side right
pack .pfiles.hdr.hidden  -side right   ;# ◉/◌ toggle for hidden files, left of ⟳ (D62)
pack .pfiles.hdr.head    -side left -fill x -expand 1
pack .pfiles.hdr -side top -fill x
bind .pfiles.hdr.refresh <Button-1> populate_nav
bind .pfiles.hdr.hidden  <Button-1> nav_toggle_hidden
tooltip .pfiles.hdr.refresh "Refresh"   ;# the hidden toggle's tooltip is set (per state) by nav_hidden_glyph
frame .pfiles.well -borderwidth 2 -relief sunken -background white
scrollbar .pfiles.well.sb -command {.pfiles.well.body yview}
text .pfiles.well.body -width 26 -height 10 -wrap none -state disabled \
	-cursor arrow -insertwidth 0 -takefocus 1 \
	-borderwidth 0 -highlightthickness 0 -padx 2 -pady 1 \
	-background white -foreground black \
	-yscrollcommand {autoscroll .pfiles.well.sb .pfiles.well.body}
pack .pfiles.well -side top -fill both -expand 1
pack .pfiles.well.body -side left -fill both -expand 1
# .pfiles.well.sb is packed on demand by autoscroll (hidden when the list fits).
# The files pane doesn't act on mere selection (onselect empty); a double-click /
# Return opens the row (nav_open); right-click pops a context menu (nav_context_menu).
rl_init .pfiles.well.body {} nav_open nav_context_menu
# D87: the files pane splits the click — a single click on a folder's arrow unfolds it,
# a double-click on the name activates. Override the plain rl_* click binds (set by rl_init)
# on this body only; the git pane keeps the default select-on-single-click behaviour.
bind .pfiles.well.body <Button-1>        {nav_b1 %W %x %y ; break}
bind .pfiles.well.body <Double-Button-1> {nav_b1_double %W %x %y ; break}

# Git pane body: branch header + Refresh, the changed-file list (a rich-list well,
# D43 — same chrome as the file pane), and a read-only diff area below it.
frame .pgit -background "#dddddd"
frame .pgit.hdr -background "#dddddd"
label .pgit.hdr.branch -anchor w -font {monospace 9} -padx 4 -pady 2 \
	-background "#dddddd" -foreground black
label .pgit.hdr.refresh -text "⟳" -font {monospace 9} -padx 6 \
	-background "#dddddd" -foreground black
# ↩ discards every change in the repo (D93). Built here but NOT packed: refresh_git packs it
# (left of ⟳) only while the repo has changes, so the pane's one destructive control is
# absent from a clean repo — and a mis-click is caught by the No-defaulted confirm anyway.
label .pgit.hdr.discard -text "↩" -font {monospace 9} -padx 6 \
	-background "#dddddd" -foreground black
set ::git_change_count 0
pack .pgit.hdr.refresh -side right
pack .pgit.hdr.branch  -side left -fill x -expand 1
pack .pgit.hdr -side top -fill x
bind .pgit.hdr.refresh <Button-1> refresh_git
bind .pgit.hdr.discard <Button-1> git_discard_all_confirm
tooltip .pgit.hdr.refresh "Refresh"
tooltip .pgit.hdr.discard "Discard all changes"
frame .pgit.well -borderwidth 2 -relief sunken -background white
scrollbar .pgit.well.sb -command {.pgit.well.body yview}
text .pgit.well.body -width 26 -height 8 -wrap none -state disabled \
	-cursor arrow -insertwidth 0 -takefocus 1 \
	-borderwidth 0 -highlightthickness 0 -padx 2 -pady 1 \
	-background white -foreground black \
	-yscrollcommand {autoscroll .pgit.well.sb .pgit.well.body}
# -width 26 matches the file pane so the git pane does not balloon the dock (and the
# whole window) to the text widget's default 80 columns when it is shown.
text .pgit.diff -wrap none -width 26 -height 8 -state disabled \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black
ctx_bind_view .pgit.diff   ;# Copy / Select All (D115)
pack .pgit.well -side top -fill both -expand 1
pack .pgit.well.body -side left -fill both -expand 1
# .pgit.well.sb is packed on demand by autoscroll; .pgit.diff by git_show_diff.
# Picking a change (single click / arrow) shows its diff (git_pick); no separate
# activate; right-click pops a context menu (git_context_menu).
rl_init .pgit.well.body git_pick {} git_context_menu

# The commit bar (D45): rio's first inline text-input in a dock pane. A single-line
# summary entry + a Commit button, packed at the bottom of the git pane by refresh_git
# ONLY when something is staged (and hidden otherwise) — "appears only when needed", the
# D36 find-bar quality bar. Enter in the entry commits too. The ＋ toggle reveals an
# optional multi-line description (D80), joined to the summary as git's subject+body.
# Built here, not packed; git_commit_body_set lays out the row (body collapsed to start).
set ::git_commit_body_shown 0
frame  .pgit.commit -background "#dddddd"
entry  .pgit.commit.msg  -font {monospace 9} -textvariable git_commit_msg
button .pgit.commit.more -text "＋" -font {monospace 9} -takefocus 0 -command git_commit_body_toggle
button .pgit.commit.go   -text "✓ Commit" -font {monospace 9} -command git_commit
text   .pgit.commit.body -height 4 -font {monospace 9} -wrap word -undo 1 \
	-borderwidth 1 -relief solid -highlightthickness 0
# A greyed "message" hint, shown only while the entry is empty (Tk has no native
# placeholder). It is a child label placed inside the entry, so it never becomes part of
# `.msg get` — the empty check and the commit stay honest. A trace toggles it on content.
label .pgit.commit.msg.ph -text message -font {monospace 9} -takefocus 0 -borderwidth 0
place .pgit.commit.msg.ph -x 3 -rely 0.5 -anchor w
bind  .pgit.commit.msg.ph <Button-1> {focus .pgit.commit.msg}
# The body's own placeholder, same device — a child label over the text widget.
label .pgit.commit.body.ph -text "Longer description (optional)" -font {monospace 9} \
	-takefocus 0 -borderwidth 0
bind  .pgit.commit.body.ph <Button-1> {focus .pgit.commit.body}
# Cut/Copy/Paste/Select All on both fields (D115). The placeholder labels are PLACED ON
# TOP of them, so a right-click on an empty commit bar would hit the label and never
# reach the field — forward it, exactly as each label already forwards Button-1.
ctx_bind_input .pgit.commit.msg
ctx_bind_input .pgit.commit.body
ctx_bind_placeholder .pgit.commit.msg.ph  .pgit.commit.msg  input
ctx_bind_placeholder .pgit.commit.body.ph .pgit.commit.body input
trace add variable git_commit_msg write git_commit_hint
bind .pgit.commit.body <KeyRelease> git_commit_body_hint
bind .pgit.commit.body <FocusIn>    git_commit_body_hint
bind .pgit.commit.body <FocusOut>   git_commit_body_hint
tooltip .pgit.commit.more "Add a longer description"
git_commit_body_set 0   ;# summary row only; body hidden until ＋
# Enter in the one-line summary commits; in the multi-line body it inserts a newline, so
# Ctrl+Enter is the commit chord there (and works from the summary too, for muscle memory).
bind .pgit.commit.msg  <Return>         git_commit
bind .pgit.commit.msg  <Control-Return> git_commit
bind .pgit.commit.body <Control-Return> {git_commit ; break}

# A thin draggable divider between the dock and the editor. apply_layout parks it on
# whichever edge the dock occupies; dragging it resizes the dock (the editor, which
# -expands, absorbs the difference). The resize cursor on hover advertises the grip.
frame .sash -width 5 -cursor sb_h_double_arrow -background "#bbbbbb"
bind .sash <B1-Motion> sash_drag
# Record the dock's final width into its site on release (sizes persist now, D35 b).
bind .sash <ButtonRelease-1> { rio::layout::put left size [winfo width .siteleft] ; prefs_save }

# A horizontal divider between the editor and the bottom dock; dragging it resizes
# the bottom site's HEIGHT (the editor, which -expands, absorbs the difference).
frame .bsash -height 5 -cursor sb_v_double_arrow -background "#bbbbbb"
bind .bsash <B1-Motion> bsash_drag
bind .bsash <ButtonRelease-1> { rio::layout::put bottom size [winfo height .sitebottom] ; prefs_save }

# The editor region (AGENTS.md D33). The center is a .groups panedwindow that holds one
# or two editor GROUPS side by side with a draggable divider; each group is an
# independent text widget (with its own tab strip, scrollbars, and highlight cache)
# built by make_editor_group. Each text widget is renamed to a real command (::real<g>)
# and driven through a proxy proc at its Tk path so class bindings still call
# `.eg<g>.t insert`, which the proxy turns into protocol requests (the D3 dumb-view
# discipline, now per group). The horizontal bar auto-hides (gridscroll) when no line
# overflows, and apply_wrap drops it entirely while wrapping.
panedwindow .groups -orient horizontal -borderwidth 0 \
	-sashwidth 6 -sashrelief raised -opaqueresize 1

# A one-shot undo break (D90). The core merges a run of single-character edits
# into one undo step — right for typing, wrong for a repeated command: vi's `x`
# pressed three times is three one-character deletions the core cannot tell from
# three presses of Delete. A mode about to dispatch a discrete command arms this,
# and the next edit through the proxy starts its own undo step.
set ::undo_break 0
proc undo_break {} { set ::undo_break 1 }

# The coalesce flag for the edit being sent now, consuming any armed break.
proc undo_coalesce {} {
	if {!$::undo_break} { return 1 }
	set ::undo_break 0
	return 0
}

# The per-widget proxy: an insert/delete becomes a buffer.replace on THIS group's
# active buffer; everything else passes straight through to the real widget command.
proc editor_proxy {g args} {
	set rc [gw $g]
	switch -- [lindex $args 0] {
		insert {
			# .t insert <index> <chars> ?tagList chars ...?
			set idx   [$rc index [lindex $args 1]]
			set chars [lindex $args 2]
			if {$chars ne ""} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer [gcur $g] start $idx end $idx text $chars \
						coalesce [undo_coalesce]]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		delete {
			# .t delete <index1> ?index2?  — compute i2 WITHOUT expr. A Tk text index
			# like "1.10" passed through expr is coerced to the float 1.1, silently
			# corrupting the column: backspace would then no-op at every column 10, 20,
			# 30, … (and forward/range deletes ending there too).
			set i1 [$rc index [lindex $args 1]]
			if {[llength $args] >= 3} {
				set i2 [$rc index [lindex $args 2]]
			} else {
				set i2 [$rc index "[lindex $args 1]+1c"]
			}
			if {[$rc compare $i1 < $i2]} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer [gcur $g] start $i1 end $i2 text {} \
						coalesce [undo_coalesce]]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		replace {
			# .t replace <index1> <index2> <chars> — one edit, one undo step
			# (paste over a selection). Same index discipline as delete: no expr.
			set i1    [$rc index [lindex $args 1]]
			set i2    [$rc index [lindex $args 2]]
			set chars [lindex $args 3]
			if {[$rc compare $i1 < $i2] || $chars ne ""} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer [gcur $g] start $i1 end $i2 text $chars \
						coalesce [undo_coalesce]]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		default { return [$rc {*}$args] }
	}
}

# ---------------------------------------------------------------------------
# Shared clipboard actions on an editor widget (D38). One implementation serves
# the Edit menu and whichever editing mode binds keys to them (the Windows mode
# does), so menu and keyboard can never drift apart. `w` is a group's PROXY path:
# the cut/paste edits run through editor_proxy and reach the core; copy only
# reads. Paste REPLACES a selection (the Windows/VSCode convention — Tk's own
# x11 <<Paste>> leaves it in place) as a single replace, i.e. one undo step.
# ---------------------------------------------------------------------------
proc editor_select_all {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	$w tag remove sel 1.0 end
	$w tag add sel 1.0 "end -1c"
}

proc editor_copy {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[llength [$w tag ranges sel]] == 0} return
	clipboard clear
	clipboard append [$w get sel.first sel.last]
}

proc editor_cut {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[llength [$w tag ranges sel]] == 0} return
	clipboard clear
	clipboard append [$w get sel.first sel.last]
	$w delete sel.first sel.last
}

proc editor_paste {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[catch {clipboard get} txt] || $txt eq ""} return
	if {[llength [$w tag ranges sel]] > 0} {
		$w replace sel.first sel.last $txt
	} else {
		$w insert insert $txt
	}
	$w see insert
}

# ---------------------------------------------------------------------------
# The editor's context menu (AGENTS.md D108), and the table it shares with the
# Edit menu.
#
# D38's rule — one implementation behind the menu and the mode keys, so they
# cannot drift — applied one level up, to the two MENUS. `editor_menu_items`
# is the whole of the Edit menu's action block; the menubar builds from it and
# so does the right-click menu, which then appends the find group of its own.
#
# Each row is {label command accel state}. No accelerators on the clipboard
# three: those keys belong to the editing mode (Ctrl+X/C/V in the Windows mode;
# emacs and vi have their own ideas), so a fixed label here could lie — the same
# reason the Edit menu has shown none since D38.
#
# The greys are only the ones rio can compute HONESTLY:
#   • Undo/Redo stay enabled — the history lives in the core and there is no
#     "can undo" query to ask (ops-undo.tcl registers edit.undo/edit.redo and
#     nothing else). A grey we cannot compute would be a guess.
#   • Paste stays enabled — probing the clipboard means a blocking X round-trip
#     to whichever application owns the selection, and an unresponsive owner
#     would stall the menu on its way up. An empty clipboard already does
#     nothing, silently, in editor_paste.
#
# `w` decides the GREYS only. Every command is late-bound — editor_cut and its
# neighbours resolve [gget $::focus path] when they are invoked — so both menus act
# on the focused group, and the right-click's own job is to make the group you
# clicked the focused one before the menu is built (editor_context_click).
# ---------------------------------------------------------------------------
proc editor_menu_items {w} {
	set sel  [expr {[llength [$w tag ranges sel]] ? "normal" : "disabled"}]
	set some [expr {[$w compare "end -1c" > 1.0] ? "normal" : "disabled"}]
	return [list \
		[list "Undo"       do_undo             [key_accel undo] normal] \
		[list "Redo"       do_redo             [key_accel redo] normal] \
		[list "-"          {}                  {}               {}] \
		[list "Cut"        editor_cut          {}               $sel] \
		[list "Copy"       editor_copy         {}               $sel] \
		[list "Paste"      editor_paste        {}               normal] \
		[list "-"          {}                  {}               {}] \
		[list "Select All" editor_select_all   {}               $some]]
}

# Append the rows to a menu (a separator for the "-" rows).
proc editor_menu_fill {m items} {
	foreach it $items {
		lassign $it label cmd accel state
		if {$label eq "-"} { $m add separator ; continue }
		$m add command -label $label -command $cmd -accelerator $accel -state $state
	}
}

# Re-derive the Edit menu's greys for the focused group each time it is posted.
# Only -state: the labels and accelerators stay as built, so keymap_refresh_menus
# keeps addressing them by label.
proc editor_menu_post {} {
	if {$::focus eq "" || ![dict exists $::grp $::focus]} return
	foreach it [editor_menu_items [gget $::focus path]] {
		lassign $it label cmd accel state
		if {$label eq "-"} continue
		catch {.m.edit entryconfigure $label -state $state}
	}
}

# What a right-click does BEFORE the menu appears (the Win98/VSCode convention):
# click inside the selection and it survives untouched, so Cut/Copy/Search act on
# what you can see is highlighted; click anywhere else and the selection is
# cleared and the caret moves to the character you pointed at, so Paste lands
# there. Tk moves keyboard focus on Button-1 only, and Undo/Find/Search all act on
# the FOCUSED group (::focus / ::cur) — so a right-click in the other half of a
# split has to focus it first, or the menu would quietly act on the other pane.
proc editor_context_click {g x y} {
	set w [gget $g path]
	focus_group $g
	focus $w
	set idx [$w index @$x,$y]
	set inside 0
	foreach {from to} [$w tag ranges sel] {
		if {[$w compare $idx >= $from] && [$w compare $idx < $to]} { set inside 1 ; break }
	}
	if {!$inside} {
		$w tag remove sel 1.0 end
		$w mark set insert $idx
	}
	cursor_moved $g
}

# Fill menu `m` for group `g`: the shared Edit block, then the find group.
#
# The find items are the context menu's own (D75 lifted them out of Edit into
# their own top-level menu) because they are the ones that act on the selection
# you just right-clicked: find_open and search_open ALREADY seed their entry from
# the focused group's selection, single-line only. The Search label says so —
# with a usable selection it quotes it; with none, or one spanning lines (the two
# cases search_open will not seed from), it is the plain "Search…" the Find menu
# carries. Rebuilt on every popup, so the quoted text and every accelerator are
# current by construction.
proc editor_context_build {m g} {
	set w [gget $g path]
	editor_menu_fill $m [editor_menu_items $w]
	$m add separator
	$m add command -label "Find…"    -accelerator [key_accel find]    -command {find_open 0}
	$m add command -label "Replace…" -accelerator [key_accel replace] -command {find_open 1}
	$m add command -label [editor_search_label $w] \
		-accelerator [key_accel search] -command search_open
	# Change with Agent… (D113), last and behind its own separator. An AI entry must not
	# get in the way of people who don't use one, so it appears only while a real provider
	# is selected (Echo can't change anything) and the preference hasn't hidden it. The
	# grey is honest: it needs a selection, and a turn that isn't already under way.
	if {$::agent_selection_menu && $::agent_provider ne "echo"} {
		set ok [expr {[agent_selection_scope $g] ne "" && !$::chat_busy && $::pending_turn eq ""}]
		$m add separator
		$m add command -label "Change with Agent…" -state [expr {$ok ? "normal" : "disabled"}] \
			-command [list agent_change_dialog $g]
	}
}

# Group `g`'s selection as agent.send's scope {buffer start end} (D113), or "" when
# there is none. Indices are the widget's own — the core's line.col is the same form (D12).
proc agent_selection_scope {g} {
	set w [gget $g path]
	if {[catch {list [$w index sel.first] [$w index sel.last]} r]} { return "" }
	lassign $r a b
	if {[$w compare $a >= $b]} { return "" }
	return [dict create buffer [gcur $g] start $a end $b]
}

# "foo.tcl, lines 12–20" — where a scope is, as the dialog and the transcript say it.
# A selection ending at column 0 doesn't count that last line (the D38 block rule).
proc agent_scope_label {scope} {
	set l1 [lindex [split [dict get $scope start] .] 0]
	lassign [split [dict get $scope end] .] l2 c2
	if {$l2 > $l1 && $c2 == 0} { incr l2 -1 }
	return "[tab_name [dict get $scope buffer]], [expr {$l1 == $l2 ? "line $l1" : "lines $l1–$l2"}]"
}

# Send the instruction as a turn scoped to `scope`: the Agent pane comes into view,
# because the review bar and the transcript live there.
proc agent_change_send {text scope} {
	set text [string trim $text]
	if {$text eq ""} return
	if {![rio::layout::shown chat]} { panel_reveal chat }
	chat_send_text $text $scope "on the selection in [agent_scope_label $scope]"
}

# The small dialog behind the entry: where the selection is, what to do with it, Send.
# The scope is taken when the dialog opens, so the request is about what was selected
# when the user asked; the core checks it again before anything changes.
proc agent_change_dialog {g} {
	set scope [agent_selection_scope $g]
	if {$scope eq ""} { bell ; return }
	set w .agentchg
	destroy $w
	toplevel $w
	wm title $w "Change with Agent"
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.where -text "Selection: [agent_scope_label $scope]" -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	label $w.hint -text "Enter sends · Shift+Enter starts a new line" -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	text $w.input -width 56 -height 5 -wrap word -undo 1 -font RioUIFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.fg] -highlightthickness 1
	ctx_bind_input $w.input   ;# (D115)
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.send   -text Send   -font RioUIFont -default active \
		-command [list agent_change_submit $w $scope]
	button $w.btns.cancel -text Cancel -font RioUIFont -command [list destroy $w]
	pack $w.btns.cancel $w.btns.send -side right -padx 3
	grid $w.where -row 0 -column 0 -sticky w  -padx 8 -pady {8 2}
	grid $w.input -row 1 -column 0 -sticky nsew -padx 8 -pady 2
	grid $w.hint  -row 2 -column 0 -sticky w  -padx 8 -pady {0 2}
	grid $w.btns  -row 3 -column 0 -sticky e  -padx 5 -pady {2 8}
	grid rowconfigure $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	bind $w.input <Return>       "[list agent_change_submit $w $scope] ; break"
	bind $w.input <Shift-Return> { %W insert insert "\n" ; break }
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.input
}
proc agent_change_submit {w scope} {
	set text [$w.input get 1.0 end]
	if {[string trim $text] eq ""} { bell ; return }
	destroy $w
	agent_change_send $text $scope
}

# The Search entry's label for the current selection (see above). 20 characters
# is the cap: long enough to recognise the needle, short enough that the menu
# keeps its shape.
proc editor_search_label {w} {
	if {[catch {$w get sel.first sel.last} s]} { return "Search…" }
	if {$s eq "" || [string first "\n" $s] >= 0} { return "Search…" }
	if {[string length $s] > 20} { set s "[string range $s 0 19]…" }
	return "Search for “$s”"
}

# Right-click: place the caret/selection, then post a fresh menu — the D44 idiom,
# with the builder split from the popup so a headless test can read the entries
# without a global grab nobody is there to dismiss.
proc editor_context_menu {g x y X Y} {
	editor_context_click $g $x $y
	catch {destroy .edmenu}
	menu .edmenu -tearoff 0
	editor_context_build .edmenu $g
	tk_popup .edmenu $X $Y
}

# The keyboard route (the Menu key, Shift+F10): the same menu at the caret. No
# click, so nothing about the selection changes. The caret's bbox is empty when it
# has been scrolled out of view — then the widget's top-left corner stands in.
proc editor_context_key {g} {
	set w [gget $g path]
	focus_group $g
	set X [winfo rootx $w] ; set Y [winfo rooty $w]
	if {[set bb [$w bbox insert]] ne ""} {
		lassign $bb bx by bw bh
		set X [expr {$X + $bx}] ; set Y [expr {$Y + $by + $bh}]
	}
	catch {destroy .edmenu}
	menu .edmenu -tearoff 0
	editor_context_build .edmenu $g
	tk_popup .edmenu $X $Y
}

# ---------------------------------------------------------------------------
# Block indent / dedent (D38). The Windows mode binds these to Tab / Shift+Tab.
# With a selection, every line the selection touches shifts by one tab as a
# SINGLE core edit (one undo step, one round-trip): existing leading tabs and
# spaces are kept and pushed along, never replaced — so a selection is indented,
# never deleted (Tk's own <Tab> would delete it). Tab with no selection inserts a
# plain tab at the caret (the Notepad feel); Shift+Tab with no selection dedents
# the caret's line. The block edits go through the group PROXY (`w`) to the core.
# Indenting/dedenting never changes the line count, so the block is re-selected
# afterward — press Tab again to add another level.
# ---------------------------------------------------------------------------
proc editor_indent {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[llength [$w tag ranges sel]] == 0} { $w insert insert \t ; $w see insert ; return }
	editor_shift_lines $w 1
}
proc editor_dedent {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	editor_shift_lines $w -1
}

# Shift the line span the selection (else the caret) covers by one indent level:
# dir 1 adds a tab in front of each line, dir -1 removes one level. A selection
# that ends at column 0 does NOT pull in that trailing line — its text is
# untouched (the VSCode/Notepad++ rule).
proc editor_shift_lines {w dir} {
	set had_sel [expr {[llength [$w tag ranges sel]] > 0}]
	if {$had_sel} {
		set l1 [lindex [split [$w index sel.first] .] 0]
		set le [split [$w index sel.last] .]
		set l2 [lindex $le 0]
		if {$l2 > $l1 && [lindex $le 1] == 0} { incr l2 -1 }
	} else {
		set caret [split [$w index insert] .]
		set l1 [lindex $caret 0] ; set l2 $l1 ; set caretcol [lindex $caret 1]
	}
	set start $l1.0
	set end   [$w index "$l2.0 lineend"]
	set out {} ; set changed 0 ; set removedfirst 0 ; set i 0
	foreach ln [split [$w get $start $end] \n] {
		if {$dir > 0} {
			# Don't grow a wholly blank line into trailing whitespace.
			if {$ln eq ""} { lappend out $ln } else { lappend out "\t$ln" ; set changed 1 }
		} else {
			set s [editor_dedent_one $ln]
			if {$i == 0} { set removedfirst [expr {[string length $ln] - [string length $s]}] }
			if {$s ne $ln} { set changed 1 }
			lappend out $s
		}
		incr i
	}
	if {!$changed} return
	$w replace $start $end [join $out \n]
	if {$had_sel} {
		$w tag remove sel 1.0 end
		$w tag add sel $l1.0 [$w index "$l2.0 lineend"]
		$w mark set insert [$w index "$l2.0 lineend"]
	} else {
		# Caret-only dedent: keep the caret over the same character by pulling it
		# left by however much whitespace this line lost (clamped to line start).
		set col [expr {$caretcol - $removedfirst}] ; if {$col < 0} { set col 0 }
		$w mark set insert $l1.$col
	}
	$w see insert
}

# One indent level off the front of a line: a leading tab, else up to a
# tab-stop's worth (4) of leading spaces. A line with no leading whitespace is
# returned unchanged.
proc editor_dedent_one {ln} {
	if {[string index $ln 0] eq "\t"} { return [string range $ln 1 end] }
	set n 0
	while {$n < 4 && [string index $ln $n] eq " "} { incr n }
	return [string range $ln $n end]
}

# ---------------------------------------------------------------------------
# Column / block editing (AGENTS.md D40). Ctrl+Shift+drag makes a vertical,
# multi-line cursor. Its zero-width form is a CARET COLUMN: typing / Backspace /
# Delete / Tab act at one column on EVERY spanned line; drag a width and typing
# overwrites that rectangular slice per line. Off by default (::col_on), a
# Settings toggle. Notepad++'s real gesture is Alt+drag, but Linux/X11 window
# managers grab Alt+drag to move the window, so rio uses Ctrl+Shift+drag.
#
# The whole feature is GUI-side. A column operation is emitted as ONE
# buffer.replace over L1.0..L2.lineend with the transformed block, so it is a
# single undo step — the same shape as replace_all and the D38 block-indent. All
# these procs work on the group PROXY path `w` (edits route through editor_proxy
# to the core; reads/tags/marks pass through). The windows mode binds them,
# pref-gated; vi/emacs keep their own block notions. Columns are CHARACTER
# columns (a tab inside the band may look misaligned — a documented v1 edge).
# ---------------------------------------------------------------------------

# Is a live column selection on THIS widget? (Guards every key/edit handler.)
proc col_here {w} { return [expr {$::col_active && $w eq $::col_w}] }

# Character length of line L in widget w.
proc col_linelen {w L} { return [lindex [split [$w index "$L.0 lineend"] .] 1] }

# Pad a line to at least n chars with spaces (column mode's virtual space).
proc col_pad {line n} {
	set d [expr {$n - [string length $line]}]
	if {$d > 0} { append line [string repeat " " $d] }
	return $line
}

# The line span (L1..L2) and column span (C1..C2) the selection currently covers.
proc col_span {} {
	lassign [split $::col_anchor .] al ac
	lassign [split $::col_caret  .] cl cc
	return [list [expr {min($al,$cl)}] [expr {max($al,$cl)}] \
	             [expr {min($ac,$cc)}] [expr {max($ac,$cc)}]]
}

# Start a column selection at the widget pixel (x,y): anchor = caret = @x,y.
proc col_begin {w x y} {
	if {!$::col_on} return
	set g [group_of_widget $w]
	if {$g ne ""} { focus_group $g }
	focus $w
	$w tag remove sel 1.0 end
	set idx [$w index @$x,$y]
	set ::col_w $w ; set ::col_anchor $idx ; set ::col_caret $idx ; set ::col_active 1
	col_paint
}

# Extend the moving end to @x,y as the mouse drags.
proc col_motion {w x y} {
	if {![col_here $w]} return
	set ::col_caret [$w index @$x,$y]
	col_paint
}

# Destroy the placed caret bars, stop the blink loop, and give the widget its native
# insert bar back (col_bars_draw hides it so the caret line blinks in phase with the
# rest rather than showing two out-of-phase bars). Idempotent.
proc col_bars_clear {} {
	if {$::col_blink ne ""} { after cancel $::col_blink ; set ::col_blink "" }
	foreach b $::col_bars { catch {destroy $b} }
	set ::col_bars {} ; set ::col_blink_on 1
	if {$::col_insw ne "" && $::col_w ne ""} {
		catch { $::col_w configure -insertwidth $::col_insw }
	}
	set ::col_insw ""
}

# The x pixel of column C on line L of widget w — bbox of the character there, or,
# past the line's end (column mode's virtual space), the line-end x plus the
# remaining columns' worth of a space glyph. "" if the line isn't laid out (off
# screen). y/h come from the same bbox so bars match the line height.
proc col_caret_xy {w L C} {
	set len [col_linelen $w $L]
	if {$C <= $len} {
		set bb [$w bbox $L.$C]
		if {$bb eq ""} { return "" }
		lassign $bb x y bw h
		return [list $x $y $h]
	}
	set bb [$w bbox "$L.$len"]
	if {$bb eq ""} { return "" }
	lassign $bb x y bw h
	set sp [font measure [$w cget -font] " "]
	return [list [expr {$x + $bw + ($C - $len - 1) * $sp}] $y $h]
}

# Draw one thin caret bar per spanned line at column C (the zero-width form). The
# bars overlay the text via place; they blink together via col_blink_tick, matching
# the look of the normal caret across every line rather than a solid block.
proc col_bars_draw {L1 L2 C} {
	col_bars_clear
	set w $::col_w
	set fg [dict get $::theme_colors editor.cursor]
	# Hide the native insert bar so the caret line blinks with the drawn bars, not
	# against them; col_bars_clear restores it (saved width, default 2 if unset).
	set iw [$w cget -insertwidth]
	set ::col_insw [expr {$iw == 0 ? 2 : $iw}]
	catch { $w configure -insertwidth 0 }
	# bbox coordinates already include the widget's -padx/-pady, but `place -in`
	# adds them again — a double-count that lands the bar ~half a cell into the
	# glyph. Subtract them so the bar sits on the true cell boundary (bbox.x), the
	# exact spot Tk draws the native insert bar. Font-size independent, no fudging.
	set px [$w cget -padx] ; set py [$w cget -pady]
	for {set L $L1} {$L <= $L2} {incr L} {
		set xy [col_caret_xy $w $L $C]
		if {$xy eq ""} continue
		lassign $xy x y h
		set b $w.colbar$L
		catch {destroy $b}
		frame $b -background $fg -bd 0 -width 1 -height $h
		place $b -in $w -x [expr {$x - $px}] -y [expr {$y - $py}] -width 1 -height $h
		lappend ::col_bars $b
	}
	set ::col_blink_on 1
	set ::col_blink [after 500 col_blink_tick]
}

# Toggle every caret bar's visibility, then reschedule — one shared blink phase.
proc col_blink_tick {} {
	if {![info exists ::col_bars] || $::col_bars eq ""} { set ::col_blink "" ; return }
	set ::col_blink_on [expr {!$::col_blink_on}]
	set fg [dict get $::theme_colors editor.cursor]
	set w $::col_w
	set bg [$w cget -background]
	foreach b $::col_bars {
		catch { $b configure -background [expr {$::col_blink_on ? $fg : $bg}] }
	}
	set ::col_blink [after 500 col_blink_tick]
}

# Repaint the block highlight (coltag) or the caret column. A width selection is a
# rectangular coltag band per line; the zero-width form is a thin blinking caret
# bar on every spanned line (col_bars_draw), so it reads as one cursor stretched
# down the column rather than a stack of solid blocks. The caret line also carries
# Tk's own insert bar at ::col_caret.
proc col_paint {} {
	if {!$::col_active} return
	set w $::col_w
	$w tag remove coltag 1.0 end
	lassign [col_span] L1 L2 C1 C2
	if {$C2 > $C1} {
		col_bars_clear
		for {set L $L1} {$L <= $L2} {incr L} {
			set len [col_linelen $w $L]
			set a [expr {min($C1,$len)}] ; set b [expr {min($C2,$len)}]
			if {$b > $a} { $w tag add coltag $L.$a $L.$b }
		}
	}
	catch { $w mark set insert $::col_caret ; $w see insert }
	# Draw the bars AFTER `see` so bbox reflects the final scroll position.
	if {$C2 <= $C1} { col_bars_draw $L1 $L2 $C1 }
}

# Collapse the column selection and hand a single normal caret back.
proc col_clear {} {
	if {!$::col_active} return
	set w $::col_w
	col_bars_clear
	catch { $w tag remove coltag 1.0 end }
	catch { $w mark set insert $::col_caret ; $w see insert }
	set ::col_active 0 ; set ::col_w ""
}

# Apply one column operation across every spanned line as a SINGLE span replace
# (one undo). op: insert (a char/tab), delfwd (Delete), delback (BackSpace).
proc col_edit {op {ch ""}} {
	if {!$::col_active} return
	set w $::col_w
	lassign [col_span] L1 L2 C1 C2
	set start $L1.0 ; set end [$w index "$L2.0 lineend"]
	set block [$w get $start $end]
	set out {} ; set newcol $C1
	foreach line [split $block \n] {
		switch -- $op {
			insert {
				set line [col_pad $line $C1]
				lappend out [string range $line 0 [expr {$C1-1}]]$ch[string range $line $C2 end]
				set newcol [expr {$C1 + [string length $ch]}]
			}
			delfwd {
				if {$C2 > $C1} {
					set line [col_pad $line $C1]
					lappend out [string range $line 0 [expr {$C1-1}]][string range $line $C2 end]
				} elseif {$C1 < [string length $line]} {
					lappend out [string range $line 0 [expr {$C1-1}]][string range $line [expr {$C1+1}] end]
				} else { lappend out $line }
				set newcol $C1
			}
			delback {
				if {$C2 > $C1} {
					set line [col_pad $line $C1]
					lappend out [string range $line 0 [expr {$C1-1}]][string range $line $C2 end]
					set newcol $C1
				} elseif {$C1 > 0} {
					lappend out [string range $line 0 [expr {$C1-2}]][string range $line $C1 end]
					set newcol [expr {$C1 - 1}]
				} else { lappend out $line ; set newcol 0 }
			}
		}
	}
	set newblock [join $out \n]
	if {$newblock eq $block} { return }   ;# no-op (e.g. BackSpace at column 0)
	$w replace $start $end $newblock       ;# proxy -> one buffer.replace -> one undo
	# Collapse to a caret column at the new column, same line span; keep it live so
	# the next keystroke keeps typing down the column.
	set ::col_anchor $L1.$newcol ; set ::col_caret $L2.$newcol
	col_paint
}

# Key hooks the windows mode binds. Each returns 1 when it consumed the event
# (the binding then breaks), 0 to let normal editing through.
proc col_typed {w ch state} {
	if {![col_here $w]} { return 0 }
	if {$ch eq "" || ($state & 0x0C)} { return 0 }   ;# Control/Alt held, or no char
	if {![string is print -strict $ch]} { return 0 } ;# Tab/Return/BackSpace handled elsewhere
	col_edit insert $ch ; return 1
}
proc col_key {w op} {
	if {![col_here $w]} { return 0 }
	col_edit $op ; return 1
}

# Settings toggle: turning it off ends any live selection, then persist.
proc apply_column_edit {} {
	if {!$::col_on} { col_clear }
	prefs_save
}

# ---------------------------------------------------------------------------
# Keymap (AGENTS.md D23): ONE table maps a logical command -> {chord action}. It is
# the single source of truth for the editor's keyboard shortcuts AND for the
# accelerator labels shown in the menus, so a remap moves both together. Users remap
# by dropping a keys.json in the config dir (D21) — {"command":"chord", ...} overrides
# the default chord per command; "" unbinds one. Chords are Tk event syntax minus the
# <>: modifiers Control/Shift/Alt joined by '-', then the key (a letter, or a keysym
# like Tab/backslash/bracketright). A capital letter carries an implicit Shift, the Tk
# convention: Control-S is Ctrl+Shift+S. New commands slot in here as one line each —
# the binder and the menus pick them up with no further wiring.
# ---------------------------------------------------------------------------
# Each entry is {chord action label}: `action` is the KEY behaviour (a menu item may run
# a different -command — split-editor's key toggles, its menu only splits — and just
# borrows this chord for its accelerator); `label` is the human name the shortcuts editor
# shows. An override changes only the chord; action and label are fixed in code here.
set ::keymap_default {
	new            {Control-n            do_new                                                        "New tab"}
	open           {Control-o            open_dialog                                                   "Open file…"}
	open-folder    {Control-O            open_folder_dialog                                            "Open folder…"}
	save           {Control-s            do_save                                                       "Save"}
	save-as        {Control-S            save_as_dialog                                                "Save As…"}
	close-tab      {Control-w            do_close                                                      "Close tab"}
	quit           {Control-q            do_quit                                                       "Quit"}
	undo           {Control-z            do_undo                                                       "Undo"}
	redo           {Control-Z            do_redo                                                       "Redo"}
	redo-alt       {Control-y            do_redo                                                        "Redo (alternate)"}
	find           {Control-f            {find_open 0}                                                 "Find…"}
	replace        {Control-h            {find_open 1}                                                 "Replace…"}
	find-next      {F3                   find_next                                                     "Find next"}
	find-prev      {Shift-F3             find_prev                                                     "Find previous"}
	search         {Control-F            search_open                                                   "Search…"}
	next-tab       {Control-Tab          {cycle 1}                                                     "Next tab"}
	prev-tab       {Control-Shift-Tab    {cycle -1}                                                    "Previous tab"}
	show-files     {Control-E            {show_pane files}                                             "Show files pane"}
	show-git       {Control-G            {show_pane git}                                               "Show git pane"}
	toggle-wrap    {Control-W            {set ::wrap_lines [expr {!$::wrap_lines}] ; apply_wrap}        "Toggle line wrap"}
	toggle-linenums {Control-l           {set ::line_numbers [expr {!$::line_numbers}] ; apply_line_numbers} "Toggle line numbers"}
	toggle-chat    {Control-A            {panel_toggle chat}                                           "Toggle agent pane"}
	split-editor   {Control-backslash    toggle_split                                                  "Toggle editor split"}
	move-tab-other {Control-bracketright move_tab_other                                                "Move tab to other group"}
	preferences    {{}                   preferences_window                                            "Preferences…"}
	help           {F1                   help_window                                                   "Help contents…"}
}
set ::keymap     $::keymap_default ;# resolved map (defaults + user overrides); keymap_resolve fills it
set ::keymap_bad {}                ;# entries keys.json got wrong, for one post-startup notice
set ::keymap_live_chords {}        ;# chords currently bound on the group widgets (to clear on a live remap)

proc keys_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio keys.json]
}

# Is `chord` a usable binding? (An empty chord is a deliberate unbind.) Tk's `bind`
# accepts almost any string — it treats unknown tokens as modifiers/keysyms that simply
# never fire — so a probe-bind can't flag a typo. We instead check the shape ourselves:
# every token before the key must be a known modifier. That catches the likely mistake
# (a misspelled modifier); we don't try to enumerate every keysym, so a bogus *key*
# still binds harmlessly and just never triggers.
proc keymap_valid {chord} {
	if {$chord eq ""} { return 1 }
	set mods {Control Ctrl Shift Alt Meta Command Option \
		Mod1 Mod2 Mod3 Mod4 Mod5 Lock Extended}
	set parts [split $chord -]
	foreach m [lrange $parts 0 end-1] { if {$m ni $mods} { return 0 } }
	return [expr {[lindex $parts end] ne ""}]
}

# Merge user overrides (keys.json: command -> chord) over the defaults into ::keymap.
# Only known commands with a Tk-valid chord are honoured; a missing/corrupt file, an
# unknown command, or a bad chord is ignored (a broken keys.json must never stop the
# editor). What was ignored is collected in ::keymap_bad for a single startup notice.
proc keymap_resolve {} {
	set ::keymap $::keymap_default
	set ::keymap_bad {}
	set path [keys_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {set over [json::json2dict [slurp_utf8 $path]]}]} {
		lappend ::keymap_bad "keys.json is not valid JSON — ignored" ; return
	}
	dict for {cmd chord} $over {
		if {![dict exists $::keymap_default $cmd]} {
			lappend ::keymap_bad "unknown command \"$cmd\"" ; continue
		}
		if {![keymap_valid $chord]} {
			lappend ::keymap_bad "\"$cmd\": invalid chord \"$chord\"" ; continue
		}
		# Replace only the chord; keep the command's action and label (set in code).
		dict set ::keymap $cmd [lreplace [dict get $::keymap $cmd] 0 0 $chord]
	}
}

# The chord bound to `cmd` in the resolved keymap ("" if unbound / unknown).
proc key_chord {cmd} {
	if {![dict exists $::keymap $cmd]} { return "" }
	return [lindex [dict get $::keymap $cmd] 0]
}

# The human name of `cmd` (the shortcuts editor's row label); falls back to the id.
proc key_label {cmd} {
	if {![dict exists $::keymap_default $cmd]} { return $cmd }
	set l [lindex [dict get $::keymap_default $cmd] 2]
	return [expr {$l eq "" ? $cmd : $l}]
}

# A human accelerator label for `cmd`, derived from its resolved chord so a remap
# updates the menu automatically. "" when unbound (the menu then shows no accelerator).
proc key_accel {cmd} { return [chord_label [key_chord $cmd]] }

# Turn a Tk chord (Control-Shift-e, Control-backslash, Control-S) into a display label
# (Ctrl+Shift+E, Ctrl+\, Ctrl+Shift+S). A lone capital letter carries an implicit Shift.
proc chord_label {chord} {
	if {$chord eq ""} { return "" }
	set parts [split $chord -]
	set key   [lindex $parts end]
	set out {} ; set shift 0
	foreach m [lrange $parts 0 end-1] {
		switch -- $m {
			Control - Ctrl    { lappend out Ctrl }
			Shift             { set shift 1 }
			Alt - Mod1 - Meta { lappend out Alt }
			default           { lappend out $m }
		}
	}
	if {[string length $key] == 1 && [string is upper $key]} { set shift 1 }
	if {$shift} { lappend out Shift }
	set order {}
	foreach want {Ctrl Alt Shift} { if {$want in $out} { lappend order $want } }
	lappend order [key_glyph $key]
	return [join $order +]
}

# Display glyph for a single key: letters upper-cased, common keysyms to their symbol.
proc key_glyph {key} {
	set map [dict create \
		backslash "\\" bracketright "]" bracketleft "\[" slash "/" grave "`" \
		semicolon ";" comma "," period "." minus "-" equal "=" space "Space"]
	if {[dict exists $map $key]}        { return [dict get $map $key] }
	if {[string length $key] == 1}      { return [string toupper $key] }
	return $key   ;# Tab, Escape, Return, F5, … shown as-is
}

# Editor keyboard shortcuts, bound on a group's text widget with `break` so the
# widget's own class bindings (Tk's built-in Ctrl+O/Ctrl+Z etc.) don't also fire.
# Bound per group so a shortcut acts on whichever group has keyboard focus — driven
# entirely by the resolved ::keymap, so nothing here changes when a command is added.
proc editor_bindings {w} {
	dict for {cmd spec} $::keymap {
		lassign $spec chord action
		if {$chord eq ""} continue   ;# a deliberately unbound command
		catch { bind $w <$chord> "$action ; break" }
	}
}

# Document-view zoom (D56): Ctrl+scroll and Ctrl +/- resize the editor font, Ctrl+0
# resets it. These are fixed accelerators, not remappable keymap entries — like the
# compare pane's Esc — so they bind directly here rather than through ::keymap. Bound
# on the editor widget AND its gutter so a zoom works with the pointer over either.
# `break` stops a Control-wheel from also plain-scrolling via the Text class binding.
# Both the X11 (Button-4/5) and Windows/macOS (MouseWheel + %D) wheel idioms are wired,
# matching the plain-scroll bindings the gutter already carries.
proc editor_zoom_bindings {w} {
	bind $w <Control-MouseWheel> {editor_zoom [expr {%D > 0 ? 1 : -1}] ; break}
	bind $w <Control-Button-4>   {editor_zoom 1 ; break}
	bind $w <Control-Button-5>   {editor_zoom -1 ; break}
	bind $w <Control-plus>       {editor_zoom 1 ; break}
	bind $w <Control-equal>      {editor_zoom 1 ; break}   ;# Ctrl+= so no Shift is needed
	bind $w <Control-KP_Add>     {editor_zoom 1 ; break}
	bind $w <Control-minus>      {editor_zoom -1 ; break}
	bind $w <Control-KP_Subtract> {editor_zoom -1 ; break}
	bind $w <Control-Key-0>      {editor_zoom_reset ; break}
	bind $w <Control-KP_0>       {editor_zoom_reset ; break}
}

# The non-empty chords in the resolved keymap.
proc keymap_chords {} {
	set out {}
	dict for {cmd spec} $::keymap { set c [lindex $spec 0] ; if {$c ne ""} { lappend out $c } }
	return $out
}

# Re-apply the resolved keymap to every live editor group WITHOUT a restart: clear the
# chords bound last time (so a changed/unbound chord actually goes away — `bind` never
# removes, only overwrites), then bind the current set. ::keymap_live_chords tracks what
# is on the widgets so we know what to clear next time.
proc keymap_rebind_all {} {
	foreach g $::groups {
		set w [gget $g path]
		foreach c $::keymap_live_chords { catch {bind $w <$c> ""} }
		editor_bindings $w
	}
	set ::keymap_live_chords [keymap_chords]
}

# Re-derive every menu accelerator from the current keymap (so a remap updates the labels
# shown in the menus, not just the bindings). Indexed by the exact menu labels.
proc keymap_refresh_menus {} {
	.m.file entryconfigure "New"          -accelerator [key_accel new]
	.m.file entryconfigure "Open…"        -accelerator [key_accel open]
	.m.file entryconfigure "Open Folder…" -accelerator [key_accel open-folder]
	.m.file entryconfigure "Save"         -accelerator [key_accel save]
	.m.file entryconfigure "Save As…"     -accelerator [key_accel save-as]
	.m.file entryconfigure "Close Tab"    -accelerator [key_accel close-tab]
	.m.file entryconfigure "Quit"         -accelerator [key_accel quit]
	.m.edit entryconfigure "Undo"          -accelerator [key_accel undo]
	.m.edit entryconfigure "Redo"          -accelerator [key_accel redo]
	.m.find entryconfigure "Find…"         -accelerator [key_accel find]
	.m.find entryconfigure "Replace…"      -accelerator [key_accel replace]
	.m.find entryconfigure "Find Next"     -accelerator [key_accel find-next]
	.m.find entryconfigure "Find Previous" -accelerator [key_accel find-prev]
	.m.find entryconfigure "Search…"       -accelerator [key_accel search]
	.m.view entryconfigure "Files"        -accelerator [key_accel show-files]
	.m.view entryconfigure "Git"          -accelerator [key_accel show-git]
	.m.view entryconfigure "Agent"        -accelerator [key_accel toggle-chat]
	.m.view entryconfigure "Wrap Lines"   -accelerator [key_accel toggle-wrap]
	.m.view.layout entryconfigure "Split Editor" -accelerator [key_accel split-editor]
	.m.view.layout entryconfigure "Move Tab to Other Group" -accelerator [key_accel move-tab-other]
	.m.settings entryconfigure "Preferences…" -accelerator [key_accel preferences]
	.m.help entryconfigure "Contents…"        -accelerator [key_accel help]
}

# One entry point after the keymap changes at runtime: re-read keys.json, then push the
# new bindings and menu labels to the live UI. The shortcuts editor calls this after it
# saves; everything routes through keymap_resolve so file and UI never diverge.
proc keymap_apply_live {} {
	keymap_resolve
	keymap_rebind_all
	keymap_refresh_menus
}

# ---- Pure helpers for the shortcuts editor (unit-tested; no widgets) --------------

# Turn a key event (keysym + state bitmask, from %K/%s) into a chord string, or "" if it
# isn't a usable shortcut: a bare modifier press, or a bare printable key with no modifier
# (binding a lone letter would hijack typing — a named key like F5/Delete is allowed).
# Modifiers are emitted Control/Alt/Shift; a letter is lower-cased with Shift kept explicit.
proc event_to_chord {keysym state} {
	if {[string match *_L $keysym] || [string match *_R $keysym] \
		|| $keysym in {Caps_Lock Num_Lock Shift Control Alt Meta ISO_Level3_Shift}} { return "" }
	set mods {}
	if {$state & 0x4} { lappend mods Control }
	if {$state & 0x8} { lappend mods Alt }      ;# Mod1
	if {$state & 0x1} { lappend mods Shift }
	set key $keysym
	if {[string length $key] == 1 && [string is alpha $key]} { set key [string tolower $key] }
	if {[llength $mods] == 0 && [string length $key] == 1} { return "" }  ;# bare printable: refuse
	return [join [concat $mods [list $key]] -]
}

# Which OTHER command in `chords` (a command -> chord dict) already uses `chord`, or "" if
# none — the shortcuts editor's live conflict check. An empty chord never conflicts.
proc keys_conflict {chords cmd chord} {
	if {$chord eq ""} { return "" }
	dict for {c ch} $chords {
		if {$c ne $cmd && $ch eq $chord} { return $c }
	}
	return ""
}

# The minimal overrides to persist from a command -> chord dict: keep only commands whose
# chord differs from its default (including "" for one the user unbound). Commands left at
# their default are omitted, so keys.json stays a small diff, not a full copy.
proc keymap_overrides {chords} {
	set out {}
	dict for {cmd chord} $chords {
		set dflt [lindex [dict get $::keymap_default $cmd] 0]
		if {$chord ne $dflt} { dict set out $cmd $chord }
	}
	return $out
}

# Write the overrides dict to keys.json (deleting it when empty, so a full reset removes
# the file). Returns 1 on success. Mirrors prefs_save: plain JSON, best-effort.
proc keys_save {overrides} {
	set path [keys_path]
	if {$path eq ""} { return 0 }
	if {[dict size $overrides] == 0} { catch {file delete $path} ; return 1 }
	if {[catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f [rio::wire::obj $overrides] ; close $f
	}]} { return 0 }
	return 1
}

# ---------------------------------------------------------------------------
# Preferences window (AGENTS.md D58). One place to find every stateful setting as the
# count grows, so the top-level menus don't keep accreting checkbuttons. It does NOT own
# any state: each control drives the SAME global the menu entry binds (::wrap_lines,
# ::tab_layout, …) and calls the SAME applier, which persists via prefs_save. So it is
# live-apply (no Save/Cancel — a toggle takes effect at once, like every view toggle in
# rio), and the twin menu entry updates with it for free (Tk repaints a checkbutton the
# instant its -variable changes), and vice-versa. Commands (Zoom, Split, Compare) are
# actions, not preferences, and stay menu-only; keyboard shortcuts keep their own
# recorder (its working-copy model suits a half-typed chord), reached from a button here.
# ---------------------------------------------------------------------------
# Themed control factories: the menu-matching palette (D31 named fonts, theme_colors) in
# one place so each control is a single line. `args` passes extras through (e.g. the
# Multi-Line Tabs checkbutton's -onvalue/-offvalue).
proc prefs_check {w label var cmd args} {
	set c $::theme_colors
	checkbutton $w -text $label -variable $var -command $cmd -font RioUIFont -anchor w \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg] \
		-selectcolor [dict get $c ui.bg] {*}$args
	return $w
}
proc prefs_radio {w label var val cmd} {
	set c $::theme_colors
	radiobutton $w -text $label -variable $var -value $val -command $cmd -font RioUIFont -anchor w \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg] \
		-selectcolor [dict get $c ui.bg]
	return $w
}
proc prefs_label {w text} {
	set c $::theme_colors
	label $w -text $text -anchor w -justify left -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	return $w
}
proc prefs_button {w text cmd} { button $w -text $text -font RioUIFont -command $cmd ; return $w }
# A muted, greyed-out hint line (gutter.fg) — orientation text, styled apart from the
# interactive controls so it never reads as one (D68). Wraps within the pane width.
proc prefs_hint {w text} {
	set c $::theme_colors
	label $w -text $text -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	return $w
}

# View category: the display cluster (the same controls as the View menu), the dock
# side, the theme button (onto the shared picker, which enumerates from the core so
# installed themes appear), and the Font… dialog button.
proc prefs_fill_view {f} {
	set r 0
	grid [prefs_check $f.wrap    "Wrap Lines"           ::wrap_lines  apply_wrap]        -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.wrapind "Indent Wrapped Lines" ::wrap_indent apply_wrap_indent] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.lnum    "Line Numbers"         ::line_numbers apply_line_numbers] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.curln   "Highlight Current Line" ::highlight_current_line apply_curline] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.relnum  "Relative Line Numbers"  ::relative_line_numbers apply_relnum] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.mtab    "Multi-Line Tabs"      ::tab_layout  tab_layout_apply \
		-onvalue multi -offvalue scroll] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.hidden  "Show Hidden Files"    ::show_hidden apply_show_hidden] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_label $f.dockl "Dock side"] -row [incr r] -column 0 -sticky w -pady {8 0}
	grid [prefs_radio $f.dl "Left"  ::dock_side left  {dock_set_side left}]  -row [incr r] -column 0 -sticky w -padx {12 0}
	grid [prefs_radio $f.dr "Right" ::dock_side right {dock_set_side right}] -row [incr r] -column 0 -sticky w -padx {12 0}
	# A button carrying the current theme's pretty label (::theme_choice_label, kept live
	# by a trace) and opening the shared picker — the same door as View ▸ Theme…, so the
	# two stay in sync for free and do_theme applies + persists the pick. It was a
	# dropdown until D92; a menu can't bound its own height, and the theme list grows with
	# every installed theme (D39). Keeping the *value* on the button (not a bare "Theme…")
	# is what the dropdown was for: Preferences is the config home, so it shows what is set.
	grid [prefs_label $f.thl "Theme"] -row [incr r] -column 0 -sticky w -pady {8 0}
	grid [prefs_button $f.theme "" theme_pick_dialog] -row [incr r] -column 0 -sticky w -padx {12 0}
	$f.theme configure -textvariable ::theme_choice_label -anchor w
	grid [prefs_label $f.fontl "Font"] -row [incr r] -column 0 -sticky w -pady {8 0}
	grid [prefs_button $f.font "Font…" editor_font_dialog] -row [incr r] -column 0 -sticky w -padx {12 0} -pady {0 2}
}

# Editor category: the editing mode (enumerated from the registry like modes_menu_fill,
# so a mode extension shows up), and column editing.
proc prefs_fill_editor {f} {
	set r 0
	grid [prefs_label $f.eml "Editing Mode"] -row [incr r] -column 0 -sticky w
	if {[info commands rio::modes::names] ne ""} {
		set i 0
		foreach name [rio::modes::names] {
			grid [prefs_radio $f.em[incr i] [rio::modes::label $name] ::edit_mode $name apply_editmode] \
				-row [incr r] -column 0 -sticky w -padx {12 0}
		}
	}
	grid [prefs_check $f.col "Column Editing (Ctrl+Shift+Drag)" ::col_on apply_column_edit] \
		-row [incr r] -column 0 -sticky w -pady {8 1}
}

# Agent category: the provider picker (enumerated from the core like the theme
# radios, so an installed provider appears), a muted hint when only the echo stub is
# present, the two agent-edit toggles, an API-key button per keyed provider, and the
# door to the agent's instructions (Agent Prompts…, D70/D79).
proc prefs_fill_agent {f} {
	agent_providers_refresh
	set r 0
	grid [prefs_label $f.pl "Agent"] -row [incr r] -column 0 -sticky w
	set i 0 ; set have_real 0
	foreach p $::agent_providers {
		if {[dict get $p name] ne "echo"} { set have_real 1 }
		grid [prefs_radio $f.p[incr i] [provider_radio_label $p] \
			::agent_provider [dict get $p name] apply_provider] \
			-row [incr r] -column 0 -sticky w -padx {12 0}
	}
	# Echo is only a stub: with no real provider installed the picker is a single
	# offline option, so point the way to one — Extensions… is a button in this very
	# window. Guidance, not a control, so it's muted (prefs_hint / D68); once a real
	# provider is installed the pane is self-explanatory and the hint drops away.
	if {!$have_real} {
		grid [prefs_hint $f.hint "Echo is a built-in stub. Install Claude or an OpenAI-compatible provider from Extensions… to use a real model."] \
			-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	}
	# The mode: three exclusive states over the core's two flags (D102), the same
	# ::agent_mode_ui and the same writer the chat header's control and the Settings
	# cascade use — three doors, one answer.
	grid [prefs_label $f.ml "Mode"] -row [incr r] -column 0 -sticky w -pady {8 1}
	foreach {v lbl} {plan "Plan — read and plan, change nothing until you approve a plan" \
			review "Review each edit" auto "Auto-accept edits"} {
		grid [prefs_radio $f.m$v $lbl ::agent_mode_ui $v agent_mode_set] \
			-row [incr r] -column 0 -sticky w -padx {12 0} -pady 1
	}
	grid [prefs_check $f.cc "Compare complex edits" ::agent_compare_complex {}] -row [incr r] -column 0 -sticky w -pady 1
	# The editor's one AI entry (D113). On by default, yet only ever seen with a real
	# provider selected — so someone who never installs one never meets it, and someone
	# who does can still keep their context menu to plain editing.
	grid [prefs_check $f.selmenu "Show “Change with Agent…” in the editor's context menu" \
		::agent_selection_menu prefs_save] -row [incr r] -column 0 -sticky w -pady {8 1}
	grid [prefs_hint $f.selhint "Shown only while a provider other than Echo is selected. It asks the agent to change the selected text and nothing else."] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	set i 0
	foreach p $::agent_providers {
		if {![dict get $p keyed]} continue
		grid [prefs_button $f.key[incr i] "[dict get $p label] API Key…" \
			[list provider_key_dialog [dict get $p name]]] \
			-row [incr r] -column 0 -sticky w -pady {4 2}
	}
	# The agent's instructions (system / project / per-provider prompts, D70/D79) are
	# the third leg of its config alongside provider + key. This pane is their ONLY home
	# now — the Settings menu keeps just the provider picker and the two quick toggles,
	# so all of the agent's heavier configuration gathers here (jka, 2026-09-09).
	grid [prefs_button $f.prompts "Agent Prompts…" agent_prompts_dialog] \
		-row [incr r] -column 0 -sticky w -pady {8 2}
	# The command allow-list (D84) — the standing-approval companion to the gate. Its
	# only door, beside the prompts button just above.
	grid [prefs_button $f.allow "Allowed commands…" agent_allow_dialog] \
		-row [incr r] -column 0 -sticky w -pady {2 2}
}

# Extensions category (D107): where the repositories are configured and where the
# one durable decision about them lives — whether rio looks for new versions when
# it starts. D85 puts it here rather than in the Extensions window: that window is
# a browsing surface, this is the config home. The two buttons are doors to the
# surfaces themselves, so the pane is not a dead end.
proc prefs_fill_extensions {f} {
	set r 0
	grid [prefs_check $f.chk "Check for extension updates at start-up" \
		::ext_check_updates ext_check_pref_save] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_hint $f.hint "Off by default: rio asks its core to fetch from your repositories only when you tell it to. Updates are never installed automatically, and an update comes from the repository an extension was installed from — a same-named extension elsewhere is a different thing until you say otherwise."] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	grid [prefs_check $f.unver "Use repositories rio can't check" \
		::repo_allow_unverified ext_check_pref_save] -row [incr r] -column 0 -sticky w -pady {6 1}
	grid [prefs_hint $f.unverhint "A repository can publish a signing key, and rio checks it by running ssh-keygen on the core's host (D118). Where that isn't installed, a repository whose key rio trusts is refused rather than used unchecked. Turn this on to use it anyway: it then lists and installs marked \"unverified\", never \"signed\". A signature that fails, a key that changed, or a file that doesn't match is refused either way."] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	grid [prefs_button $f.ext "Extensions…" extensions_window] \
		-row [incr r] -column 0 -sticky w -pady {8 2}
	grid [prefs_button $f.repos "Repositories…" extw_sources_dialog] \
		-row [incr r] -column 0 -sticky w -pady {2 2}
	grid [prefs_button $f.keys "Repository signing keys…" repo_keys_dialog] \
		-row [incr r] -column 0 -sticky w -pady {2 2}
}

# Network category (D114): how the core's https connections are verified — for the agent
# and extension repositories alike, so neither of their panes owns it. The one security
# trade-off (D110), off by default; it lives here, not in Settings: a fast switch it is
# not. And the certificates accepted one by one (D111), which also apply to every https
# connection the core makes.
proc prefs_fill_network {f} {
	adopt_tls_settings
	set r 0
	grid [prefs_check $f.tls "Allow https without host-name checks (tcltls older than 1.8)" \
		::tls_unchecked tls_unchecked_set] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_hint $f.hint [tls_unchecked_hint]] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	grid [prefs_button $f.certs "Accepted certificates…" certs_dialog] \
		-row [incr r] -column 0 -sticky w -pady {8 2}
}

# Keyboard category: app shortcuts keep their own recorder (D23) — reached, not
# reimplemented, from here.
proc prefs_fill_keyboard {f} {
	grid [prefs_label $f.blurb "App shortcuts are edited in their own recorder — click a\ncommand, then press the keys. They always win over the editing mode's keys."] \
		-row 0 -column 0 -sticky w -pady {0 8}
	grid [prefs_button $f.edit "Edit Keyboard Shortcuts…" keybindings_dialog] -row 1 -column 0 -sticky w
}

# Raise the body frame for the selected category.
proc prefs_show_cat {w} {
	set sel [$w.cats curselection]
	if {$sel eq ""} return
	raise $w.body.[string tolower [$w.cats get $sel]]
}

proc preferences_window {} {
	set w .prefs
	if {[winfo exists $w]} { wm deiconify $w ; raise $w ; focus $w.cats ; return }
	toplevel $w
	wm title $w "Preferences"
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	# Left: the category list. Right: one body frame per category, stacked at the same
	# cell and raised on selection (a tab-like switch without a notebook widget).
	listbox $w.cats -width 12 -height 8 -exportselection 0 -font RioUIFont \
		-activestyle none -highlightthickness 0 -borderwidth 1 -relief solid \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] -selectforeground [dict get $c ui.bg]
	foreach cat {View Editor Agent Extensions Network Keyboard} { $w.cats insert end $cat }
	bind $w.cats <<ListboxSelect>> [list prefs_show_cat $w]

	frame $w.body -background [dict get $c ui.bg]
	foreach cat {view editor agent extensions network keyboard} {
		frame $w.body.$cat -background [dict get $c ui.bg]
		grid $w.body.$cat -row 0 -column 0 -sticky nsew
	}
	prefs_fill_view       $w.body.view
	prefs_fill_editor     $w.body.editor
	prefs_fill_agent      $w.body.agent
	prefs_fill_extensions $w.body.extensions
	prefs_fill_network    $w.body.network
	prefs_fill_keyboard   $w.body.keyboard

	# Extensions… mirrors the Settings menu, where it sits right under Preferences…
	# (D67): from here you jump to the installer for the providers/modes/themes/syntax
	# the categories above pick from. Left of Close; a spacer column keeps them apart.
	frame $w.btns -background [dict get $c ui.bg]
	grid [prefs_button $w.btns.ext   "Extensions…" [list extensions_window]] -row 0 -column 0 -sticky w
	grid [prefs_button $w.btns.close "Close"       [list destroy $w]]         -row 0 -column 2 -sticky e
	grid columnconfigure $w.btns 1 -weight 1

	grid $w.cats -row 0 -column 0 -sticky ns   -padx {8 4} -pady 8
	grid $w.body -row 0 -column 1 -sticky nsew -padx {4 8} -pady 8
	grid $w.btns -row 1 -column 0 -columnspan 2 -sticky we -padx 8 -pady {0 8}
	grid columnconfigure $w 1 -weight 1
	grid rowconfigure    $w 0 -weight 1

	$w.cats selection set 0
	prefs_show_cat $w
	bind $w <Escape> [list destroy $w]
	focus $w.cats
}

# ---------------------------------------------------------------------------
# Keyboard-shortcuts editor (AGENTS.md D23). A modal listing every command with its
# current chord; the user re-records (press-to-capture, like a modern IDE), clears, or
# resets. Editing happens in a working copy ::keys_work (command -> chord); Cancel
# discards it, Save writes keys.json (overrides only) and applies live via
# keymap_apply_live — no restart — so file and UI never diverge.
# ---------------------------------------------------------------------------
proc keys_refresh_buttons {} {
	dict for {cmd chord} $::keys_work {
		if {![winfo exists .keys.body.k$cmd]} continue
		set lbl [chord_label $chord]
		.keys.body.k$cmd configure -text [expr {$lbl eq "" ? "(unbound)" : $lbl}]
	}
}
proc keys_status {msg} { catch {.keys.status configure -text $msg} }

# Begin recording a chord for `cmd`. Any capture in progress is cancelled first; focus
# moves to the toplevel so keypresses land on our <KeyPress> handler, not a button.
proc keys_capture {cmd} {
	if {$::keys_capturing ne ""} { keys_capture_cancel }
	set ::keys_capturing $cmd
	.keys.body.k$cmd configure -text "Press keys…"
	keys_status "Recording “[key_label $cmd]” — press a shortcut, or Esc to cancel."
	focus .keys
}
proc keys_capture_cancel {} {
	if {$::keys_capturing eq ""} return
	set ::keys_capturing ""
	keys_refresh_buttons
	keys_status ""
}

# A key arrived while recording: ignore unusable keys (bare modifier / lone printable) and
# conflicts, keep recording; otherwise set the chord and stop.
proc keys_on_key {keysym state} {
	if {$::keys_capturing eq ""} return
	set chord [event_to_chord $keysym $state]
	if {$chord eq ""} {
		keys_status "That key can’t be a shortcut on its own — add Ctrl / Alt / Shift."
		return
	}
	set cmd $::keys_capturing
	set other [keys_conflict $::keys_work $cmd $chord]
	if {$other ne ""} {
		keys_status "[chord_label $chord] is already “[key_label $other]” — clear that first."
		return
	}
	dict set ::keys_work $cmd $chord
	set ::keys_capturing ""
	keys_refresh_buttons
	keys_status "Set “[key_label $cmd]” to [chord_label $chord]. Save to apply."
}
proc keys_clear {cmd} { dict set ::keys_work $cmd "" ; keys_refresh_buttons ; keys_status "" }
# Restore one command to its shipped default chord (the per-row counterpart of Reset all).
# We note if the restored chord now duplicates another command's, but still apply it — it's
# a deliberate "put it back" and the user can sort out the collision.
proc keys_default {cmd} {
	set chord [lindex [dict get $::keymap_default $cmd] 0]
	dict set ::keys_work $cmd $chord
	keys_refresh_buttons
	set other [keys_conflict $::keys_work $cmd $chord]
	if {$other ne ""} {
		keys_status "Restored “[key_label $cmd]” to [chord_label $chord] — now also on “[key_label $other]”."
	} else {
		keys_status "Restored “[key_label $cmd]” to [chord_label $chord]."
	}
}
proc keys_reset_all {} {
	set ::keys_work {}
	dict for {cmd spec} $::keymap_default { dict set ::keys_work $cmd [lindex $spec 0] }
	keys_refresh_buttons
	keys_status "Reset to defaults — Save to apply."
}
proc keys_dialog_save {} {
	keys_save [keymap_overrides $::keys_work]
	keymap_apply_live         ;# re-read the file and push new bindings + menu labels live
	destroy .keys
}

proc keybindings_dialog {} {
	set w .keys
	destroy $w
	toplevel $w
	wm title $w "Keyboard Shortcuts"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	set ::keys_capturing ""
	set ::keys_work {}
	dict for {cmd spec} $::keymap { dict set ::keys_work $cmd [lindex $spec 0] }

	label $w.hint -anchor w -font RioUIFont -justify left \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-text "Click a shortcut, then press the keys you want. Clear unbinds; Default restores the original.\nThese app shortcuts always win over the editing mode's keys (Settings ▸ Editing Mode)."
	grid $w.hint -row 0 -column 0 -sticky we -padx 8 -pady {8 4}

	frame $w.body -background [dict get $c ui.bg]
	set r 0
	dict for {cmd spec} $::keymap_default {
		label $w.body.l$cmd -text [key_label $cmd] -anchor w -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		button $w.body.k$cmd -width 20 -font RioUIFont -command [list keys_capture $cmd]
		button $w.body.c$cmd -text "Clear"   -font RioUIFont -command [list keys_clear $cmd]
		button $w.body.d$cmd -text "Default" -font RioUIFont -command [list keys_default $cmd]
		grid $w.body.l$cmd -row $r -column 0 -sticky w  -padx {2 12} -pady 1
		grid $w.body.k$cmd -row $r -column 1 -sticky we -padx 2      -pady 1
		grid $w.body.c$cmd -row $r -column 2 -sticky w  -padx {2 2}  -pady 1
		grid $w.body.d$cmd -row $r -column 3 -sticky w  -padx {2 2}  -pady 1
		incr r
	}
	grid $w.body -row 1 -column 0 -sticky nwe -padx 8

	label $w.status -anchor w -font RioUIFont -text "" \
		-background [dict get $c ui.bg] -foreground [dict get $c accent]
	grid $w.status -row 2 -column 0 -sticky we -padx 8 -pady {4 2}

	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.reset  -text "Reset all to defaults" -font RioUIFont -command keys_reset_all
	button $w.btns.cancel -text "Cancel" -font RioUIFont -command {destroy .keys}
	button $w.btns.save   -text "Save"   -font RioUIFont -command keys_dialog_save
	pack $w.btns.reset -side left
	pack $w.btns.save $w.btns.cancel -side right -padx 3
	grid $w.btns -row 3 -column 0 -sticky we -padx 5 -pady {2 8}

	# Capture keys only while recording; otherwise let them drive normal focus/buttons.
	bind $w <KeyPress> {if {$::keys_capturing ne ""} { keys_on_key %K %s ; break }}
	bind $w <Escape>   {if {$::keys_capturing ne ""} { keys_capture_cancel } else { destroy .keys }}
	keys_refresh_buttons
	catch {grab $w}
	focus $w
	tkwait window $w
}

# Build editor group `g`: its frame (.eg<g>) with a tab strip on top and the text
# widget + scrollbars below, the renamed real command, the proxy, and the key/focus
# bindings. Registers the group in ::grp. The literal font is replaced by
# RioEditorFont in the next apply_theme. Each group owns its OWN tab strip (D33) — a
# tab lives in exactly one group — so the strip is gridded inside the group frame,
# spanning the text + scrollbar columns, with refresh_tabs filling it per group.
proc make_editor_group {g} {
	set f .eg$g
	frame $f
	frame $f.tabs -background "#bbbbbb"
	text $f.t -wrap none -undo 0 -font {monospace 12} -width 80 -height 28 \
		-background white -foreground black -insertbackground black \
		-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
		-yscrollcommand [list edscroll $g] -xscrollcommand [list gridscroll $f.hsb]
	# The line-number gutter (D49): a thin, unfocusable canvas in column 0 that
	# gutter_redraw paints from the text widget's dlineinfo. Its wheel forwards to
	# the text so a scroll begun over the numbers still moves the buffer.
	canvas $f.gutter -width 1 -highlightthickness 0 -borderwidth 0 -takefocus 0
	bind $f.gutter <MouseWheel> "$f.t yview scroll \[expr {%D > 0 ? -1 : 1}\] units"
	bind $f.gutter <Button-4>   [list $f.t yview scroll -1 units]
	bind $f.gutter <Button-5>   [list $f.t yview scroll  1 units]
	bind $f.gutter <Button-1>   [list gutter_press  $g %y]  ;# click a number selects its line (D61)
	bind $f.gutter <B1-Motion>  [list gutter_motion $g %y]  ;# drag to extend, line-by-line
	editor_zoom_bindings $f.gutter   ;# Ctrl+wheel over the numbers zooms too (D56)
	# Resize / re-wrap / font zoom → repaint the gutter, and re-check the highlight
	# window (D126): this is also where a freshly split group first learns its height.
	bind $f.t <Configure> [list editor_reconfigured $g]
	scrollbar $f.vsb -orient vertical   -command [list $f.t yview]
	scrollbar $f.hsb -orient horizontal -command [list $f.t xview]
	grid $f.tabs   -row 0 -column 0 -columnspan 3 -sticky ew
	bind $f.tabs <Configure> [list tabstrip_on_configure $g]  ;# re-flow tabs on resize (D57)
	grid $f.gutter -row 1 -column 0 -sticky ns
	grid $f.t      -row 1 -column 1 -sticky nsew
	grid $f.vsb    -row 1 -column 2 -sticky ns
	grid $f.hsb    -row 2 -column 1 -sticky ew
	grid rowconfigure    $f 1 -weight 1
	grid columnconfigure $f 1 -weight 1
	rename $f.t ::real$g
	dict set ::grp $g [dict merge [new_group_state] \
		[dict create w ::real$g path $f.t frame $f tabs $f.tabs]]
	proc $f.t {args} "editor_proxy $g {*}\$args"
	editor_bindings $f.t
	editor_zoom_bindings $f.t   ;# Ctrl+scroll / Ctrl +/- / Ctrl+0 zoom the font (D56)
	# Slot the editing-mode tag between the widget (app chords) and the Text class
	# (Tk defaults) — the D38 precedence order. The tag is SHARED, so whatever mode
	# is attached covers this group with no per-widget rebinding.
	bindtags $f.t [linsert [bindtags $f.t] 1 RioMode]
	bind $f.t <Button-1> [list focus_group $g]   ;# clicking a group focuses it
	# Right-click opens the editor's context menu (D108); the Menu key and Shift+F10
	# open the same one at the caret. Bound on the WIDGET, so they sit ahead of the
	# RioMode tag in the D38 precedence order — the app's menu wins over anything an
	# editing mode might put on Button-3 — and `break` stops the rest of the chain.
	bind $f.t <Button-3>   "editor_context_menu $g %x %y %X %Y ; break"
	bind $f.t <Key-Menu>   "editor_context_key $g ; break"
	bind $f.t <Shift-F10>  "editor_context_key $g ; break"
	# Keep the status bar's Ln/Col segment live: any key-up or click-release may have
	# moved the insert mark (arrows, typing, click-to-place). Cheap; edits already
	# refresh, this covers pure navigation. Guarded on focus so a stray event is a no-op.
	bind $f.t <KeyRelease>      [list cursor_moved $g]
	bind $f.t <ButtonRelease-1> [list cursor_moved $g]
	# OS file-drop onto the editor text opens the file (D86). tkdnd doesn't bubble a drop
	# to ancestors, so each group's text widget registers as its own target (the toplevel,
	# below, covers the docks and tab strips); every drop routes to the one dnd_open_files.
	# Optional extension + local core only — a no-op in a headless run (no tkdnd there).
	if {$::have_tkdnd && !$::core_remote} {
		tkdnd::drop_target register $f.t DND_Files
		bind $f.t <<Drop>> {dnd_open_files %D}
	}
	return $g
}

# Make group `g` the focused one (::cur mirrors its active buffer). Tk moves keyboard
# focus on a click itself; this just repoints our state and repaints the chrome.
# A cursor-moving event fired in group g; repaint the status only when g is the
# focused group (a background group never owns the shown Ln/Col).
proc cursor_moved {g} {
	curline_update $g   ;# per-group: band follows this group's own caret, focused or not
	if {$g eq $::focus} refresh_status
}
proc focus_group {g} {
	if {$g eq $::focus} return
	set ::focus $g
	set ::cur [gcur $g]
	refresh_all
}

# Resolve the keymap (defaults + the user's keys.json) before any binding or menu is
# built, so both the editor shortcuts and the menu accelerators read the same table.
keymap_resolve
set ::keymap_live_chords [keymap_chords] ;# what the first group's editor_bindings will bind

# Create the first editor group; the split adds a second (phase 3).
make_editor_group 0
set ::groups {0}
set ::focus 0
relayout_groups

# The compare / diff view (AGENTS.md D28): two read-only text panes side by side
# with a single shared vertical scrollbar, packed in the center INSTEAD of .ed
# while comparing (apply_layout). Built here with bootstrap colours; apply_theme
# recolours them and configures the del/add/filler row tags. cmp_fill renders the
# core diff.lines alignment into the panes.
frame .cmp
frame .cmp.l ; frame .cmp.r
label .cmp.l.hdr -anchor w -font {monospace 9} -padx 4 -pady 2 -background "#dddddd" -foreground black
label .cmp.r.hdr -anchor w -font {monospace 9} -padx 4 -pady 2 -background "#dddddd" -foreground black
text .cmp.l.t -wrap none -state disabled -font {monospace 12} -width 40 -height 28 \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black -yscrollcommand {cmp_yscroll l}
text .cmp.r.t -wrap none -state disabled -font {monospace 12} -width 40 -height 28 \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black -yscrollcommand {cmp_yscroll r}
ctx_bind_view .cmp.l.t ; ctx_bind_view .cmp.r.t   ;# Copy / Select All (D115)
scrollbar .cmp.sb -orient vertical -command cmp_yview
# A top bar with a clear way out — the Esc binding alone isn't discoverable, so the
# button names the shortcut (D27: a plain × glyph, widely covered).
frame .cmp.bar
button .cmp.bar.close -text "× Close compare (Esc)" -font {monospace 9} -command compare_close
pack .cmp.bar.close -side right -padx 2 -pady 1
pack .cmp.bar -side bottom -fill x
pack .cmp.l.hdr -side top -fill x ; pack .cmp.l.t -side left -fill both -expand 1
pack .cmp.r.hdr -side top -fill x ; pack .cmp.r.t -side left -fill both -expand 1
pack .cmp.l  -side left  -fill both -expand 1
pack .cmp.sb -side right -fill y
pack .cmp.r  -side left  -fill both -expand 1
foreach w {.cmp.l.t .cmp.r.t} {
	bind $w <MouseWheel> {cmp_yview scroll [expr {%D > 0 ? -1 : 1}] units ; break}
	bind $w <Button-4>   {cmp_yview scroll -1 units ; break}
	bind $w <Button-5>   {cmp_yview scroll 1 units ; break}
	bind $w <Escape>     {compare_close ; break}
}

# The plan view (AGENTS.md D101): one read-only pane in the center, rendering the agent's
# plan with the manual's renderer (plan_open). Same chrome as the compare view — a titled
# header and a bottom bar whose button names the Esc shortcut — because it is the same kind
# of thing: a proposal being read before it is decided. Wrapped, not scrolled sideways:
# this is prose, and help_paint's own code/table tags handle what must not reflow.
frame .plan
label .plan.hdr -anchor w -font {monospace 9} -padx 4 -pady 2 -background "#dddddd" -foreground black
text .plan.text -wrap word -state disabled -font {monospace 12} -width 80 -height 28 \
	-borderwidth 0 -highlightthickness 0 -padx 12 -pady 8 \
	-background white -foreground black -yscrollcommand {.plan.sb set}
ctx_bind_view .plan.text   ;# Copy / Select All (D115)
scrollbar .plan.sb -orient vertical -command {.plan.text yview}
frame .plan.bar
button .plan.bar.close -text "× Close plan (Esc)" -font {monospace 9} -command plan_close
pack .plan.bar.close -side right -padx 2 -pady 1
pack .plan.bar -side bottom -fill x
pack .plan.hdr -side top -fill x
pack .plan.sb -side right -fill y
pack .plan.text -side left -fill both -expand 1
bind .plan.text <Escape> {plan_close ; break}

# The agent chat pane (built here; apply_layout packs it on the right when shown,
# apply_theme colours it via the chat.* roles + RioChatFont). propagate off so a
# fixed -width holds across content, like the dock. A header (Agent + Clear) on
# top, the composer (input + Send) at the bottom, the transcript filling between.
frame .chat -width 340 -background white
pack propagate .chat 0
frame .chat.hdr -background white
label .chat.hdr.title -text "Agent" -anchor w -font {monospace 9} -padx 4 -pady 2 \
	-background white -foreground black
label .chat.hdr.clear -text "Clear" -font {monospace 9} -padx 6 -cursor hand2 \
	-background white -foreground black
# The agent's mode, where it was already being displayed — but as a control (D102). Three
# exclusive states over the core's two flags: Plan (may read, may not change), Review (each
# edit waits), Auto (edits apply as they come). The header is the pane's control strip
# already (Clear lives here, as ⟳ and the hidden toggle do in the Files and Git headers),
# and a one-word label needs the tooltip to say what it means.
menubutton .chat.hdr.mode -text "Review ▾" -font {monospace 9} -menu .chat.hdr.mode.m \
	-padx 4 -cursor hand2 -background white -foreground black
menu .chat.hdr.mode.m -tearoff 0
foreach {v lbl} {plan "Plan — read and plan, change nothing" \
		review "Review each edit" auto "Auto-accept edits"} {
	.chat.hdr.mode.m add radiobutton -label $lbl -variable ::agent_mode_ui -value $v \
		-command agent_mode_set
}
pack .chat.hdr.clear -side right
pack .chat.hdr.mode  -side right
pack .chat.hdr.title -side left -fill x -expand 1
bind .chat.hdr.clear <Button-1> chat_clear
# Composer: a few-line input + a Send button. Enter sends; Shift+Enter newlines.
text .chat.input -height 3 -wrap word -undo 1 -font {monospace 11} \
	-borderwidth 1 -relief solid -highlightthickness 0 -padx 3 -pady 2 \
	-background white -foreground black -insertbackground black
ctx_bind_input .chat.input   ;# Cut / Copy / Paste / Select All (D115)
button .chat.send -text "▶" -font {monospace 9} -command chat_send  ;# ▶ send (D27)
# …and ■ stop while a turn is working (D104): the same button, because "send" and "stop"
# are never both available — the turn is either yours to type into or the agent's to run.
tooltip .chat.send "Send this message"
# Status strip at the pane's very bottom: on the left the agent you are talking to —
# provider, model, and any option that is not at its default — as a CONTROL (D106),
# on the right the working indicator. They used to be one label, which meant the
# animation erased the answer to "which model is this?" for the whole time it mattered
# most. This is also where the eye already is: directly under the composer.
frame .chat.status -background "#eeeeee"
menubutton .chat.status.sel -anchor w -font {monospace 9} -padx 4 -pady 2 \
	-menu .chat.status.sel.m -cursor hand2 \
	-background "#eeeeee" -foreground "#444444"
menu .chat.status.sel.m -tearoff 0
label .chat.status.busy -anchor e -font {monospace 9} -padx 4 -pady 2 \
	-background "#eeeeee" -foreground "#444444"
pack .chat.status.sel  -side left
pack .chat.status.busy -side right
bind .chat.input <Return>       { chat_send ; break }
bind .chat.input <Shift-Return> { %W insert insert "\n" ; break }
# A thin draggable divider between the transcript and the composer, so the user can
# size the input box (mirror of .sash/.csash, but horizontal).
frame .chat.isash -height 5 -cursor sb_v_double_arrow -background "#bbbbbb"
bind .chat.isash <ButtonPress-1> { isash_press %Y }
bind .chat.isash <B1-Motion>     { isash_drag %Y }
bind .chat <Configure> clamp_input_height
# Approve/Reject bar for a proposed edit (packed on demand by approve_bar; D26 s5).
frame .chat.approve -background white
label .chat.approve.lbl -text "Apply this edit?" -anchor w -font {monospace 9} \
	-padx 4 -pady 2 -background white -foreground black
button .chat.approve.yes -text "Approve" -font {monospace 9} -command {agent_decide approve}
button .chat.approve.no  -text "Reject"  -font {monospace 9} -command {agent_decide reject}
button .chat.approve.cmp -text "Compare" -font {monospace 9} -command {compare_proposal $::pending_turn}
# "Plan" (plan proposals only, D101): reopen the plan the user closed while thinking. The
# plan is already in hand — nothing is fetched, it is only shown again.
button .chat.approve.plan -text "Plan" -font {monospace 9} -command plan_reopen
# A plan is approved WITH a policy for the work it starts (D102): the two items are the two
# ways to say yes, so "approve" never silently means one of them. A menubutton rather than
# two buttons because the choice is the approval, not a setting beside it.
menubutton .chat.approve.appr -text "Approve ▾" -font {monospace 9} \
	-menu .chat.approve.appr.m -relief raised -borderwidth 1 -padx 4
menu .chat.approve.appr.m -tearoff 0
.chat.approve.appr.m add command -label "Approve — review each edit" \
	-command {agent_decide_plan review}
.chat.approve.appr.m add command -label "Approve — auto-accept edits" \
	-command {agent_decide_plan auto}
# "Edit plan" (plan proposals only, D102): the plan is a file in the project, so changing it
# is rio's ordinary edit path. Packed only when the plan was filed.
button .chat.approve.edit -text "Edit plan" -font {monospace 9} -command plan_edit
# "Always allow" (command proposals only, D84): remember a trust rule so this command
# stops asking. Packed on demand by approve_bar; its menu is rebuilt per proposal by
# chat_allow_menu_populate. tearoff off — a floating menu makes no sense here.
menubutton .chat.approve.always -text "Always allow ▾" -font {monospace 9} \
	-menu .chat.approve.always.m -relief raised -borderwidth 1 -padx 4
menu .chat.approve.always.m -tearoff 0
pack .chat.approve.yes -side right
pack .chat.approve.no  -side right
pack .chat.approve.cmp -side right
pack .chat.approve.lbl -side left -fill x -expand 1
# Transcript: read-only, word-wrapped, with an auto-hiding scrollbar.
text .chat.log -wrap word -state disabled -font {monospace 11} -cursor "" \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black \
	-yscrollcommand {autoscroll .chat.sb .chat.log}
ctx_bind_view .chat.log   ;# Copy / Select All (D115)
scrollbar .chat.sb -command {.chat.log yview}
.chat.log tag configure you-label   -font {monospace 9} -background "#c3d9ff" \
	-spacing1 4 -spacing3 2
.chat.log tag configure agent-label -font {monospace 9} -background "#dddddd" \
	-spacing1 4 -spacing3 2
.chat.log tag configure error-label -font {monospace 9}
.chat.log tag configure tool        -font {monospace 9} -foreground "#888888"
.chat.log tag configure tool-error  -font {monospace 9} -foreground "#cc0000"
.chat.log tag configure diff-add    -font {monospace 9} -foreground "#118811"
.chat.log tag configure diff-del    -font {monospace 9} -foreground "#cc0000"
pack .chat.hdr    -side top    -fill x
pack .chat.status -side bottom -fill x
pack .chat.send   -side bottom -fill x
pack .chat.input  -side bottom -fill x
pack .chat.isash  -side bottom -fill x
pack .chat.log    -side left   -fill both -expand 1
# .chat.sb is packed on demand by autoscroll (hidden when the transcript fits).

# A thin draggable divider between the editor and the chat pane (mirror of .sash).
frame .csash -width 5 -cursor sb_h_double_arrow -background "#bbbbbb"
bind .csash <B1-Motion> csash_drag
# Record the chat column's final width into the right site on release (D35 b).
bind .csash <ButtonRelease-1> { rio::layout::put right size [winfo width .siteright] ; prefs_save }

# The find/replace bar (D36): built hidden; find_open packs it above the status
# bar. Row 0 finds, row 1 replaces (gridded away in find-only mode). Plain
# labelled controls and a × to close (D27) — the bar reads at a glance. Colours
# are bootstrap; apply_theme restyles (entries take the editor surface).
frame .find -borderwidth 1 -relief raised -background "#dddddd"
label .find.fl -text "Find:"    -font {monospace 9} -anchor e -background "#dddddd"
label .find.rl -text "Replace:" -font {monospace 9} -anchor e -background "#dddddd"
entry .find.e  -font {monospace 11} -width 24
entry .find.re -font {monospace 11} -width 24
ctx_bind_input .find.e ; ctx_bind_input .find.re   ;# Cut / Copy / Paste / Select All (D115)
# ↓/↑ (U+2193/U+2191) step forward/backward through matches (top-to-bottom),
# the find-widget idiom (D27); F3 / Shift+F3 are the keyboard path.
button .find.next -text "↓" -width 2 -font {monospace 9} -command find_next
button .find.prev -text "↑" -width 2 -font {monospace 9} -command find_prev
checkbutton .find.case -text "Match case" -font {monospace 9} \
	-variable ::find_case -command find_update -background "#dddddd"
checkbutton .find.word -text "Whole word" -font {monospace 9} \
	-variable ::find_word -command find_update -background "#dddddd"
checkbutton .find.regex -text "Regex" -font {monospace 9} \
	-variable ::find_regex -command find_regex_changed -background "#dddddd"
label .find.count -font {monospace 9} -anchor w -background "#dddddd"
label .find.close -text "×" -font {monospace 9} -padx 6 -cursor hand2 \
	-background "#dddddd"
button .find.rep    -text "Replace"     -font {monospace 9} -command find_replace_one
button .find.repall -text "Replace All" -font {monospace 9} -command find_replace_all
grid .find.fl     -row 0 -column 0 -sticky e  -padx {6 2} -pady 2
grid .find.e      -row 0 -column 1 -sticky ew -pady 2
grid .find.next   -row 0 -column 2 -padx 2
grid .find.prev   -row 0 -column 3 -padx 2
grid .find.case   -row 0 -column 4 -padx 4
grid .find.word   -row 0 -column 5 -padx 4
grid .find.regex  -row 0 -column 6 -padx 4
grid .find.count  -row 0 -column 7 -sticky ew -padx 4
grid .find.close  -row 0 -column 8 -sticky e  -padx {2 6}
grid .find.rl     -row 1 -column 0 -sticky e  -padx {6 2} -pady {0 2}
grid .find.re     -row 1 -column 1 -sticky ew -pady {0 2}
grid .find.rep    -row 1 -column 2 -padx 2 -pady {0 2}
grid .find.repall -row 1 -column 3 -columnspan 2 -sticky w -padx 2 -pady {0 2}
grid columnconfigure .find 1 -weight 1
grid columnconfigure .find 7 -weight 1
bind .find.close <Button-1> find_close
# Both entries: Enter steps (Shift-Enter steps back), Esc closes, F3 works too.
# In the Replace entry, Enter replaces instead — you are aiming at a replace.
foreach _w {.find.e .find.re} {
	bind $_w <Return>       {find_next ; break}
	bind $_w <Shift-Return> {find_prev ; break}
	bind $_w <Escape>       {find_close ; break}
	bind $_w <F3>           {find_next ; break}
	bind $_w <Shift-F3>     {find_prev ; break}
	# Escalate to the full Search panel (D52), carrying the bar's needle + options.
	# Bound here too because the group-widget keymap chord doesn't fire while a bar
	# entry holds focus.
	bind $_w <Control-F>    {search_from_bar ; break}
}
bind .find.re <Return> {find_replace_one ; break}
bind .find.e  <KeyRelease> find_update
unset _w

# The Search panel (D52), a D35 dock tenant. Its controls are BOTTOM-anchored like the
# Agent composer, not a top header: Search and Chat are both "compose" panes (a real
# input field + full controls), so their controls hug the bottom edge and the content
# accumulates above — the type-here/output-above idiom, and the input lands in the same
# place when switching between them. (Files/Git differ: their chrome is a *thin* caption
# — a name + a glyph button — so it sits at the top. The split is by control weight, not
# by pane; see AGENTS.md D35.) So the sunken well of results fills the top and the query
# row (needle + scope + Match case + Whole word + count + ×) is pinned to the bottom;
# Ctrl+H toggles the replace row in just ABOVE it, so the query field never moves. The
# scope option menu picks the engine (Project vs Open docs vs Current doc). Colours are
# bootstrap; apply_theme restyles (the query entry the editor surface, the well the chrome).
frame .results -borderwidth 1 -relief raised -background "#dddddd"
frame .results.hdr -background "#dddddd"
label .results.hdr.l -text "Search:" -font {monospace 9} -background "#dddddd"
entry .results.hdr.e -font {monospace 11} -width 28
ctx_bind_input .results.hdr.e   ;# (D115)
# The scope option menu drives ::search_scope; each entry re-runs the query so a
# scope change is live (like the option toggles). tk_optionMenu returns the menu.
set _scopemenu [tk_optionMenu .results.hdr.scope ::search_scope "Project" "Open docs" "Current doc"]
for {set _i 0} {$_i <= [$_scopemenu index end]} {incr _i} {
	$_scopemenu entryconfigure $_i -command search_run
}
.results.hdr.scope configure -font {monospace 9} -background "#dddddd" \
	-highlightthickness 0 -borderwidth 1 -relief raised -padx 4 -pady 0
unset _scopemenu _i
checkbutton .results.hdr.case -text "Match case" -font {monospace 9} \
	-variable ::search_case -command search_run -background "#dddddd"
checkbutton .results.hdr.word -text "Whole word" -font {monospace 9} \
	-variable ::search_word -command search_run -background "#dddddd"
checkbutton .results.hdr.regex -text "Regex" -font {monospace 9} \
	-variable ::search_regex -command search_regex_changed -background "#dddddd"
label .results.hdr.count -font {monospace 9} -anchor w -background "#dddddd"
label .results.hdr.close -text "×" -font {monospace 9} -padx 6 -cursor hand2 -background "#dddddd"
pack .results.hdr.l     -side left  -padx {6 2} -pady 2
pack .results.hdr.e     -side left  -pady 2
pack .results.hdr.scope -side left  -padx 6
pack .results.hdr.case  -side left  -padx 6
pack .results.hdr.word  -side left  -padx {0 4}
pack .results.hdr.regex -side left  -padx {0 6}
pack .results.hdr.close -side right -padx {2 6}
pack .results.hdr.count -side right -padx 6
pack .results.hdr -side bottom -fill x   ;# controls hug the bottom edge (compose pane)
# The replace row (D52 Phase B): built hidden; search_show_replace (Ctrl+H) packs it
# just ABOVE the bottom-anchored query row. Replacement entry + Replace All — the scope
# selector on the query row below decides where it lands (buffers vs disk, confirm-gated).
frame .results.rep -background "#dddddd"
label .results.rep.l -text "Replace:" -font {monospace 9} -background "#dddddd"
entry .results.rep.e -font {monospace 11} -width 28
ctx_bind_input .results.rep.e   ;# (D115)
button .results.rep.all -text "Replace All" -font {monospace 9} -command search_replace_all
pack .results.rep.l   -side left -padx {6 2} -pady {0 2}
pack .results.rep.e   -side left -pady {0 2}
pack .results.rep.all -side left -padx 6
frame .results.well -borderwidth 2 -relief sunken -background white
scrollbar .results.well.sb -command {.results.well.body yview}
text .results.well.body -width 40 -height 8 -wrap none -state disabled \
	-cursor arrow -insertwidth 0 -takefocus 1 \
	-borderwidth 0 -highlightthickness 0 -padx 2 -pady 1 \
	-background white -foreground black \
	-yscrollcommand {autoscroll .results.well.sb .results.well.body}
pack .results.well -side top -fill both -expand 1
pack .results.well.body -side left -fill both -expand 1
# .results.well.sb is packed on demand by autoscroll. A double-click / Return on a
# match row goes to it (search_activate); mere selection does nothing.
rl_init .results.well.body {} search_activate {}
bind .results.hdr.e    <Return>    {search_run ; break}
bind .results.hdr.e    <Escape>    {search_close ; break}
bind .results.hdr.e    <Control-h> {search_show_replace 1 ; break}
bind .results.rep.e    <Return>    {search_replace_all ; break}
bind .results.rep.e    <Escape>    {search_close ; break}
bind .results.rep.e    <Control-h> {search_show_replace 0 ; focus .results.hdr.e ; break}
bind .results.hdr.close <Button-1> search_close

# Register the four tool panes now that their body widgets exist (AGENTS.md D35 step
# (a)). Placement is still owned by apply_layout / show_pane — this only
# declares each pane as data and gives its refresh a name. Files and git are separate
# panels sharing today's side dock; chat is event-driven (no batch refresh hook).
rio::panel::register files  {title Files  site left   body .pfiles refresh populate_nav}
rio::panel::register git    {title Git    site left   body .pgit   refresh refresh_git}
rio::panel::register chat   {title Agent  site right  body .chat       refresh {}}
rio::panel::register search {title Search site bottom body .results    refresh search_run}

label .status -anchor w -font {monospace 9} -padx 4 -pady 1 \
	-background "#dddddd" -foreground black
pack .status -side bottom -fill x
# The dock sites and .groups are packed by apply_layout at startup (from the layout);
# each editor group's tab strip lives inside its own frame (D33), not a global top bar.
focus [gget 0 path]

# Menus use stock Tk behaviour. An earlier tweak (AGENTS.md D59, reverted) rebound the Menu
# class's <ButtonRelease> and renamed tk::MenuFirstEntry so a click wouldn't pre-highlight a
# dropdown's first entry (to match a hover-slide). It reached into Tk's menu grab/post state
# machine and caused intermittent misfires — a click invoking the first item, or a post that
# stuck — so it was removed. The cosmetic click-vs-hover first-entry difference is accepted
# as stock Tk. Don't re-add that override without a non-invasive mechanism.
menu .m ; . configure -menu .m
menu .m.file -tearoff 0
.m add cascade -label File -menu .m.file
.m.file add command -label "New"       -accelerator [key_accel new]         -command do_new
.m.file add command -label "Open…"    -accelerator [key_accel open]        -command open_dialog
.m.file add command -label "Open Folder…" -accelerator [key_accel open-folder] -command open_folder_dialog
.m.file add command -label "Save"      -accelerator [key_accel save]        -command do_save
.m.file add command -label "Save As…" -accelerator [key_accel save-as]     -command save_as_dialog
.m.file add separator
.m.file add command -label "Connect to Remote Core…" -command connect_remote_dialog
.m.file add separator
.m.file add command -label "Close Tab" -accelerator [key_accel close-tab]   -command do_close
.m.file add command -label "Quit"      -accelerator [key_accel quit]        -command do_quit
# Undo/Redo and the clipboard block (Win98 canon) come from editor_menu_items — the
# ONE table the editor's right-click menu is built from too (D108), so the two doors
# offer the same actions, on the same procs, greyed by the same rules. The commands
# work in every editing mode; -postcommand re-derives the greys for the focused group
# each time the menu is posted.
menu .m.edit -tearoff 0 -postcommand editor_menu_post
.m add cascade -label Edit -menu .m.edit
editor_menu_fill .m.edit [editor_menu_items [gget $::focus path]]
# Find / Replace / Search moved out to their own top-level Find menu (D75) — see below.
menu .m.view -tearoff 0
.m add cascade -label View -menu .m.view
# The four tool panes toggle from here — a checkmark shows whether each is currently
# on screen (site visible + its active tab); clicking shows or hides it (panel_toggle).
# Ctrl+E/G stay quick "reveal" keys (idempotent go-to); the Agent's Ctrl+Shift+A
# toggles it (a solo pane, so no ambiguity).
.m.view add checkbutton -label "Files"  -accelerator [key_accel show-files] \
	-variable ::shown_files  -command {panel_toggle files}
.m.view add checkbutton -label "Git"    -accelerator [key_accel show-git] \
	-variable ::shown_git    -command {panel_toggle git}
.m.view add checkbutton -label "Agent"  -accelerator [key_accel toggle-chat] \
	-variable ::shown_chat   -command {panel_toggle chat}
.m.view add checkbutton -label "Search" \
	-variable ::shown_search -command {panel_toggle search}
.m.view add separator
.m.view add checkbutton -label "Wrap Lines" -accelerator [key_accel toggle-wrap] \
	-variable ::wrap_lines -command apply_wrap
.m.view add checkbutton -label "Indent Wrapped Lines" \
	-variable ::wrap_indent -command apply_wrap_indent
.m.view add checkbutton -label "Line Numbers" -accelerator [key_accel toggle-linenums] \
	-variable ::line_numbers -command apply_line_numbers
.m.view add checkbutton -label "Highlight Current Line" \
	-variable ::highlight_current_line -command apply_curline
.m.view add checkbutton -label "Relative Line Numbers" \
	-variable ::relative_line_numbers -command apply_relnum
# How the editor tab strip lays out when tabs outrun the width (D57): scroll (one line
# behind ◂ ▸ arrows) or multi (wrap onto rows). A view preference, so it sits with its
# display-toggle neighbors above — a view preference, not a navigation action like the
# Switch to Tab… picker below.
.m.view add checkbutton -label "Multi-Line Tabs" \
	-onvalue multi -offvalue scroll -variable ::tab_layout -command tab_layout_apply
.m.view add checkbutton -label "Show Hidden Files" \
	-variable ::show_hidden -command apply_show_hidden
.m.view add separator
# Switch to Tab… replaces the old top-level Tabs menu (D74): the reliable way to reach a
# buffer when the window is too narrow to show its tab handle. It opens the bounded
# buffer-picker dialog (which also backs Compare ▸ Compare With Another Tab…) instead of an
# unbounded cascade that could grow screen-tall on X11 — and the dialog shows a path hint so
# two same-named tabs are told apart. A navigation command, so it heads the lower group.
.m.view add command -label "Switch to Tab…" -command switch_tab_dialog
# Less-frequent items live in topical submenus so the View menu stays short enough to fit
# on screen (D64). A Tk menu posted taller than the space below it misbehaves on X11 (it can
# unpost on a mid-list hover); we keep it in check by grouping, not by patching Tk's menu
# machinery (the D59 lesson). The display toggles above stay top-level — they are the ones
# flicked often. Each cascade below is built the same way.
menu .m.view.dock -tearoff 0
.m.view add cascade -label "Dock Side" -menu .m.view.dock
.m.view.dock add radiobutton -label "Left"  -variable ::dock_side -value left  -command {dock_set_side left}
.m.view.dock add radiobutton -label "Right" -variable ::dock_side -value right -command {dock_set_side right}
menu .m.view.zoom -tearoff 0
.m.view add cascade -label "Font & Zoom" -menu .m.view.zoom
.m.view.zoom add command -label "Font…"      -command editor_font_dialog
.m.view.zoom add separator
.m.view.zoom add command -label "Zoom In"    -accelerator "Ctrl++" -command {editor_zoom 1}
.m.view.zoom add command -label "Zoom Out"   -accelerator "Ctrl+-" -command {editor_zoom -1}
.m.view.zoom add command -label "Reset Zoom" -accelerator "Ctrl+0" -command editor_zoom_reset
menu .m.view.layout -tearoff 0
.m.view add cascade -label "Editor Layout" -menu .m.view.layout
.m.view.layout add command -label "Split Editor"          -accelerator [key_accel split-editor] -command split_editor
.m.view.layout add command -label "Unsplit Editor"        -command unsplit_editor
.m.view.layout add command -label "Move Tab to Other Group" -accelerator [key_accel move-tab-other] -command move_tab_other
# Theme… opens the bounded picker (D92), not a cascade: the theme list grows with every
# installed theme (D39), so it was the one menu here with no size bound at all.
.m.view add command -label "Theme…" -command theme_pick_dialog
# Language… (D112) picks the current buffer's highlighter by hand. Also a bounded picker:
# the language list grows with every installed syntax extension, just like themes.
.m.view add command -label "Language…" -command language_pick_dialog
# Extensions… is NOT here (it moved to Settings, D67): it is a management dialog that
# installs the providers/modes/themes the Settings choosers pick, not a pane toggle.

# Find is its own top-level menu (D75), holding the search cluster that used to sit behind a
# separator in Edit — in-buffer Find/Replace/Next/Previous plus project-wide Search…. Lifting
# the whole coherent group (not splitting it) leaves Edit as the classic clipboard/selection
# ops and gives search a discoverable home, in the spirit of Sublime's top-level Find menu.
# Named "Find", not "Search", so it doesn't collide with the View ▸ Search *pane* toggle;
# four of its five items are Find anyway. Placed left of Compare — both are editor-action
# menus to the right of View.
menu .m.find -tearoff 0
.m add cascade -label Find -menu .m.find
.m.find add command -label "Find…"         -accelerator [key_accel find]      -command {find_open 0}
.m.find add command -label "Replace…"      -accelerator [key_accel replace]   -command {find_open 1}
.m.find add command -label "Find Next"     -accelerator [key_accel find-next] -command find_next
.m.find add command -label "Find Previous" -accelerator [key_accel find-prev] -command find_prev
.m.find add separator
.m.find add command -label "Search…"       -accelerator [key_accel search]    -command search_open

# Compare is its own top-level menu, not a View ▸ Editor Layout item (D73): the diff view
# (D28) is a distinct mode that swaps the whole editor surface for two read-only panes —
# it is not one of the split/unsplit/move-tab *layouts* of the editing groups, so it read
# as misplaced there. A short top-level menu makes the mode discoverable and gives the
# agent's own "opened in compare view" flow a named home the user can reach directly.
menu .m.compare -tearoff 0
.m add cascade -label Compare -menu .m.compare
# Another Tab comes first — comparing the active buffer against another open tab is the
# more frequent case than against a file on disk (D74); both open the same modal picker /
# file chooser respectively.
.m.compare add command -label "Compare With Another Tab…" -command compare_with_tab_dialog
.m.compare add command -label "Compare With A File…" -command compare_with_file_dialog
.m.compare add separator
.m.compare add command -label "Close Compare" -accelerator Esc -command compare_close
menu .m.settings -tearoff 0
.m add cascade -label Settings -menu .m.settings
# The Preferences window (D58) gathers every stateful setting in one place; the items
# below stay here too — it is a second door, not a replacement.
.m.settings add command -label "Preferences…" -accelerator [key_accel preferences] \
	-command preferences_window
# Extensions… sits right under Preferences… (D67): both open a management window for
# customizing rio — Preferences the built-in settings, Extensions the installer for
# the providers/modes/themes/syntax the choosers below pick from. The Preferences
# window mirrors this with its own Extensions… button.
.m.settings add command -label "Extensions…" -command extensions_window
.m.settings add separator
# The agent provider is a cascade filled from the core (providers_menu_fill, mirroring
# View ▸ Theme): the list scales as providers are added (D39/milestone B), and the
# collapsed menu stays short. Choosing which model is live is a quick runtime switch,
# so it earns a menu home; the provider's heavier configuration — its API key, its
# prompts, its command allow-list — lives only in the Preferences Agent pane (jka,
# 2026-09-09), keeping this menu to fast toggles.
menu .m.settings.provider -tearoff 0
.m.settings add cascade -label "Agent Provider" -menu .m.settings.provider
# The agent's mode and compare-complex are the agent settings flipped often enough
# mid-session to keep here alongside the provider (their twins live in Preferences too).
# The mode leads: it decides whether the agent may change anything at all, and it is chosen
# at the START of a piece of work, which is when this menu is open (D101). Three exclusive
# states, not two checkboxes, so the menu cannot show a combination the pane cannot (D102);
# same variable and same writer as the chat header's control.
menu .m.settings.agentmode -tearoff 0
foreach {v lbl} {plan "Plan — read and plan, change nothing" \
		review "Review each edit" auto "Auto-accept edits"} {
	.m.settings.agentmode add radiobutton -label $lbl -variable ::agent_mode_ui -value $v \
		-command agent_mode_set
}
.m.settings add cascade -label "Agent Mode" -menu .m.settings.agentmode
.m.settings add checkbutton -label "Agent: Compare complex edits" \
	-variable ::agent_compare_complex
.m.settings add separator
# Keyboard behaviour clusters here: the editing mode decides what keys do inside
# the text area (D38), the shortcuts editor remaps the app chords (D23).
menu .m.settings.editmode -tearoff 0
.m.settings add cascade -label "Editing Mode" -menu .m.settings.editmode
.m.settings add checkbutton -label "Column Editing (Ctrl+Shift+Drag)" \
	-variable ::col_on -command apply_column_edit
.m.settings add command -label "Keyboard Shortcuts…" -command keybindings_dialog
# Help is the last (rightmost) menu, the Windows/VSCode convention (D76). Contents… opens the
# manual in rio itself (D99) and About names the version and the build, so a tester can say
# which rio they're running (D123 — the release line, and the exact commit under it).
# Contents first, About last — the Windows order.
menu .m.help -tearoff 0
.m add cascade -label Help -menu .m.help
.m.help add command -label "Contents…" -command help_window
.m.help add separator
.m.help add command -label "About rio" -command about_dialog

# The editor keyboard shortcuts and the edit-proxy are installed per group by
# make_editor_group (editor_bindings + editor_proxy). Only the window-manager close
# needs binding here.
wm protocol . WM_DELETE_WINDOW do_quit

# The window / taskbar icon (AGENTS.md D117). Without one the window manager and the
# taskbar each fall back to their OWN default, so rio showed two different generic
# icons in the two places.
#
# A RASTER asset, deliberately outside D27's monochrome-Unicode rule: that rule governs
# glyphs drawn INSIDE rio's own UI, where a font is the right tool. `_NET_WM_ICON` takes
# pixels, and a glyph would have to be rendered to a pixmap to get here anyway.
#
# SOFT, like tkdnd (D86): missing or unreadable files leave rio running exactly as
# before, with the window manager's default. The icons are only ever read, never
# required — so a checkout with the directory removed still starts.
#
# Tk 8.6 reads PNG natively, so this costs no dependency. Several sizes are handed over
# at once and the WM picks the one it wants (16 for the title bar, 32/48 for alt-tab,
# larger for the window list). `-default` also covers every toplevel made LATER, so the
# dialogs and the help window inherit it without each repeating this.
#
# The sizes are a VARIABLE, not a literal in the loop, so the guard in smoke.tcl can ask
# what was asked for rather than reading this proc's source text (AGENTS §7: assert
# against behaviour). `icons/make-icons.sh` cuts exactly this set.
set ::icon_sizes {16 24 32 48 64 128 256}
proc apply_window_icon {} {
	set dir [file join $::rio_dir icons]
	set imgs {}
	foreach n $::icon_sizes {
		set f [file join $dir rio-$n.png]
		if {![file exists $f]} continue
		if {[catch {image create photo ::rio_icon_$n -file $f}]} continue
		lappend imgs ::rio_icon_$n
	}
	if {[llength $imgs]} { catch {wm iconphoto . -default {*}$imgs} }
	# Windows only: `wm iconphoto` works there, but a real .ico is what the taskbar and
	# alt-tab render best. Harmless to attempt and caught if the file isn't there.
	if {[tk windowingsystem] eq "win32"} {
		set ico [file join $dir rio.ico]
		if {[file exists $ico]} { catch {wm iconbitmap . -default $ico} }
	}
}
apply_window_icon

# Re-sync the dock whenever rio regains OS focus, to pick up changes made outside rio
# (see app_focus_event). The binding lives on the toplevel bindtag, so a focus event on
# any descendant reaches it; app_focus_settle debounces the flurry into one check.
bind . <FocusIn>  app_focus_event
bind . <FocusOut> app_focus_event

# Load the syntax highlighters before the first apply_theme (which configures a
# text tag per token type from the theme's syntax.* roles) and before any buffer
# loads (which re-tokenises it) — D32.
hl_load

# Load the editing modes the same way (D38): registry, shipped modules, user
# drop-ins. Loaded before prefs so a persisted mode name can resolve; attached by
# apply_editmode in the boot applier block below.
modes_load
modes_menu_fill

# Load saved preferences (theme, wrap, dock, chat) over the defaults, then apply the
# theme before the first tab is drawn, so every widget — and the tab bar refresh_tabs
# builds — uses the role table. A persisted theme that no longer exists falls back to
# the default rather than erroring at startup (D31).
prefs_load
ledger_load   ;# which extensions this GUI installed, with their provenance (D39)
ext_installed_compute  ;# the installed view (D107) — the core's half arrives with the first scan
sources_seed_default   ;# first run: pre-fill sources.list with rio's own repo (D39)
repo_keys_load         ;# which signing key speaks for which repository (D118)
# Greet the core before any other op. This is the first exchange over the channel, so
# it's also where a stale connection surfaces: a dead `ssh -L` forward accepts the
# socket but never answers, and without this bounded handshake the GUI would hang with
# a blank window (a real bug report). fatal → a clear dialog, then exit.
hello_core 1
# The greeting bounded only the first exchange; the watchdog (D37) extends that
# cover to the whole session. Socket-attached cores only — a pipe EOFs on its own.
if {$::core_remote} watch_start
set _boot_theme [rio_call theme.get [dict create name $::theme_name]]
if {![dict get $_boot_theme ok]} {
	set ::theme_name default
	set _boot_theme [rio_call theme.get {}]
}
apply_theme [dict get $_boot_theme result]
set ::theme_choice $::theme_name
# The Preferences window's Theme control (D58) shows the current theme by its pretty
# label, with a trailing ellipsis — the standard "opens a chooser" affordance, since D92
# turned it from a dropdown into a button onto the shared picker. Keep that display
# string tracking ::theme_choice so a switch from either door (View ▸ Theme… or the
# button) updates the text. One trace, live for the app's life — it writes only a
# variable, harmless whether the window is open.
proc theme_choice_display {} { return "[theme_label $::theme_choice]…" }
set ::theme_choice_label [theme_choice_display]
trace add variable ::theme_choice write \
	{apply {{a b c} {set ::theme_choice_label [theme_choice_display]}}}

# Adopt the core's existing buffer(s), then process the command line. In-process: a
# directory argument opens as the project folder, a file opens in a tab. Remote: the
# path lives on the SERVER, so we can't stat it from here — open each as a project
# folder (project.open) and let the core judge; files are reached via the tree (D29).
set ::nav_root ""          ;# rl_* list state was initialised at widget construction
set ::nav_expanded [dict create]   ;# unfolded-dir set for the files tree (D87)
set ::nav_row_depth [dict create]  ;# path -> depth, filled per paint (arrow-click hit test)
adopt_initial_buffers      ;# take over the core's existing buffer(s) (D29)
apply_layout               ;# derive placement + tab strips from the layout (D35 b/c)
rio::panel::refresh $::dock_pane   ;# first populate of the dock's active pane
apply_wrap                 ;# sync wrap + the horizontal scrollbar to ::wrap_lines
apply_wrap_indent          ;# size the wrapped-line indents to each buffer (if enabled)
apply_line_numbers         ;# grid each group's gutter to ::line_numbers (default on)
apply_curline              ;# paint the caret-line band on each group (default on)
nav_hidden_glyph           ;# sync the Files-pane ◉/◌ toggle to ::show_hidden (D62)
apply_editmode             ;# attach the editing mode (windows default) to the RioMode tag (D38)
adopt_agent_status         ;# mirror the core's live provider/auto-accept; don't overwrite it (D30)
foreach f $argv {
	if {$::core_remote} {
		open_folder $f
	} elseif {[file isdirectory $f]} {
		open_folder $f
	} else {
		do_open $f
	}
}

# Reopen the folder from last launch if argv opened none (D88), so a bare `rio` resumes
# the project instead of a blank pane — and so the workspace restore below has a root to
# key on. Local cores only; a no-op when a project is already open.
reopen_last_project

# Resume the project's workspace: reopen the files that were open last time (D31).
# Only meaningful once a project is open (argv opened one, or reopen_last_project did — or
# none, then this is a no-op); the core prunes vanished paths, so a restore never errors on
# stale entries. Still guarded by ::rio_started=0, so the do_opens here don't each re-save.
session_restore

# Let the window settle at its natural content size, then stop child geometry from
# driving the toplevel. After this, resizing the dock (the sash) flexes the editor
# rather than resizing the whole window — which is what made sash drags feed back
# on themselves. The user can still resize the toplevel via the WM as usual.
update idletasks
pack propagate . 0

# Startup is done: from here, view-state and workspace changes persist (D31).
set ::rio_started 1

# Look for new versions of the installed extensions, if the user asked for that
# (D107) — off by default, deferred on a timer, and silent about everything but a
# genuine finding. Armed after ::rio_started so a preference written by the
# dialog's "don't check again" persists.
ext_check_arm

# Register the whole window as an OS file-drop target (D86) so a file dropped anywhere —
# a dock, the tab strip, empty editor space — opens (each editor text widget also registers
# itself in make_editor_group, for drops that land on buffer text). Optional tkdnd + local
# core only. Whether that holds headless depends on the host: a bare Linux CI box has no
# tkdnd and this is a no-op, but the Magicsplat distribution bundles it on Windows, where
# the targets really are registered (harmless — nothing can drop onto a withdrawn window).
if {$::have_tkdnd && !$::core_remote} {
	tkdnd::drop_target register . DND_Files
	bind . <<Drop>> {dnd_open_files %D}
}

# A test harness sets RIO_GUI_HEADLESS to keep the window off-screen.
#
# Map it once, off-screen, before withdrawing it. X11 assigns a toplevel real
# geometry whether or not it is ever mapped, so plain `wm withdraw .` was enough
# there; Windows does not — `winfo width .` stays at the trivial 120x1 and every
# child collapses with it (the tab strip measured 47px), so any check that asks
# whether something FITS its pane reads the wrong answer. The sizes survive the
# withdraw, so the final state is the same withdrawn window as before, only with
# a usable layout underneath it. See CAVEATS.md.
if {[info exists ::env(RIO_GUI_HEADLESS)]} {
	wm geometry . 1200x800-4000-4000
	update                       ;# a full update: idletasks alone does not MAP it
	wm withdraw .
}

# Headless means there is NO HUMAN at this display — so a blocking dialog has only two
# ways to end, and both are wrong: it waits forever, or it lands on whichever screen the
# suite happens to be running against and waits for a developer to click it. The second is
# what actually happened: a test run asked jka "«zeta.txt» has been deleted on disk. Keep
# it open in the editor?" and their answer silently decided the state the rest of the suite
# then ran against. A suite that needs an answer must supply it itself.
#
# The line, and it is jka's: a dialog that REPORTS something is worth seeing — an error
# message is a diagnostic — while one that ASKS YOU TO DECIDE must never reach a person who
# cannot know whether their answer changes the result. Both halves are served by sending
# the dialog to the test OUTPUT instead of the screen. So each of these writes what it was
# about to ask to stderr (where it survives even a `catch`, and is copy-pasteable in a way
# a screenshot never was) and then raises, failing the suite that reached it.
#
# No informational carve-out: a report_error reaching a test means an op failed where the
# test did not expect it, which is worth failing on — and the message is preserved above.
#
# A suite that MEANS to exercise a dialog overrides these the way it always has
# (`rename tk_messageBox _real_mb ; proc tk_messageBox {args} {...}`) — it now renames this
# guard rather than the real dialog, which changes nothing for it.
#
# Not covered: rio's own tkwait-window modals (name_prompt, pick_dialog,
# remote_browse_dialog, connect_remote_dialog, extw_sources_dialog, keybindings_dialog).
# Each is reached only by an explicit call, so a suite that calls one meant to.
set ::headless_dialogs {}   ;# what was asked, when nobody was there to answer
if {[info exists ::env(RIO_GUI_HEADLESS)]} {
	foreach _hl_dlg {tk_messageBox tk_getOpenFile tk_getSaveFile tk_chooseDirectory
	                 tk_chooseColor tk_dialog} {
		if {[info commands ::$_hl_dlg] eq ""} continue
		rename ::$_hl_dlg ::_headless_real_$_hl_dlg
		proc ::$_hl_dlg {args} [string map [list @N@ $_hl_dlg] {
			lappend ::headless_dialogs "@N@ $args"
			puts stderr "HEADLESS DIALOG: @N@ $args"
			flush stderr
			return -code error "@N@ reached with no stub under RIO_GUI_HEADLESS: $args"
		}]
	}
	unset -nocomplain _hl_dlg

	# Raising is not enough on its own. Most dialogs are reached from a timer or event
	# callback, where Tcl hands the error to the background handler and carries on — so a
	# suite can finish, print ALL CHECKS PASSED, and still have asked a question nobody
	# answered. (Observed: exactly that, before the fixture teardown below was fixed.) The
	# recorded list is therefore the authority: a run that asked anything fails, whatever
	# happened to the error afterwards.
	rename exit _headless_real_exit
	proc exit {{code 0}} {
		if {[llength $::headless_dialogs]} {
			puts stderr "\nRUN FAILED — [llength $::headless_dialogs] dialog(s) reached with no stub; a headless run must never ask:"
			foreach d $::headless_dialogs { puts stderr "  $d" }
			flush stderr
			if {$code == 0} { set code 1 }
		}
		_headless_real_exit $code
	}

	# wish's own background-error handler is itself a dialog. Print instead, so a stray
	# error in a callback cannot stop a run either.
	proc bgerror {msg} {
		puts stderr "HEADLESS BGERROR: $msg\n$::errorInfo"
		flush stderr
	}
}

# If keys.json had entries we couldn't use, say so once — a silent skip would leave the
# user's remap mysteriously ineffective. The editor still ran on the valid rest.
if {[llength $::keymap_bad] && ![info exists ::env(RIO_GUI_HEADLESS)]} {
	report_error "Some shortcuts in [keys_path] were ignored:\n  • [join $::keymap_bad "\n  • "]"
}
