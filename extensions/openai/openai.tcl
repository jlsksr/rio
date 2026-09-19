# extensions/openai — loader / entry file (AGENTS.md D8, D26, D66).
#
# MIT-licensed, like rio itself (D121). The notice is IN this file because an installed
# extension travels alone: rio writes the payload into your extension directory, and there
# is no LICENSE beside it there (D122).
#
# Copyright (c) 2026 Julius Kaiser <jkdata@mailbox.org>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be included in all copies
# or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
# CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
# OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
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
