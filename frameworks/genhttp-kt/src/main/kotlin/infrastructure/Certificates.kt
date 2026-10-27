package genhttp.infrastructure

import java.io.File
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64

object Certificates {

    /**
     * Reads a certificate chain and its PKCS#8 private key from PEM files.
     */
    fun fromPem(certificatePath: String, keyPath: String): KeyStore.PrivateKeyEntry {
        val chain = File(certificatePath).inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificates(it).toTypedArray()
        }

        val pem = File(keyPath).readText().replace(Regex("-----(BEGIN|END) PRIVATE KEY-----"), "")
        val keySpec = PKCS8EncodedKeySpec(Base64.getMimeDecoder().decode(pem))

        val key = KeyFactory.getInstance(chain.first().publicKey.algorithm).generatePrivate(keySpec)

        return KeyStore.PrivateKeyEntry(key, chain)
    }

}
