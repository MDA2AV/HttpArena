#include "app.h"

#include "root.h"

#include <Cutelyst/Plugins/View/Cutelee/cuteleeview.h>

#include <acoroexpected.h>
#include <adatabase.h>
#include <apg.h>
#include <apool.h>

#include <QCoreApplication>
#include <QDir>
#include <QThread>

#include <cstdlib>

using namespace ASql;
using namespace Cutelyst;
using namespace Qt::StringLiterals;

ArenaApp::ArenaApp(QObject *parent)
    : Cutelyst::Application(parent)
{
    QCoreApplication::setApplicationName(u"HttpArena-Cutelyst"_s);
}

bool ArenaApp::init()
{
    auto *view = new CuteleeView(this);
    const char *env = std::getenv("CUTELEE_INCLUDE_PATH");
    const QString includePath = env ? QString::fromLocal8Bit(env) : u"/templates"_s;
    view->setIncludePaths({includePath, QDir::currentPath()});
    view->preloadTemplates();

    new Root(this);
    return true;
}

bool ArenaApp::postFork()
{
    // ASql pools are thread_local; each Cutelyst::Server worker thread gets its own pool.
    const char *url = std::getenv("DATABASE_URL");
    if (!url || !*url) {
        return true;
    }

    int maxConn = 256;
    if (const char *env = std::getenv("DATABASE_MAX_CONN")) {
        bool ok = false;
        const int parsed = QByteArray(env).toInt(&ok);
        if (ok && parsed > 0) {
            maxConn = parsed;
        }
    }

    const int threads = qMax(1, QThread::idealThreadCount());
    const int perThread = qMax(1, qMin(maxConn, 240) / threads);

    APool::create(APg::factory(QString::fromUtf8(url)));
    APool::setMaxIdleConnections(perThread);
    APool::setMaxConnections(perThread);
    APool::setSetupHook([](ADatabase db) -> ACoroTerminator {
        db.enterPipelineMode(std::chrono::milliseconds{500});
        co_return;
    });

    return true;
}
