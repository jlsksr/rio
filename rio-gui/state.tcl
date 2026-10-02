# rio-gui/state.tcl — view state every part shares, and the chrome's fonts.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Per-buffer view state. The core holds the text; the GUI holds the rest.
# Caret and scroll are per buffer; tab order and the active buffer are per
# group.
set ::buffers {} ;# id -> {path <s> meta <dict> modified <0|1> cursor <idx> yview <frac>}

# Editor groups (D33): one or two, side by side. Each has its own text
# widget, tab strip and active buffer. A buffer is in exactly one group.
#
#   ::grp   id -> dict:
#     w       the real text widget command; edits through it bypass the proxy
#     path    the Tk widget path (the proxy), for winfo, focus and bind
#     frame   the group's frame (.eg<id>)
#     tabs    its tab strip (.eg<id>.tabs)
#     cur     the active buffer id
#     order   buffer ids, in tab order
#     hl_*    the highlight cache (D32)
set ::grp    {} ;# group id -> group-state dict (above)
set ::groups {} ;# group ids, left-to-right
set ::focus  "" ;# the focused group id (::cur mirrors its active buffer)
set ::cur    "" ;# active buffer of the FOCUSED group — a mirror, kept by activate/focus_group

# The side dock shows one pane, on one side of the editor.
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
# The View menu's checkmarks: 1 when the pane's site is visible and the pane
# is its active tab. apply_layout sets them.
set ::shown_files 0 ; set ::shown_git 0 ; set ::shown_chat 0 ; set ::shown_search 0
set ::edit_mode windows   ;# active editing mode (D38/D41): windows ships; emacs/vi & other drop-ins install as extensions
set ::editmode_active ""  ;# the mode currently attached to the RioMode tag ("" before boot)
set ::editmode_status ""  ;# the mode's status-bar segment ("-- INSERT --" in vi; "" otherwise)
set ::theme_name default ;# active colour theme — a persisted preference; do_theme records it (D31)
set ::last_project ""    ;# last folder opened on a LOCAL core — persisted, reopened on next launch (D88)
set ::theme_choice default ;# what the Preferences button shows: tracks theme_name, snaps back on a failed switch (D39)
# Tab strip on overflow (D57); see tabstrip_layout.
set ::tab_layout scroll   ;# scroll | multi — see tabstrip_layout
set ::tabstrip_w [dict create] ;# per-group last laid-out strip width, to skip no-op <Configure>s
# The editor font (D56): the theme's, with the user's override on top.
set ::editor_font_family ""  ;# user family override, "" = use the theme's
set ::editor_font_size   0   ;# user size override, 0 = use the theme's
set ::editor_theme_family monospace ;# the active theme's editor family (apply_theme records it)
# Resolve the family `monospace`. On X11 it is a fixed-width alias; Aqua
# does not know it and falls back to a proportional font. So ask Tk: if the
# alias is not fixed-width, use TkFixedFont's family (Menlo on macOS).
proc mono_family {fam} {
	if {$fam ne "monospace"} { return $fam }
	if {![info exists ::mono_resolved]} {
		set ::mono_resolved [expr {[font metrics {monospace 12} -fixed]
			? "monospace" : [font actual TkFixedFont -family]}]
	}
	return $::mono_resolved
}
set ::mono [mono_family monospace] ;# the chrome's fixed-width family, resolved once
# The primary shortcut modifier (D136): Command on a Mac, Control elsewhere.
# ::primary_label is its spelling in a menu.
set ::primary_mod   [expr {[tk windowingsystem] eq "aqua" ? "Command" : "Control"}]
set ::primary_label [expr {[tk windowingsystem] eq "aqua" ? "Cmd" : "Ctrl"}]
# Aqua font floor (D135). A point is 1 px on Aqua (1.33 on X11), so the
# theme's UI 9 is too small there. Chrome and chat fonts get a floor of 11;
# the editor font does not.
set ::ui_font_floor [expr {[tk windowingsystem] eq "aqua" ? 11 : 0}]
proc ui_size {sz} {
	return [expr {$sz < $::ui_font_floor ? $::ui_font_floor : $sz}]
}
# A fixed-width chrome font of size `sz`, floored.
proc chrome_font {sz} { return [list $::mono [ui_size $sz]] }
# Aqua draws buttons natively and ignores -background. Their appearance
# follows the theme, not the system: dark when ui.bg is dark.
# hex_luma: lightness, 0-255, Rec. 601 weights.
proc hex_luma {hex} {
	lassign [winfo rgb . $hex] r g b
	return [expr {(0.299*$r + 0.587*$g + 0.114*$b) / 257.0}]
}
proc aqua_appearance_for {bg} {
	return [expr {[hex_luma $bg] < 128 ? "darkaqua" : "aqua"}]
}
set ::aqua_appearance aqua ;# apply_theme sets it from ui.bg
# Set a toplevel's appearance. The command is missing on older Tk, hence
# the catch. A new toplevel gets it from the <Configure> binding below.
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
# On Aqua a button with rio's colours is a pale pill with unreadable text.
# So reset every button's and menubutton's colours to the native ones: when
# it is mapped, and across the tree after a theme switch.
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
# The agent's busy indicator (D82): while a turn runs, a label cycles
# phrases and dots, so a wait never looks frozen.
set ::chat_busy       0    ;# a turn is being worked (animation running)
set ::chat_busy_after ""   ;# the pending `after` id, so it can be cancelled
set ::chat_busy_frame 0    ;# tick counter: drives the dots and the phrase change
set ::chat_busy_word  ""   ;# the phrase currently shown
# The phrases. Data: edit at will.
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
# The highlight cache (D32) is per group, in ::grp's hl_* keys; see
# new_group_state.
set ::hl_margin 50   ;# lines highlighted beyond each edge of the viewport (D126)
set ::hl_chunk 1000  ;# lines a single scan pass may walk before yielding to the event loop
# One shared object per distinct {state param} pair, so hl_enter's entry per
# line costs a pointer, not a list. Capped: a scanner whose param carries
# data (a heredoc delimiter) must not grow it without bound. Past the cap,
# entries are not shared.
set ::hl_states {}
set ::hl_states_max 256
