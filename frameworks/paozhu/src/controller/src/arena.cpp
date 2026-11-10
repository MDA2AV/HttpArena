#include "httppeer.h"

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
// the last segment, so /json/:count and /static/:filename are registered as the
// fixed prefixes /json and /static with a parameter-name table.
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

std::string render_json(std::size_t count, long long multiplier,
                        const std::vector<arena_item> &items)
{
    std::string out;
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
    return out;
}

// Split "a=1&b=2" without decoding: the harness sends plain decimal values.
// Returns false once the segment is exhausted.
bool next_query_pair(const std::string &q, std::size_t &pos,
                     std::string &key, std::string &value)
{
    if (pos >= q.size())
    {
        return false;
    }
    if (q[pos] == '?' || q[pos] == '&')
    {
        ++pos;
    }
    const std::size_t amp = q.find('&', pos);
    const std::size_t end = (amp == std::string::npos) ? q.size() : amp;
    const std::size_t eq  = q.find('=', pos);
    if (eq != std::string::npos && eq < end)
    {
        key   = q.substr(pos, eq - pos);
        value = q.substr(eq + 1, end - eq - 1);
    }
    else
    {
        key   = q.substr(pos, end - pos);
        value.clear();
    }
    pos = end + 1;
    return true;
}

long long sum_query(const std::string &q)
{
    long long sum = 0;
    std::size_t pos = 0;
    std::string key, value;
    while (next_query_pair(q, pos, key, value))
    {
        if (value.empty())
        {
            continue;
        }
        char *end = nullptr;
        const long long n = std::strtoll(value.c_str(), &end, 10);
        if (end != value.c_str())
        {
            sum += n;
        }
    }
    return sum;
}

long long query_multiplier(const std::string &q)
{
    long long multiplier = 1;
    std::size_t pos = 0;
    std::string key, value;
    while (next_query_pair(q, pos, key, value))
    {
        if (key == "m" && !value.empty())
        {
            char *end = nullptr;
            const long long n = std::strtoll(value.c_str(), &end, 10);
            if (end != value.c_str())
            {
                multiplier = n;
            }
            break;
        }
    }
    return multiplier;
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

//@urlpath(null,baseline11)
asio::awaitable<std::string> arena_baseline11(std::shared_ptr<httppeer> peer)
{
    long long sum = sum_query(peer->querystring);
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
    peer->type("text/plain");
    peer->output = std::to_string(sum_query(peer->querystring));
    co_return "";
}

//@urlpath(null,json/:count)
asio::awaitable<std::string> arena_json(std::shared_ptr<httppeer> peer)
{
    const std::vector<arena_item> &items = dataset();
    const long long count      = peer->get["count"].to_int();
    const long long multiplier = query_multiplier(peer->querystring);

    peer->type("application/json");
    if (items.empty() || count < 1 || count > static_cast<long long>(items.size()))
    {
        peer->status(400);
        peer->output = "{}";
        co_return "";
    }
    peer->output = render_json(static_cast<std::size_t>(count), multiplier, items);
    co_return "";
}

//@urlpath(null,static/:filename)
asio::awaitable<std::string> arena_static(std::shared_ptr<httppeer> peer)
{
    const std::string filename = peer->get["filename"].to_string();
    // Read on every request: the validation suite replaces a mounted file and
    // expects the next response to carry the new bytes.
    std::ifstream in;
    if (safe_filename(filename))
    {
        in.open("/data/static/" + filename, std::ios::binary);
    }
    // is_open(), not operator bool(): a default-constructed ifstream has a
    // goodbit state even though no file is attached, so a rejected filename
    // would otherwise fall through to a 200 with an empty body.
    if (!in.is_open())
    {
        peer->status(404);
        peer->type("text/plain");
        peer->output = "Not Found";
        co_return "";
    }
    // Size the body once, then read straight into peer->output: no per-byte
    // iterator and no second copy. Still one open + one read per request.
    const std::streampos end = in.seekg(0, std::ios::end).tellg();
    const std::streamsize size = end < 0 ? 0 : static_cast<std::streamsize>(end);
    peer->output.resize(static_cast<std::size_t>(size));
    in.seekg(0, std::ios::beg);
    if (size > 0 && !in.read(&peer->output[0], size))
    {
        // Short read (file shrank between sizing and reading): keep what arrived.
        peer->output.resize(static_cast<std::size_t>(in.gcount()));
    }
    peer->type(mime_of(filename));
    co_return "";
}

}  // namespace http
