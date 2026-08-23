package com.vortx.android.usenet

import org.w3c.dom.Element
import org.w3c.dom.Node
import java.io.ByteArrayInputStream
import javax.xml.parsers.DocumentBuilderFactory

/// A pure NZB parser (no Android service dependency; runs in JVM unit tests too).
///
/// XXE-hardened: the factory is forced to disallow document type declarations, external general/parameter
/// entities, and external DTD/schema access, so an NZB that tries to smuggle an external entity (a real
/// SSRF risk in a parser wired into an on-device resolver) is rejected outright. Large-input guard: NZB
/// files are tiny (a few KB for a typical release), so a 4 MiB cap is far above any legitimate input while
/// bounding the expansion surface.
internal object NzbParser {

    fun parse(xml: ByteArray): List<NzbFile> = parse(xml.toString(Charsets.UTF_8))

    fun parse(xml: String): List<NzbFile> {
        require(xml.length <= MAX_XML_BYTES) { "NZB XML exceeds the 4 MiB safety cap" }
        val document = try {
            val factory = DocumentBuilderFactory.newInstance().apply {
                setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
                setFeature("http://xml.org/sax/features/external-general-entities", false)
                setFeature("http://xml.org/sax/features/external-parameter-entities", false)
                setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
                // Best-effort extras: some parser builds do not recognise these properties; the features
                // above are sufficient XXE protection on their own.
                try {
                    setAttribute("http://apache.org/xml/properties/accessExternalDTD", "")
                    setAttribute("http://apache.org/xml/properties/accessExternalSchema", "")
                } catch (_: IllegalArgumentException) {
                }
                isXIncludeAware = false
                isExpandEntityReferences = false
            }
            factory.newDocumentBuilder().parse(ByteArrayInputStream(xml.toByteArray(Charsets.UTF_8)))
        } catch (_: Exception) {
            // Malformed / XXE-attempting input: fail soft to an empty document, never propagate.
            return emptyList()
        }
        val root = document.documentElement ?: return emptyList()

        val files = arrayListOf<NzbFile>()
        childElements(root) { element ->
            if (element.tagName == "file") files.add(parseFile(element))
        }
        return files
    }

    private fun parseFile(node: Element): NzbFile {
        val poster = attr(node, "poster").orEmpty()
        val date = attr(node, "date").orEmpty()
        val subject = attr(node, "subject").orEmpty()

        val groups = child(node, "groups") ?: child(node, "group")
        // `<groups><group>alt.binaries.x</group></groups>`: the name lives in a GRANDCHILD, so read the
        // concatenated descendant text, not just direct text nodes.
        val group = groups?.textContent?.trim().orEmpty()

        val segments = arrayListOf<NzbSegment>()
        val directContainer = child(node, "segments")
        if (directContainer != null) {
            appendSegments(directContainer, segments)
        } else {
            appendSegments(node, segments)
        }
        // Assembly order MUST follow segment numbers regardless of document order.
        segments.sortBy { it.number }
        return NzbFile(
            // Real NZB subjects look like `"Show.S01E01.mkv" yEnc (1/3) 52428800`: the QUOTED token is
            // the actual file name; unquoted subjects carry it before the ` yEnc` marker. Fall back to
            // the raw subject only when neither shape matches.
            name = QUOTED_NAME.find(subject)?.groupValues?.getOrNull(1)
                ?: subject.substringBefore(YENC_MARKER).trim().ifEmpty { subject },
            poster = poster,
            date = date,
            subject = subject,
            group = group,
            segments = segments,
        )
    }

    private fun appendSegments(parent: Node, out: MutableList<NzbSegment>) {
        childElements(parent) { element ->
            if (element.tagName == "segment" || element.tagName == "article") {
                out.add(parseSegment(element))
            }
        }
    }

    private fun parseSegment(element: Element): NzbSegment {
        val number = attr(element, "number")?.toLongOrNull() ?: 0L
        val bytes = attr(element, "bytes")?.toLongOrNull() ?: 0L
        // The message-id is the ELEMENT TEXT in a standard NZB (`<segment bytes=".." number="..">id@host</segment>`);
        // an `article=".."` attribute is accepted as a non-standard fallback.
        val article = attr(element, "article") ?: firstText(element).orEmpty().trim()
        val isBinary = attr(element, "isbinary") == "y" || attr(element, "isBinary") == "y"
        val subject = firstText(element).orEmpty()
        return NzbSegment(
            subject = subject,
            bytes = bytes,
            number = number,
            article = article,
            isBinary = isBinary,
        )
    }

    private fun childElements(parent: Node, visit: (Element) -> Unit) {
        var child = parent.firstChild
        while (child != null) {
            if (child.nodeType == Node.ELEMENT_NODE) visit(child as Element)
            child = child.nextSibling
        }
    }

    private fun child(parent: Node, name: String): Element? {
        var current = parent.firstChild
        while (current != null) {
            if (current.nodeType == Node.ELEMENT_NODE && (current as Element).tagName == name) return current
            current = current.nextSibling
        }
        return null
    }

    private fun firstText(node: Node?): String? {
        if (node == null) return null
        var current = node.firstChild
        while (current != null) {
            if (current.nodeType == Node.TEXT_NODE) {
                val text = current.textContent
                if (text.isNotEmpty()) return text
            }
            current = current.nextSibling
        }
        return null
    }

    private fun attr(element: Element, name: String): String? =
        element.getAttribute(name).takeIf { it.isNotEmpty() }

    private const val MAX_XML_BYTES = 4 * 1024 * 1024
    private val QUOTED_NAME = Regex("\"([^\"]+)\"")
    private const val YENC_MARKER = " yEnc"
}