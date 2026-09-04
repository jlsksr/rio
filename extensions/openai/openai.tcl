# extensions/openai — loader / entry file (AGENTS.md D8, D26, D66).
#
# The OpenAI-compatible agent provider, shipped as an INSTALLABLE provider extension
# (kind = provider, D66) rather than in-tree: it lands in the core's provider store
# and the core sources THIS file (the manifest's `entry`) at startup. It sources
# only its own two payload files — the inference core and the auth face; the shared
# rio::llm::* runtime (JSON serialisers + HTTPS transport) and rio::secret::* are
# guaranteed present by the core BEFORE any provider loads (the provider-api = 1
# surface, server.tcl), so an installed provider ships no copy of them.
#
# (The plugin's own unit tests source the core lib themselves — see tests/.)

apply {{} {
	set dir [file dirname [file normalize [info script]]]
	source [file join $dir inference.tcl]
	source [file join $dir api-face.tcl]
}}
