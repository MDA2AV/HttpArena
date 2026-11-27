import java.io.{ByteArrayInputStream, IOException}
import java.net.ServerSocket
import java.nio.charset.StandardCharsets.US_ASCII
import java.nio.file.{Files, Path}
import java.security.{GeneralSecurityException, KeyFactory, KeyStore, Signature}
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import javax.net.ssl.{KeyManagerFactory, SSLContext, SSLSocket}
import scala.util.control.NonFatal

private object ArenaTls {
  def context(cert: Path, key: Path): SSLContext =
    context(readPair(cert, key), verifyPair = false)

  def reloadingSocket(cert: Path, key: Path): ServerSocket = {
    val initialPair = readPair(cert, key)
    val initialContext = context(initialPair, verifyPair = true)
    new ServerSocket() {
      // Potateh's single accept loop owns this state. Established sockets keep their original context.
      private var pair = initialPair
      private var currentContext = initialContext

      override def accept(): SSLSocket = {
        val socket = super.accept()
        try {
          reload()
          val factory = currentContext.getSocketFactory
          val tls = factory.createSocket(socket, socket.getInetAddress.getHostAddress, socket.getPort, true)
            .asInstanceOf[SSLSocket]
          tls.setUseClientMode(false)
          tls
        } catch {
          case NonFatal(error) =>
            try socket.close()
            catch { case NonFatal(closeError) => error.addSuppressed(closeError) }
            throw error
        }
      }

      private def reload(): Unit = {
        try {
          val candidate = readPair(cert, key)
          if candidate != pair then {
            val updated = context(candidate, verifyPair = true)
            pair = candidate
            currentContext = updated
          }
        } catch {
          // The certificate and key are replaced separately. Keep serving until both match.
          case _: IOException | _: GeneralSecurityException | _: IllegalArgumentException => ()
        }
      }
    }
  }

  private def readPair(cert: Path, key: Path): (certificatePem: String, keyPem: String) =
    (Files.readString(cert), Files.readString(key))

  private def context(pair: (certificatePem: String, keyPem: String), verifyPair: Boolean): SSLContext = {
    val certificate = CertificateFactory.getInstance("X.509")
      .generateCertificate(new ByteArrayInputStream(pair.certificatePem.getBytes(US_ASCII)))
    val pem = pair.keyPem
      .replace("-----BEGIN PRIVATE KEY-----", "")
      .replace("-----END PRIVATE KEY-----", "")
      .replaceAll("\\s", "")
    val publicKey = certificate.getPublicKey
    val keyBytes = Base64.getDecoder.decode(pem)
    val key = KeyFactory.getInstance(publicKey.getAlgorithm).generatePrivate(new PKCS8EncodedKeySpec(keyBytes))
    if verifyPair then {
      val algorithm = publicKey.getAlgorithm match {
        case "RSA" => "SHA256withRSA"
        case "EC"  => "SHA256withECDSA"
        case name  => name
      }
      val signature = Signature.getInstance(algorithm)
      val challenge = "HttpArena TLS key pair".getBytes(US_ASCII)
      signature.initSign(key)
      signature.update(challenge)
      val signed = signature.sign()
      signature.initVerify(publicKey)
      signature.update(challenge)
      require(signature.verify(signed), "TLS certificate and key do not match")
    }
    val store = KeyStore.getInstance(KeyStore.getDefaultType)
    store.load(null, null)
    store.setKeyEntry("server", key, Array.emptyCharArray, Array(certificate))
    val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm)
    managers.init(store, Array.emptyCharArray)
    val context = SSLContext.getInstance("TLS")
    context.init(managers.getKeyManagers, null, null)
    context
  }
}
