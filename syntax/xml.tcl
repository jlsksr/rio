# rio — XML syntax highlighting (AGENTS.md D32). XML and (X)HTML share one grammar of
# tags, attributes, quoted values, entities, comments (<!-- -->), and processing
# instructions / declarations (<?…?>, <!…>) — so rather than duplicate a second scanner,
# XML REUSES the (X)HTML scanner (rio::syntax::html::scan, in html.tcl) and simply claims
# the XML family of extensions under its own language NAME.
#
# The register call only stores the scanner's proc NAME (a string); the proc itself is
# invoked at scan time, by which point every syntax/*.tcl module is loaded — so this file
# needs no `source` and does not depend on load order.
#
# Honest gap inherited from the reuse: a `<![CDATA[ … ]]>` section is treated as a generic
# `<!…>` declaration (coloured `meta` up to the first `>`), so a `>` inside CDATA closes
# it early. Rare in the config/markup XML this most serves; noted rather than special-cased.

namespace eval rio::syntax::xml {}

rio::syntax::register XML {xml xsd xsl xslt svg rss atom plist wsdl xaml resx} \
	rio::syntax::html::scan
