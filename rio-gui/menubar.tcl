# rio-gui/menubar.tcl — build the menubar; top-level code, runs after build.tcl.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Menus are stock Tk. Never patch Tk's menu bindings or procs: that made
# clicks misfire (D59).
#
#   File  Edit  View  Find  Compare  Settings  Extensions  Help
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
# Edit: built from editor_menu_items, the table behind the editor's
# right-click menu too (D108). -postcommand greys items for the focused group.
menu .m.edit -tearoff 0 -postcommand editor_menu_post
.m add cascade -label Edit -menu .m.edit
editor_menu_fill .m.edit [editor_menu_items [gget $::focus path]]
menu .m.view -tearoff 0
.m add cascade -label View -menu .m.view
# View: the four tool panes. A checkmark means the pane is on screen; a
# click shows or hides it.
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
# Tab strip on overflow (D57): scroll (one row and arrows) or multi (rows).
.m.view add checkbutton -label "Multi-Line Tabs" \
	-onvalue multi -offvalue scroll -variable ::tab_layout -command tab_layout_apply
.m.view add checkbutton -label "Show Hidden Files" \
	-variable ::show_hidden -command apply_show_hidden
.m.view add separator
# Reach any buffer by name, in a bounded dialog (D74).
.m.view add command -label "Switch to Tab…" -command switch_tab_dialog
# Rarely used items go into submenus (D64): a Tk menu taller than the space
# below it misbehaves on X11.
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
# Theme and language: bounded pickers, not cascades (D92, D112). Both lists
# grow with every installed extension.
.m.view add command -label "Theme…" -command theme_pick_dialog
.m.view add command -label "Language…" -command language_pick_dialog

# Find (D75): in-buffer find and replace, and the project-wide Search. Named
# "Find" so it is not confused with View ▸ Search, the pane toggle.
menu .m.find -tearoff 0
.m add cascade -label Find -menu .m.find
.m.find add command -label "Find…"         -accelerator [key_accel find]      -command {find_open 0}
.m.find add command -label "Replace…"      -accelerator [key_accel replace]   -command {find_open 1}
.m.find add command -label "Find Next"     -accelerator [key_accel find-next] -command find_next
.m.find add command -label "Find Previous" -accelerator [key_accel find-prev] -command find_prev
.m.find add separator
.m.find add command -label "Search…"       -accelerator [key_accel search]    -command search_open

# Compare (D73): the diff view (D28) is a mode, not an editor layout, so it
# has its own menu. Another tab comes first: the more frequent case (D74).
menu .m.compare -tearoff 0
.m add cascade -label Compare -menu .m.compare
.m.compare add command -label "Compare With Another Tab…" -command compare_with_tab_dialog
.m.compare add command -label "Compare With A File…" -command compare_with_file_dialog
.m.compare add separator
.m.compare add command -label "Close Compare" -accelerator Esc -command compare_close
menu .m.settings -tearoff 0
.m add cascade -label Settings -menu .m.settings
# Settings: rio's fast switches. Preferences (D58) holds every setting; the
# items here are a second door to the ones switched often.
.m.settings add command -label "Preferences…" -accelerator [key_accel preferences] \
	-command preferences_window
.m.settings add separator
# The provider cascade is filled from the core (providers_menu_fill). A
# provider's key, prompts and allow-list are in Preferences ▸ Agent.
menu .m.settings.provider -tearoff 0
.m.settings add cascade -label "Agent Provider" -menu .m.settings.provider
# Agent mode: three exclusive states (D101, D102), the same variable as the
# chat header's control.
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
# Keyboard: the editing mode sets what keys do in the text (D38); the
# shortcuts editor remaps the app's chords (D23).
menu .m.settings.editmode -tearoff 0
.m.settings add cascade -label "Editing Mode" -menu .m.settings.editmode
.m.settings add checkbutton -label "Column Editing (Ctrl+Shift+Drag)" \
	-variable ::col_on -command apply_column_edit
.m.settings add command -label "Keyboard Shortcuts…" -command keybindings_dialog

# Extensions (D130): the installer, then one entry per installed extension
# that has settings (extensions_menu_fill). Those settings are the
# extension's; rio's settings about extensions are in Preferences.
menu .m.extensions -tearoff 0
.m add cascade -label Extensions -menu .m.extensions
extensions_menu_fill

# Help, rightmost (D76): the manual (D99), and About with version and
# build (D123).
menu .m.help -tearoff 0
.m add cascade -label Help -menu .m.help
.m.help add command -label "Contents…" -command help_window
.m.help add separator
.m.help add command -label "About rio" -command about_dialog
