# plugins/openai — loader (AGENTS.md D8, D26).
#
# Sources the shared plugin lib (JSON serialisers + HTTPS transport, rio::llm::*),
# the OpenAI inference core, and the OpenAI-compatible auth face. Loaded IN-PROCESS
# by the core (server.tcl), the same phasing as the Claude plugin (D8); it becomes
# a real out-of-process / installable plugin with no interface rework once the
# plugin platform lands (milestone B). Face selection and the key-entry UI are
# wired by the frontend.

apply {{} {
	set dir [file dirname [file normalize [info script]]]
	# The lib is shared with the Claude plugin; both files guard against a double
	# source (server.tcl loads every plugin, each pulling the lib).
	source [file join $dir .. lib json.tcl]
	source [file join $dir .. lib transport.tcl]
	source [file join $dir inference.tcl]
	source [file join $dir api-face.tcl]
}}
