# plugins/lib — shared JSON serialisation for LLM providers (AGENTS.md D8/D26).
#
# The request-body serialisers a provider needs are identical whichever LLM it
# targets: an ASCII-safe JSON *string* literal, and a flat-dict -> JSON *object*
# built from it. They lived in the Claude plugin; extracted here so a second
# provider (openai) shares one copy rather than forking a subtly different one.
# Pure string work — no Tk, no network, no provider knowledge (D1).
#
# Sourced by more than one plugin loader (server.tcl loads each), so the whole
# file is guarded to define its procs exactly once.

if {[llength [info commands rio::llm::jstr]]} { return }

namespace eval rio::llm {}

# A JSON string literal: escape ", \, and the control characters (RFC 8259), and
# \u-escape every NON-ASCII character so the whole request body is pure ASCII.
# That sidesteps request-body transcoding entirely — ASCII bytes are invariant
# under whatever encoding the HTTP layer applies — which is what a tool_result
# carrying a file's non-ASCII text (arrows, box-drawing, an emoji) needs to make
# it to the API intact. Astral codepoints (> U+FFFF) become a UTF-16 surrogate
# pair, the only way JSON can spell them; a Tcl build that already hands us
# surrogate halves (TCL_UTF_MAX=3) falls through the BMP branch and pairs up the
# same way.
proc rio::llm::jstr {s} {
	set out ""
	foreach ch [split $s ""] {
		scan $ch %c code
		if {$ch eq "\""} {
			append out {\"}
		} elseif {$ch eq "\\"} {
			append out {\\}
		} elseif {$code < 0x20} {
			switch -- $code {
				8  { append out {\b} }
				9  { append out {\t} }
				10 { append out {\n} }
				12 { append out {\f} }
				13 { append out {\r} }
				default { append out [format {\u%04x} $code] }
			}
		} elseif {$code > 0xffff} {
			set c [expr {$code - 0x10000}]
			append out [format {\u%04x\u%04x} \
				[expr {0xd800 + ($c >> 10)}] [expr {0xdc00 + ($c & 0x3ff)}]]
		} elseif {$code > 0x7e} {
			append out [format {\u%04x} $code]
		} else {
			append out $ch
		}
	}
	return "\"$out\""
}

# A flat {k v ...} dict -> a JSON object, every key and value escaped via jstr (so
# control characters and non-ASCII are \u-escaped — the body stays valid + ASCII).
# Tool inputs are flat string maps; a future typed input would re-serialize its
# values as strings, which is fine for the current tool set.
proc rio::llm::obj_json {d} {
	set parts {}
	dict for {k v} $d { lappend parts "[jstr $k]:[jstr $v]" }
	return "{[join $parts ,]}"
}
