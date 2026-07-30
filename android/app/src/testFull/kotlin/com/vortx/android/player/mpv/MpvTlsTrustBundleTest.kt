package com.vortx.android.player.mpv

import java.io.ByteArrayInputStream
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MpvTlsTrustBundleTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun `bundle is parseable deduplicated and atomically replaces corrupt output`() {
        val certificate = testCertificate()
        val directory = temporaryFolder.newFolder("trust")
        val prior = directory.resolve("mpv-system-ca-bundle.pem")
        prior.writeText("corrupt")

        val bundle = MpvConfig.writeCaBundle(directory, listOf(certificate, certificate))

        val parsed = bundle.inputStream().use { input ->
            CertificateFactory.getInstance("X.509")
                .generateCertificates(input)
                .filterIsInstance<X509Certificate>()
        }
        assertEquals(1, parsed.size)
        assertArrayEquals(certificate.encoded, parsed.single().encoded)
        assertEquals(1, bundle.readText().split("-----BEGIN CERTIFICATE-----").size - 1)
        assertFalse(bundle.readText().contains("corrupt"))
        assertTrue(directory.listFiles().orEmpty().none { it.name.contains(".tmp") })
    }

    @Test
    fun `empty trust store fails without publishing a usable bundle`() {
        val directory = temporaryFolder.newFolder("empty")

        assertTrue(runCatching { MpvConfig.replaceCaBundle(directory, emptyList()) }.isFailure)
        assertFalse(directory.resolve("mpv-system-ca-bundle.pem").exists())
    }

    @Test
    fun `failed refresh removes the prior trust snapshot`() {
        val directory = temporaryFolder.newFolder("revoked")
        val prior = MpvConfig.replaceCaBundle(directory, listOf(testCertificate()))
        assertTrue(prior.isFile)

        assertTrue(runCatching { MpvConfig.replaceCaBundle(directory, emptyList()) }.isFailure)
        assertFalse(prior.exists())
    }

    private fun testCertificate(): X509Certificate =
        CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(TEST_CA_PEM.toByteArray(Charsets.US_ASCII)))
            as X509Certificate

    private companion object {
        val TEST_CA_PEM = """
            -----BEGIN CERTIFICATE-----
            MIICPDCCAaWgAwIBAgIUD+9d2qXlB8VtgUXQ+bC+3t+SXuwwDQYJKoZIhvcNAQEL
            BQAwMDEYMBYGA1UEAwwPVm9ydFggVGVzdCBSb290MRQwEgYDVQQKDAtWb3J0WCBU
            ZXN0czAeFw0yNjA3MzAyMDQ5MTBaFw0zNjA3MjcyMDQ5MTBaMDAxGDAWBgNVBAMM
            D1ZvcnRYIFRlc3QgUm9vdDEUMBIGA1UECgwLVm9ydFggVGVzdHMwgZ8wDQYJKoZI
            hvcNAQEBBQADgY0AMIGJAoGBAOsBrhgnx24p6vYbIyV9/DjSDv6gXWKTiUxhNH35
            J43uqyCdkdu7HP1GYOsBJBSqR1nFCWvZs+Pz63j5YqYLSUy6orZKo/Nc6GVbllmL
            lGapQ3Oq0G6q9lkJvVHRrFLWvPiij6JGuRGjYSWYHtrTn6dMQ6HXYZNhItIUrEIO
            tRHrAgMBAAGjUzBRMB0GA1UdDgQWBBTXkZeW0uzgCylUQabnb4Ugh6R30TAfBgNV
            HSMEGDAWgBTXkZeW0uzgCylUQabnb4Ugh6R30TAPBgNVHRMBAf8EBTADAQH/MA0G
            CSqGSIb3DQEBCwUAA4GBAG/iw3A3tKUQ1kQsP3mEbC6oZB0bttXoQmr+5JzSIVxa
            aw59rEmrQM35kk8aNZne6BVEyYAopEX0qyPHuG+WK8l7FiVzi5IdvQncs1+s3QcK
            //yxVdhBMkvWjasqJJBcKqlSgEdzIiIhD5L6Xz6aoF7Zkq9qO5DjsHimKct8imXO
            -----END CERTIFICATE-----
        """.trimIndent()
    }
}
