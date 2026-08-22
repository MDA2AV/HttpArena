<?php

declare(strict_types=1);

namespace App;

use Hyperf\HttpServer\Server;

/**
 * The json-tls listener on 8081.
 *
 * Hyperf keys a server's ON_REQUEST callback by class, so pointing both the
 * plaintext and the TLS server at Hyperf\HttpServer\Server makes the second
 * replace the first -- it logs "http will be replaced by http-tls" and then
 * neither port answers. A distinct subclass gives the TLS server its own
 * instance, and with it the router routes.php registers under 'http-tls'.
 *
 * No behaviour is added: both ports run the identical route set.
 */
class TlsServer extends Server
{
}
