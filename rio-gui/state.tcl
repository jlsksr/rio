# rio-gui/state.tcl — view state every part shares, and the chrome's fonts.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Per-buffer view state. The core holds the text; we hold the rest. `cursor`/`yview`
# are per-buffer (a buffer lives in exactly one editor group in v1, D33), while tab
# order and the active buffer are per-GROUP — see ::grp below.
set ::buffers {} ;# id -> {path <s> meta <dict> modified <0|1> cursor <idx> yview <frac>}

# Editor groups (D33). The center holds one or two editor groups side by
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
# `monospace` is fontconfig's alias, so X11 resolves it to a fixed-width family. Aqua (and
# possibly Windows) knows no such family and falls back to the PROPORTIONAL system UI font,
# which silently takes the editor's columns with it. Asked of Tk's own metrics rather than
# of the platform: where the alias already lands on a fixed font it is kept, anywhere else
# it becomes the family of Tk's TkFixedFont (Menlo on macOS). Other families pass through.
proc mono_family {fam} {
	if {$fam ne "monospace"} { return $fam }
	if {![info exists ::mono_resolved]} {
		set ::mono_resolved [expr {[font metrics {monospace 12} -fixed]
			? "monospace" : [font actual TkFixedFont -family]}]
	}
	return $::mono_resolved
}
set ::mono [mono_family monospace] ;# the chrome's fixed-width family, resolved once
# The platform's primary shortcut modifier (D136): Command on a Mac, where Control keeps the
# system's own text keys (Ctrl+A to the line start, Ctrl+K to kill, …), and Control
# everywhere else. `::primary_label` is how a menu or a page spells it.
set ::primary_mod   [expr {[tk windowingsystem] eq "aqua" ? "Command" : "Control"}]
set ::primary_label [expr {[tk windowingsystem] eq "aqua" ? "Cmd" : "Ctrl"}]
# Aqua sizes and appearance (D135). Tk converts a font's points with `tk scaling`, which is
# 1 px/pt on Aqua against 1.33 on X11, so the theme's UI 9 is 9 px on a Mac: below the
# platform's own floor for interface text. Rather than rescale everything (which would also
# grow the editor past a Mac editor's usual size), chrome and chat fonts get a floor there,
# applied where D24 puts every Tk-specific mapping: in the GUI, never in the theme data.
# The editor font (RioEditorFont) is exempt, so the theme's size and D56's override stand.
set ::ui_font_floor [expr {[tk windowingsystem] eq "aqua" ? 11 : 0}]
proc ui_size {sz} {
	return [expr {$sz < $::ui_font_floor ? $::ui_font_floor : $sz}]
}
# A literal chrome font, floored like the named ones. Every fixed-width chrome widget is
# built through this, so the floor has one home.
proc chrome_font {sz} { return [list $::mono [ui_size $sz]] }
# Aqua draws button, menubutton and checkbutton as native controls that ignore -background,
# so a dark theme got light blobs. The native appearance follows the THEME (not the system
# setting, which is what `auto` would follow): dark when ui.bg is dark. Perceived lightness
# on a 0-255 scale, Rec. 601 weights.
proc hex_luma {hex} {
	lassign [winfo rgb . $hex] r g b
	return [expr {(0.299*$r + 0.587*$g + 0.114*$b) / 257.0}]
}
proc aqua_appearance_for {bg} {
	return [expr {[hex_luma $bg] < 128 ? "darkaqua" : "aqua"}]
}
set ::aqua_appearance aqua ;# apply_theme sets it from ui.bg
# The command is `unsupported` and missing on older Tk, hence the catch. A toplevel has no
# native window until its first idle pass, so new ones are caught by the <Configure> below,
# which fires then, withdrawn or not, and before the first map.
proc aqua_appearance_apply {w} {
	if {[tk windowingsystem] ne "aqua"} return
	catch {
		if {[::tk::unsupported::MacWindowStyle appearance $w] ne $::aqua_appearance} {
			::tk::unsupported::MacWindowStyle appearance $w $::aqua_appearance
		}
	}
}
proc aqua_appearance_all {} {
	set todo [list .]
	while {[llength $todo]} {
		set w [lindex $todo 0]; set todo [lrange $todo 1 end]
		if {$w eq "." || [winfo class $w] eq "Toplevel"} { aqua_appearance_apply $w }
		lappend todo {*}[winfo children $w]
	}
}
# The appearance only works on a button left at its native colours. Given a -background, Aqua
# tints the bezel toward it and draws the -foreground on top, which in a dark theme is a pale
# pill with unreadable text. So on Aqua, rio's colours are taken back off every button and
# menubutton: once when it is mapped, and across the tree after each theme switch, because
# the applier and the dialog builders set them in many places. A checkbutton's box is drawn
# natively too, but its colours only fill the label area around it, so it keeps them.
proc aqua_native_colours {w} {
	if {[tk windowingsystem] ne "aqua"} return
	if {[winfo class $w] ni {Button Menubutton}} return
	foreach opt {-background -foreground -activebackground -activeforeground} {
		catch {
			set def [lindex [$w configure $opt] 3]
			if {[$w cget $opt] ne $def} { $w configure $opt $def }
		}
	}
}
proc aqua_native_colours_all {} {
	set todo [list .]
	while {[llength $todo]} {
		set w [lindex $todo 0]; set todo [lrange $todo 1 end]
		aqua_native_colours $w
		lappend todo {*}[winfo children $w]
	}
}
if {[tk windowingsystem] eq "aqua"} {
	bind Toplevel <Configure> {+if {"%W" eq [winfo toplevel %W]} {aqua_appearance_apply %W}}
	bind Button     <Map> {+aqua_native_colours %W}
	bind Menubutton <Map> {+aqua_native_colours %W}
}
set ::editor_theme_size   12        ;# the active theme's editor size
set ::chat_turn_open 0 ;# mid-stream: an assistant block is open, deltas appending
set ::chat_thinking_open 0 ;# mid-stream: a run of reasoning is open (provider-api 4)
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
set ::autosave_on 1       ;# the core's choice: keep recovery copies of changed buffers (D132)
set ::autosave_interval 30000 ;# and how often it writes one — the core's number, not ours
set ::recover_pending {}  ;# {id path} per file opened during boot with a recovery copy waiting
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
# One shared Tcl object per distinct {state param} pair, so hl_enter's one entry per line
# costs a pointer rather than a freshly allocated two-element list. A scanner has a handful
# of distinct pairs — measured over a 4 MB Tcl file, exactly TWO for 131,072 lines — so the
# table is tiny and the sharing near-total. The cap is there only so a scanner whose `param`
# carries data (a heredoc delimiter, a fence's character and length) cannot grow it without
# bound; past the cap, entries are simply not shared and everything still works.
set ::hl_states {}
set ::hl_states_max 256
