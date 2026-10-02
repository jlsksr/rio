# rio-gui/menubar.tcl — build the menubar; top-level code, runs after build.tcl.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Menus use stock Tk behaviour. An earlier tweak (D59, reverted) rebound the Menu
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
.m.view.zoom add command -label "Zoom In"    -accelerator "$::primary_label++" -command {editor_zoom 1}
.m.view.zoom add command -label "Zoom Out"   -accelerator "$::primary_label+-" -command {editor_zoom -1}
.m.view.zoom add command -label "Reset Zoom" -accelerator "$::primary_label+0" -command editor_zoom_reset
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
# Extensions… is NOT here (it moved to Settings in D67, and to its own top-level menu in
# D130): it is a management dialog that
# installs the providers/modes/themes the choosers pick, not a pane toggle.

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
# Extensions… is NOT here any more (D130, amending D67): it leads the top-level
# Extensions menu, alongside the per-extension settings doors, so everything to do with
# extensions is in one place. This menu keeps rio's own fast switches.
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

# Extensions (D130) sits after Settings and before Help: rio's own configuration first,
# then what you have added to it, then Help last. It leads with the installer and then
# offers one door per installed extension that has something to configure — filled by
# extensions_menu_fill from the same cache the provider cascade above uses, so an
# extension appears here with no code change. The settings behind those doors belong to
# the extension; rio's settings ABOUT extensions stay in Preferences ▸ Extensions.
menu .m.extensions -tearoff 0
.m add cascade -label Extensions -menu .m.extensions
extensions_menu_fill

# Help is the last (rightmost) menu, the Windows/VSCode convention (D76). Contents… opens the
# manual in rio itself (D99) and About names the version and the build, so a tester can say
# which rio they're running (D123 — the release line, and the exact commit under it).
# Contents first, About last — the Windows order.
menu .m.help -tearoff 0
.m add cascade -label Help -menu .m.help
.m.help add command -label "Contents…" -command help_window
.m.help add separator
.m.help add command -label "About rio" -command about_dialog
