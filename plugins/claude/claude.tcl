# plugins/claude — loader (AGENTS.md D26).
#
# Sources the shared inference core and the claude-api auth face. Loaded
# IN-PROCESS for now (the thin protocol-participant seam, D8 phasing); it becomes
# a real out-of-process plugin sharing the inference module when the plugin
# platform lands (D17-D19), with no interface rework. Face SELECTION/activation
# (which provider is live, and the key-entry UI) is wired by the frontend.

apply {{} {
	set dir [file dirname [file normalize [info script]]]
	source [file join $dir inference.tcl]
	source [file join $dir transport.tcl]
	source [file join $dir api-face.tcl]
}}
