#include "root.h"

#include <Cutelyst/Context>
#include <Cutelyst/Request>
#include <Cutelyst/Response>
#include <Cutelyst/View>

#include <acoroexpected.h>
#include <apool.h>
#include <apreparedquery.h>
#include <aresult.h>

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

#include <algorithm>
#include <cstdlib>

using namespace ASql;
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

int queryInt(Context *c, const QString &key, int defaultValue)
{
    const QString raw = c->req()->queryParam(key);
    if (raw.isEmpty()) {
        return defaultValue;
    }
    bool ok = false;
    const int n = raw.toInt(&ok);
    return ok ? n : defaultValue;
}

void emptyAsyncDb(Context *c)
{
    c->res()->setJsonObjectBody({
        {u"items"_s, QJsonArray{}},
        {u"count"_s, 0},
    });
}

ACoroTerminator runAsyncDb(Context *c, ASync async, int min, int max, int limit)
{
    Q_UNUSED(async);

    auto result = co_await APool::exec(
        APreparedQueryLiteral(
            u"SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count "
            u"FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3"),
        QVariantList{min, max, limit},
        c);

    if (!result) {
        emptyAsyncDb(c);
        co_return;
    }

    QJsonArray items;
    for (const auto &row : *result) {
        QJsonObject item;
        item.insert(u"id"_s, row[0].toInt());
        item.insert(u"name"_s, row[1].toString());
        item.insert(u"category"_s, row[2].toString());
        item.insert(u"price"_s, row[3].toInt());
        item.insert(u"quantity"_s, row[4].toInt());
        item.insert(u"active"_s, row[5].toBool());
        item.insert(u"tags"_s, row[6].toJsonValue());
        item.insert(u"rating"_s,
                    QJsonObject{
                        {u"score"_s, row[7].toInt()},
                        {u"count"_s, row[8].toInt()},
                    });
        items.append(item);
    }

    c->res()->setJsonObjectBody({
        {u"items"_s, items},
        {u"count"_s, items.size()},
    });
}

struct FortuneRow {
    int id = 0;
    QString message;
};

ACoroTerminator runFortunes(Context *c, ASync async)
{
    Q_UNUSED(async);

    auto result = co_await APool::exec(
        APreparedQueryLiteral(u"SELECT id, message FROM fortune"), c);

    if (!result) {
        c->res()->setStatus(Response::InternalServerError);
        co_return;
    }

    QVector<FortuneRow> rows;
    rows.reserve(result->size() + 1);
    for (const auto &row : *result) {
        rows.append(FortuneRow{row[0].toInt(), row[1].toString()});
    }
    rows.append(FortuneRow{0, u"Additional fortune added at request time."_s});

    std::sort(rows.begin(), rows.end(), [](const FortuneRow &a, const FortuneRow &b) {
        return a.message < b.message;
    });

    QVariantList fortunes;
    fortunes.reserve(rows.size());
    for (const FortuneRow &row : rows) {
        fortunes.append(QVariantMap{
            {u"id"_s, row.id},
            {u"message"_s, row.message},
        });
    }

    c->setStash(u"template"_s, u"fortunes.html"_s);
    c->setStash(u"fortunes"_s, fortunes);

    if (View *view = c->view()) {
        view->execute(c);
    }
    c->response()->setContentType("text/html; charset=utf-8"_ba);
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

void Root::async_db(Context *c)
{
    int min = queryInt(c, u"min"_s, 10);
    int max = queryInt(c, u"max"_s, 50);
    int limit = queryInt(c, u"limit"_s, 50);
    if (limit < 1) {
        limit = 1;
    } else if (limit > 50) {
        limit = 50;
    }

    runAsyncDb(c, ASync(c), min, max, limit);
}

void Root::fortunes(Context *c)
{
    runFortunes(c, ASync(c));
}
