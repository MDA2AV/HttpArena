package httparena;

import io.micronaut.runtime.Micronaut;

import javax.net.ssl.KeyManagerFactory;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.Base64;
import java.util.Collection;

public class Application {

    private static final Path CERT = Path.of("/certs/server.crt");
    private static final Path KEY = Path.of("/certs/server.key");
    private static final Path KEYSTORE = Path.of("/tmp/server.p12");

    public static void main(String[] args) {
        enableJsonTls();
        Micronaut.run(Application.class, args);
    }

    /**
     * json-tls needs HTTP/1.1 over TLS on 8081 alongside plaintext on 8080.
     * Micronaut serves both when dual-protocol is on, but its SSL config wants a
     * key store and the harness mounts PEMs, so the pair is converted here and
     * the resulting PKCS12 handed to Micronaut through its own configuration.
     * The listener is still Micronaut's; only the key material is prepared.
     *
     * <p>The harness mounts /certs for the TLS profiles only, so on every other
     * profile this is a no-op and the server comes up plaintext-only.
     */
    private static void enableJsonTls() {
        if (!Files.exists(CERT) || !Files.exists(KEY)) {
            return;
        }
        try {
            writeKeyStore();
        } catch (Exception e) {
            System.err.println("json-tls: could not build a key store from the mounted PEMs: " + e);
            return;
        }
        System.setProperty("micronaut.server.dual-protocol", "true");
        System.setProperty("micronaut.server.ssl.enabled", "true");
        System.setProperty("micronaut.server.ssl.port", "8081");
        System.setProperty("micronaut.server.ssl.key-store.path", "file:" + KEYSTORE);
        System.setProperty("micronaut.server.ssl.key-store.type", "PKCS12");
        System.setProperty("micronaut.server.ssl.key-store.password", "");
    }

    private static void writeKeyStore() throws Exception {
        Collection<? extends Certificate> certs;
        try (FileInputStream in = new FileInputStream(CERT.toFile())) {
            certs = CertificateFactory.getInstance("X.509").generateCertificates(in);
        }

        // Plain JDK crypto rather than java.security.PEMDecoder, which is still a
        // preview API on the JDK in this image.
        byte[] der = Base64.getDecoder().decode(
                Files.readString(KEY)
                        .replaceAll("-----(BEGIN|END) PRIVATE KEY-----", "")
                        .replaceAll("\\s", ""));
        PrivateKey privateKey = KeyFactory.getInstance("RSA")
                .generatePrivate(new PKCS8EncodedKeySpec(der));

        char[] password = new char[0];
        KeyStore store = KeyStore.getInstance("PKCS12");
        store.load(null, password);
        store.setKeyEntry("server", privateKey, password, certs.toArray(new Certificate[0]));
        try (FileOutputStream out = new FileOutputStream(KEYSTORE.toFile())) {
            store.store(out, password);
        }
        // sanity: fail loudly here rather than with an opaque Netty error later
        KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).init(store, password);
    }
}
