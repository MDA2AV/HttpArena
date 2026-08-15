#include <drogon/drogon.h>

#include <cstdlib>
#include <fstream>
#include <string>

using namespace drogon;

namespace {

Json::Value gDataset(Json::arrayValue);

void loadDataset()
{
    const char *env = std::getenv("DATASET_PATH");
    std::string path = env ? env : "/data/dataset.json";
    std::ifstream input(path);
    if (!input)
        return;

    Json::CharReaderBuilder builder;
    std::string errors;
    Json::Value parsed;
    if (Json::parseFromStream(builder, input, &parsed, &errors) && parsed.isArray())
        gDataset = parsed;
}

HttpResponsePtr plainText(const std::string &body)
{
    auto resp = HttpResponse::newHttpResponse();
    resp->setContentTypeCode(CT_TEXT_PLAIN);
    resp->setBody(body);
    return resp;
}

long long toLong(const std::string &value)
{
    try
    {
        return std::stoll(value);
    }
    catch (...)
    {
        return 0;
    }
}

}  // namespace

int main()
{
    loadDataset();

    app().registerHandler(
        "/pipeline",
        [](const HttpRequestPtr &, std::function<void(const HttpResponsePtr &)> &&callback) {
            callback(plainText("ok"));
        },
        {Get});

    app().registerHandler(
        "/baseline11",
        [](const HttpRequestPtr &req, std::function<void(const HttpResponsePtr &)> &&callback) {
            long long sum = 0;
            for (const auto &param : req->getParameters())
                sum += toLong(param.second);
            if (req->method() == Post)
                sum += toLong(std::string(req->body()));
            callback(plainText(std::to_string(sum)));
        },
        {Get, Post});

    app().registerHandler(
        "/json/{count}",
        [](const HttpRequestPtr &req,
           std::function<void(const HttpResponsePtr &)> &&callback,
           const std::string &count) {
            int items = static_cast<int>(toLong(count));
            if (items < 0)
                items = 0;
            if (items > static_cast<int>(gDataset.size()))
                items = static_cast<int>(gDataset.size());

            long long m = 1;
            const auto &multiplier = req->getParameter("m");
            if (!multiplier.empty())
                m = toLong(multiplier);

            Json::Value list(Json::arrayValue);
            for (int i = 0; i < items; ++i)
            {
                Json::Value item = gDataset[i];
                item["total"] = static_cast<Json::Int64>(
                    item["price"].asInt64() * item["quantity"].asInt64() * m);
                list.append(std::move(item));
            }

            Json::Value payload;
            payload["items"] = std::move(list);
            payload["count"] = items;
            callback(HttpResponse::newHttpJsonResponse(payload));
        },
        {Get});

    app().registerHandler(
        "/upload",
        [](const HttpRequestPtr &req, std::function<void(const HttpResponsePtr &)> &&callback) {
            callback(plainText(std::to_string(req->body().length())));
        },
        {Post});

    app().setLogLevel(trantor::Logger::kError)
        .addListener("0.0.0.0", 8080)
        .setThreadNum(0)
        .setClientMaxBodySize(30 * 1024 * 1024)
        .setClientMaxMemoryBodySize(30 * 1024 * 1024)
        .run();

    return 0;
}
