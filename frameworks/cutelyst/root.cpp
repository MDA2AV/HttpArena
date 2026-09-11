#include "root.h"

#include <Cutelyst/Context>
#include <Cutelyst/Request>
#include <Cutelyst/Response>

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>

#include <cstdlib>

using namespace Qt::StringLiterals;

namespace {

qint64 toLong(const QString &value)
{
    bool ok = false;
    const qint64 n = value.toLongLong(&ok);
    return ok ? n : 0;
}

qint64 toLong(const QByteArray &value)
{
    bool ok = false;
    const qint64 n = value.toLongLong(&ok);
    return ok ? n : 0;
}

} // namespace

Root::Root(QObject *app)
    : Controller(app)
{
    const char *env = std::getenv("DATASET_PATH");
    const QString path = env ? QString::fromLocal8Bit(env) : u"/data/dataset.json"_s;

    QFile file(path);
    if (file.open(QIODevice::ReadOnly)) {
        const QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
        if (doc.isArray()) {
            m_dataset = doc.array();
        }
    }
}

void Root::pipeline(Context *c)
{
    c->res()->setContentType("text/plain"_ba);
    c->res()->setBody("ok"_ba);
}

void Root::baseline11(Context *c)
{
    qint64 sum = 0;
    const ParamsMultiMap params = c->req()->queryParameters();
    for (auto it = params.cbegin(); it != params.cend(); ++it) {
        sum += toLong(it.value());
    }

    if (c->req()->method() == "POST"_ba) {
        if (QIODevice *body = c->req()->body()) {
            sum += toLong(body->readAll());
        }
    }

    c->res()->setContentType("text/plain"_ba);
    c->res()->setBody(QByteArray::number(sum));
}

void Root::delay(Context *c, const QString &ms)
{
    const int millis = static_cast<int>(toLong(ms));
    const QByteArray body = QByteArray::number(millis);

    if (millis <= 0) {
        c->res()->setContentType("text/plain"_ba);
        c->res()->setBody(body);
        return;
    }

    ASync async(c);
    QTimer::singleShot(millis, c, [async, c, body] {
        c->res()->setContentType("text/plain"_ba);
        c->res()->setBody(body);
    });
}

void Root::json(Context *c, const QString &count)
{
    int items = static_cast<int>(toLong(count));
    if (items < 0) {
        items = 0;
    }
    if (items > m_dataset.size()) {
        items = m_dataset.size();
    }

    const qint64 m = toLong(c->req()->queryParam(u"m"_s, u"1"_s));

    QJsonArray list;
    for (int i = 0; i < items; ++i) {
        QJsonObject item = m_dataset.at(i).toObject();
        const qint64 price = item.value(u"price"_s).toVariant().toLongLong();
        const qint64 quantity = item.value(u"quantity"_s).toVariant().toLongLong();
        item.insert(u"total"_s, price * quantity * m);
        list.append(item);
    }

    QJsonObject payload;
    payload.insert(u"items"_s, list);
    payload.insert(u"count"_s, items);
    c->res()->setJsonObjectBody(payload);
}

void Root::echo(Context *c)
{
    QByteArray data;
    if (QIODevice *body = c->req()->body()) {
        data = body->readAll();
    }
    c->res()->setContentType("application/octet-stream"_ba);
    c->res()->setBody(data);
}
