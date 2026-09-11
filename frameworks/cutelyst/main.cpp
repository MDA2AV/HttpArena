#include "app.h"

#include <Cutelyst/Server/server.h>

#include <QCoreApplication>
#include <QFile>

using namespace Qt::StringLiterals;

int main(int argc, char *argv[])
{
    // Server must be constructed before QCoreApplication on Linux (EPoll loop).
    Cutelyst::Server server;

    QCoreApplication app(argc, argv);

    server.setHttpSocket({u":8080"_s});
    server.setThreads(u"auto"_s);
    server.setReusePort(true);
    server.setSocketTimeout(0);
    // Validation posts up to 100 KB chunked bodies on /echo.
    server.setBufferSize(128 * 1024);
    server.setPostBuffering(2 * 1024 * 1024);
    server.setPostBufferingBufsize(128 * 1024);

    const QString certFile = u"/certs/server.crt"_s;
    const QString keyFile = u"/certs/server.key"_s;
    if (QFile::exists(certFile) && QFile::exists(keyFile)) {
        // ALPN stays HTTP/1.1 only (httpsH2 defaults to false) for :8081 profiles.
        server.setHttpsSocket({u":8081,%1,%2"_s.arg(certFile, keyFile)});
    }

    return server.exec(new ArenaApp);
}
