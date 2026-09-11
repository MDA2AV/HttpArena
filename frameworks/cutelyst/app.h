#ifndef APP_H
#define APP_H

#include <Cutelyst/Application>

class ArenaApp : public Cutelyst::Application
{
    Q_OBJECT
    CUTELYST_APPLICATION(IID "org.cutelyst.HttpArena")
public:
    Q_INVOKABLE explicit ArenaApp(QObject *parent = nullptr);
    ~ArenaApp() override = default;

    bool init() override;
};

#endif
