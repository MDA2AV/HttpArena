#include "app.h"

#include "root.h"

#include <QCoreApplication>

using namespace Qt::StringLiterals;

ArenaApp::ArenaApp(QObject *parent)
    : Cutelyst::Application(parent)
{
    QCoreApplication::setApplicationName(u"HttpArena-Cutelyst"_s);
}

bool ArenaApp::init()
{
    new Root(this);
    return true;
}
