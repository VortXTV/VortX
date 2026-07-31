package com.vortx.android.security

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Test
import org.w3c.dom.Element

class CredentialBackupRulesTest {

    @Test
    fun everyCredentialFileIsExcludedFromLegacyBackup() {
        val excluded = excludes(readXml("backup_rules.xml"), parentTag = "full-backup-content")

        assertEquals(expectedCredentialFiles, excluded.filter { it.startsWith("vortx_") }.toSet())
    }

    @Test
    fun everyCredentialFileIsExcludedFromCloudBackupAndDeviceTransfer() {
        val xml = readXml("data_extraction_rules.xml")

        assertEquals(expectedCredentialFiles, excludes(xml, parentTag = "cloud-backup"))
        assertEquals(expectedCredentialFiles, excludes(xml, parentTag = "device-transfer"))
    }

    private fun readXml(name: String): Element {
        val candidates = listOf(
            File("src/main/res/xml/$name"),
            File("app/src/main/res/xml/$name"),
            File("android/app/src/main/res/xml/$name"),
        )
        val file = candidates.firstOrNull(File::isFile)
            ?: error("Could not locate $name from ${File(".").absolutePath}")
        return DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).documentElement
    }

    private fun excludes(root: Element, parentTag: String): Set<String> {
        val parents =
            if (root.tagName == parentTag) listOf(root) else {
                val nodes = root.getElementsByTagName(parentTag)
                (0 until nodes.length).mapNotNull { nodes.item(it) as? Element }
            }
        return parents.flatMap { parent ->
            val nodes = parent.getElementsByTagName("exclude")
            (0 until nodes.length).mapNotNull { nodes.item(it) as? Element }
        }.filter { it.getAttribute("domain") == "sharedpref" }
            .map { it.getAttribute("path") }
            .filter { it.startsWith("vortx_") }
            .toSet()
    }

    private companion object {
        val expectedCredentialFiles = setOf(
            "vortx_sync_session.xml",
            "vortx_sync_session_plain.xml",
            "vortx_debrid_keys.xml",
            "vortx_debrid_keys_plain.xml",
            "vortx_auth_identity.xml",
            "vortx_auth_identity_plain.xml",
            "vortx_trakt_tokens.xml",
            "vortx_trakt_tokens_plain.xml",
            "vortx_simkl_tokens.xml",
            "vortx_simkl_tokens_plain.xml",
            "vortx_mediaserver_tokens.xml",
            "vortx_mediaserver_tokens_plain.xml",
            "vortx_iptv_creds.xml",
            "vortx_iptv_creds_plain.xml",
        )
    }
}
