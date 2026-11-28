#include "httppeer.h"

#include <asio/steady_timer.hpp>
#include <asio/this_coro.hpp>
#include <asio/use_awaitable.hpp>

#include <sys/stat.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

// HttpArena handlers for the paozhu clean scaffold.
//
// Routes are picked up by paozhu_pre at build time: every //@urlpath(...)
// annotation registers the function that follows it. Path parameters must be
// the last segment, so /json/:count, /static/:filename and /delay/:ms are
// registered as the fixed prefixes /json, /static and /delay with a
// parameter-name table.
namespace
{

struct arena_item
{
    long long id            = 0;
    long long price         = 0;
    long long quantity      = 0;
    long long score         = 0;
    long long rating_count  = 0;
    bool active             = false;
    // Raw bytes between the source quotes. Re-emitting them verbatim keeps any
    // JSON escape sequence in the dataset intact.
    std::string name;
    std::string category;
    std::vector<std::string> tags;
};

// A small scanner scoped to data/dataset.json's shape. Containers are skipped by
// structure rather than by searching for the next key, so a string that looks
// like a key cannot desynchronize the parse.
struct json_scanner
{
    const char *p = nullptr;
    const char *e = nullptr;
    bool ok       = true;

    void ws()
    {
        while (p < e && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n'))
        {
            ++p;
        }
    }

    std::string str()
    {
        if (p >= e || *p != '"')
        {
            ok = false;
            return {};
        }
        ++p;
        const char *begin = p;
        while (p < e && *p != '"')
        {
            if (*p == '\\' && p + 1 < e)
            {
                ++p;
            }
            ++p;
        }
        if (p >= e)
        {
            ok = false;
            return {};
        }
        std::string out(begin, static_cast<std::size_t>(p - begin));
        ++p;
        return out;
    }

    long long num()
    {
        ws();
        bool neg = false;
        if (p < e && *p == '-')
        {
            neg = true;
            ++p;
        }
        long long n = 0;
        while (p < e && *p >= '0' && *p <= '9')
        {
            n = n * 10 + (*p - '0');
            ++p;
        }
        return neg ? -n : n;
    }

    void skip_value()
    {
        ws();
        if (p >= e)
        {
            ok = false;
            return;
        }
        if (*p == '"')
        {
            str();
            return;
        }
        if (*p == '{' || *p == '[')
        {
            const char close = (*p == '{') ? '}' : ']';
            ++p;
            while (ok && p < e)
            {
                ws();
                if (p >= e)
                {
                    break;
                }
                if (*p == close)
                {
                    ++p;
                    return;
                }
                if (*p == ',')
                {
                    ++p;
                    continue;
                }
                if (close == '}')
                {
                    str();
                    ws();
                    if (!ok || p >= e || *p != ':')
                    {
                        ok = false;
                        return;
                    }
                    ++p;
                }
                skip_value();
            }
            ok = false;
            return;
        }
        while (p < e && *p != ',' && *p != '}' && *p != ']' &&
               *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n')
        {
            ++p;
        }
    }

    bool parse_item(arena_item &it)
    {
        if (p >= e || *p != '{')
        {
            ok = false;
            return false;
        }
        ++p;
        while (ok && p < e)
        {
            ws();
            if (p >= e)
            {
                ok = false;
                break;
            }
            if (*p == '}')
            {
                ++p;
                return ok;
            }
            if (*p == ',')
            {
                ++p;
                continue;
            }

            std::string key = str();
            ws();
            if (!ok || p >= e || *p != ':')
            {
                ok = false;
                break;
            }
            ++p;
            ws();

            if (key == "id")
            {
                it.id = num();
            }
            else if (key == "price")
            {
                it.price = num();
            }
            else if (key == "quantity")
            {
                it.quantity = num();
            }
            else if (key == "name")
            {
                it.name = str();
            }
            else if (key == "category")
            {
                it.category = str();
            }
            else if (key == "active")
            {
                it.active = (p < e && *p == 't');
                skip_value();
            }
            else if (key == "tags")
            {
                if (p >= e || *p != '[')
                {
                    ok = false;
                    break;
                }
                ++p;
                while (ok && p < e)
                {
                    ws();
                    if (p >= e)
                    {
                        break;
                    }
                    if (*p == ']')
                    {
                        ++p;
                        break;
                    }
                    if (*p == ',')
                    {
                        ++p;
                        continue;
                    }
                    std::string tag = str();
                    if (!ok)
                    {
                        break;
                    }
                    it.tags.emplace_back(std::move(tag));
                }
            }
            else if (key == "rating")
            {
                if (p >= e || *p != '{')
                {
                    ok = false;
                    break;
                }
                ++p;
                while (ok && p < e)
                {
                    ws();
                    if (p >= e)
                    {
                        break;
                    }
                    if (*p == '}')
                    {
                        ++p;
                        break;
                    }
                    if (*p == ',')
                    {
                        ++p;
                        continue;
                    }
                    std::string rkey = str();
                    ws();
                    if (!ok || p >= e || *p != ':')
                    {
                        ok = false;
                        break;
                    }
                    ++p;
                    ws();
                    if (rkey == "score")
                    {
                        it.score = num();
                    }
                    else if (rkey == "count")
                    {
                        it.rating_count = num();
                    }
                    else
                    {
                        skip_value();
                    }
                }
            }
            else
            {
                skip_value();
            }
        }
        if (p >= e)
        {
            ok = false;
        }
        return ok;
    }
};

std::vector<arena_item> load_dataset()
{
    std::ifstream in("/data/dataset.json", std::ios::binary);
    if (!in)
    {
        return {};
    }
    const std::string raw((std::istreambuf_iterator<char>(in)),
                          std::istreambuf_iterator<char>());
    json_scanner sc{raw.data(), raw.data() + raw.size()};
    sc.ws();
    if (sc.p >= sc.e || *sc.p != '[')
    {
        return {};
    }
    ++sc.p;

    std::vector<arena_item> items;
    while (sc.ok && sc.p < sc.e)
    {
        sc.ws();
        if (sc.p >= sc.e || *sc.p == ']')
        {
            break;
        }
        if (*sc.p == ',')
        {
            ++sc.p;
            continue;
        }
        if (*sc.p != '{')
        {
            sc.ok = false;
            break;
        }
        arena_item it;
        if (!sc.parse_item(it))
        {
            break;
        }
        items.emplace_back(std::move(it));
    }
    return sc.ok ? items : std::vector<arena_item>{};
}

const std::vector<arena_item> &dataset()
{
    // Function-local static: initialized once, thread-safe under C++11+.
    static const std::vector<arena_item> items = load_dataset();
    return items;
}

void render_json(std::string &out, std::size_t count, long long multiplier,
                 const std::vector<arena_item> &items)
{
    out.clear();
    out.reserve(32 + count * 256);
    out += "{\"items\":[";
    for (std::size_t i = 0; i < count; ++i)
    {
        const arena_item &it = items[i];
        if (i != 0)
        {
            out += ',';
        }
        out += "{\"id\":";
        out += std::to_string(it.id);
        out += ",\"name\":\"";
        out += it.name;
        out += "\",\"category\":\"";
        out += it.category;
        out += "\",\"price\":";
        out += std::to_string(it.price);
        out += ",\"quantity\":";
        out += std::to_string(it.quantity);
        out += ",\"active\":";
        out += it.active ? "true" : "false";
        out += ",\"tags\":[";
        for (std::size_t t = 0; t < it.tags.size(); ++t)
        {
            if (t != 0)
            {
                out += ',';
            }
            out += '"';
            out += it.tags[t];
            out += '"';
        }
        out += "],\"rating\":{\"score\":";
        out += std::to_string(it.score);
        out += ",\"count\":";
        out += std::to_string(it.rating_count);
        out += "},\"total\":";
        out += std::to_string(it.price * it.quantity * multiplier);
        out += '}';
    }
    out += "],\"count\":";
    out += std::to_string(count);
    out += '}';
}

long long body_number(const std::string &body)
{
    char buf[32];
    const std::size_t n = body.size() < sizeof(buf) - 1 ? body.size() : sizeof(buf) - 1;
    for (std::size_t i = 0; i < n; ++i)
    {
        buf[i] = body[i];
    }
    buf[n] = '\0';
    const char *p = buf;
    while (*p != '\0' && static_cast<unsigned char>(*p) <= ' ')
    {
        ++p;
    }
    char *end = nullptr;
    const long long value = std::strtoll(p, &end, 10);
    return end == p ? 0 : value;
}

// Raw (non-form, non-JSON) request bodies stay in peer->rawcontent while they
// fit in CONST_HTTP_RAW_POST_SIZE (2 MB, http_parse.cpp posttype 5); only larger
// ones are spilled to a temp file. Return the in-memory bytes when present,
// otherwise read the spilled file and unlink it right away. The benchmark's POST
// bodies are a few bytes, so the file branch is the >2 MB case.
std::string raw_body(const std::shared_ptr<http::httppeer> &peer)
{
    if (!peer->rawcontent.empty())
    {
        return peer->rawcontent;
    }
    const std::string path = peer->files["rawcontent"]["tempfile"].to_string();
    if (path.empty())
    {
        return {};
    }
    std::ifstream in(path, std::ios::binary);
    const std::string body((std::istreambuf_iterator<char>(in)),
                           std::istreambuf_iterator<char>());
    std::remove(path.c_str());
    return body;
}

const char *mime_of(const std::string &filename)
{
    const std::size_t dot = filename.rfind('.');
    if (dot == std::string::npos)
    {
        return "application/octet-stream";
    }
    const std::string ext = filename.substr(dot + 1);
    if (ext == "css")  return "text/css";
    if (ext == "js")   return "application/javascript";
    if (ext == "html") return "text/html";
    if (ext == "json") return "application/json";
    if (ext == "svg")  return "image/svg+xml";
    if (ext == "webp") return "image/webp";
    if (ext == "woff2") return "font/woff2";
    return "application/octet-stream";
}

bool safe_filename(const std::string &name)
{
    if (name.empty() || name.size() > 128 || name.find("..") != std::string::npos)
    {
        return false;
    }
    for (char c : name)
    {
        const bool allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                             (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
        if (!allowed)
        {
            return false;
        }
    }
    return true;
}

// 整文件读入内存；不存在 / 非普通文件 / 读失败返回 false。
static bool read_whole_file(const std::string &path, std::string &body)
{
    struct stat st {};
    if (::stat(path.c_str(), &st) != 0 || (st.st_mode & S_IFREG) == 0)
    {
        return false;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in.is_open())
    {
        return false;
    }
    body.resize(static_cast<std::size_t>(st.st_size));
    in.read(&body[0], static_cast<std::streamsize>(st.st_size));
    body.resize(static_cast<std::size_t>(in.gcount()));
    return true;
}

// 只有文本类型存在预压缩变体（与压测脚本的预压缩范围一致）。
static bool is_compressible_ext(const std::string &filename)
{
    const std::size_t dot = filename.rfind('.');
    if (dot == std::string::npos)
    {
        return false;
    }
    const std::string ext = filename.substr(dot + 1);
    return ext == "css" || ext == "js" || ext == "html" || ext == "json" || ext == "svg";
}

}  // namespace

namespace http
{

//@urlpath(null,pipeline)
asio::awaitable<std::string> arena_pipeline(std::shared_ptr<httppeer> peer)
{
    peer->type("text/plain");
    peer->output = "ok";
    co_return "";
}

//@urlpath(null,echo)
asio::awaitable<std::string> arena_echo(std::shared_ptr<httppeer> peer)
{
    // Echo the raw request body byte-for-byte (8gbit profile). raw_body covers
    // both the in-memory fast path and the >2MB spilled file; chunked framing is
    // decoded by the parser into rawcontent. An empty body echoes as 200 empty.
    peer->type("application/octet-stream");
    peer->output = raw_body(peer);
    co_return "";
}

// HttpArena protocol-compliance route (h1/h2 suites).
// GET/HEAD: fixed text body >= 5 bytes (h2spec skips a flow-control test below 5).
// POST: byte-for-byte raw body echo, through the same parser API as /echo.
// OPTIONS: 200 with Allow; the core closes the connection if a body was sent
// rather than leave unread bytes that could be parsed as a second request.
//@urlpath(null,spec)
asio::awaitable<std::string> arena_spec(std::shared_ptr<httppeer> peer)
{
    peer->status(200);
    if (peer->method == static_cast<unsigned char>(HEAD_METHOD::HEAD) ||
        peer->method == static_cast<unsigned char>(HEAD_METHOD::GET))
    {
        peer->type("text/plain");
        peer->output = "spec ok";
    }
    else if (peer->method == static_cast<unsigned char>(HEAD_METHOD::POST))
    {
        peer->type("application/octet-stream");
        peer->output = raw_body(peer);
    }
    else if (peer->method == static_cast<unsigned char>(HEAD_METHOD::OPTIONS))
    {
        peer->set_header("Allow", "GET, HEAD, POST, OPTIONS");
        peer->type("text/plain");
        peer->output.clear();
    }
    co_return "";
}

// Header echo: one `Name: Value` line per received header, in any order/case.
// Read the body even though it is discarded, so POST bodies go through the
// normal parser path and any >2MB spilled temp file is cleaned up.
//@urlpath(null,spec/headers)
asio::awaitable<std::string> arena_spec_headers(std::shared_ptr<httppeer> peer)
{
    raw_body(peer);
    peer->status(200);
    peer->type("text/plain");
    std::string out;
    for (const auto &kv : peer->header)
    {
        out += kv.first;
        out += ": ";
        out += kv.second;
        out.push_back('\n');
    }
    peer->output = std::move(out);
    co_return "";
}

//@urlpath(null,baseline11)
asio::awaitable<std::string> arena_baseline11(std::shared_ptr<httppeer> peer)
{
    // get is parsed from the querystring at request time; sum every value.
    // is_object() guards as_object(), which would otherwise allocate on NIL.
    long long sum = 0;
    if (peer->get.is_object())
    {
        for (const auto &kv : peer->get.as_object())
        {
            sum += kv.second.to_int();
        }
    }
    if (peer->method == POST)
    {
        sum += body_number(raw_body(peer));
    }
    peer->type("text/plain");
    peer->output = std::to_string(sum);
    co_return "";
}

//@urlpath(null,baseline2)
asio::awaitable<std::string> arena_baseline2(std::shared_ptr<httppeer> peer)
{
    long long sum = 0;
    if (peer->get.is_object())
    {
        for (const auto &kv : peer->get.as_object())
        {
            sum += kv.second.to_int();
        }
    }
    peer->type("text/plain");
    peer->output = std::to_string(sum);
    co_return "";
}

//@urlpath(null,json/:count)
asio::awaitable<std::string> arena_json(std::shared_ptr<httppeer> peer)
{
    const std::vector<arena_item> &items = dataset();
    const long long count      = peer->get["count"].to_int();
    const obj_val &g           = peer->get;
    const long long multiplier = g["m"].is_null() ? 1 : g["m"].to_int();

    peer->type("application/json");
    if (items.empty() || count < 1 || count > static_cast<long long>(items.size()))
    {
        peer->status(400);
        peer->output = "{}";
        co_return "";
    }
    render_json(peer->output, static_cast<std::size_t>(count), multiplier, items);
    co_return "";
}

//@urlpath(null,static/:filename)
asio::awaitable<std::string> arena_static(std::shared_ptr<httppeer> peer)
{
    const std::string filename = peer->get["filename"].to_string();
    if (!safe_filename(filename))
    {
        peer->status(404);
        peer->type("text/plain");
        peer->output = "Not Found";
        co_return "";
    }

    // 每请求直接读盘：文件小，预热后全在 page cache，没有真实
    // 磁盘 IO；无缓存、无锁，磁盘改动即时生效。
    // 原始文件必须存在，再按客户端偏好 br → gz → 源文件依次尝试。
    const std::string base = "/data/static/" + filename;
    struct stat base_stat {};
    if (::stat(base.c_str(), &base_stat) != 0 || (base_stat.st_mode & S_IFREG) == 0)
    {
        peer->status(404);
        peer->type("text/plain");
        peer->output = "Not Found";
        co_return "";
    }

    unsigned char enc   = 0;
    bool served         = false;
    if (is_compressible_ext(filename))
    {
        if (peer->state.br && read_whole_file(base + ".br", peer->output))
        {
            enc    = 2;
            served = true;
        }
        if (!served && peer->state.gzip && read_whole_file(base + ".gz", peer->output))
        {
            enc    = 1;
            served = true;
        }
    }
    if (!served && read_whole_file(base, peer->output))
    {
        served = true;
    }
    if (!served)
    {
        peer->status(404);
        peer->type("text/plain");
        peer->output = "Not Found";
        co_return "";
    }
    peer->type(mime_of(filename));
    peer->compress = enc;
    peer->length(peer->output.size());
    co_return "";
}

//@urlpath(null,delay/:ms)
asio::awaitable<std::string> arena_delay(std::shared_ptr<httppeer> peer)
{
    // Echo the raw path parameter: /delay/0 must answer "0", not a default.
    const std::string text = peer->get["ms"].to_string();
    char *end              = nullptr;
    const long long asked  = std::strtoll(text.c_str(), &end, 10);
    long long ms           = (end == text.c_str() || asked < 0) ? 0 : asked;
    if (ms > 5000)
    {
        ms = 5000;
    }

    // One timer per request, suspended on the coroutine's own executor. The
    // async profile holds 32K connections, so a blocking sleep here would
    // exhaust the io threads long before the first response is written.
    if (ms > 0)
    {
        auto executor       = co_await asio::this_coro::executor;
        asio::steady_timer timer(executor);
        timer.expires_after(std::chrono::milliseconds(ms));
        co_await timer.async_wait(asio::use_awaitable);
    }

    peer->type("text/plain");
    peer->output = text;
    co_return "";
}

}  // namespace http
