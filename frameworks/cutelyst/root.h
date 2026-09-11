#ifndef ROOT_H
#define ROOT_H

#include <Cutelyst/Controller>

#include <QJsonArray>

using namespace Cutelyst;

class Root : public Controller
{
    Q_OBJECT
    C_NAMESPACE("")
public:
    explicit Root(QObject *app);

    C_ATTR(pipeline, :Local :AutoArgs)
    void pipeline(Context *c);

    C_ATTR(baseline11, :Local :AutoArgs)
    void baseline11(Context *c);

    C_ATTR(delay, :Local :AutoArgs)
    void delay(Context *c, const QString &ms);

    C_ATTR(json, :Local :AutoArgs)
    void json(Context *c, const QString &count);

    C_ATTR(echo, :Local :AutoArgs)
    void echo(Context *c);

private:
    QJsonArray m_dataset;
};

#endif
