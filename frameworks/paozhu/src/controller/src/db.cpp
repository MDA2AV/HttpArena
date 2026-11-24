#include "httppeer.h"
#include "orm_query.h"
#include "func.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace
{
    struct fortune_row
    {
        long long id = 0;
        std::string message;
    };

    void respond_db_error(const std::shared_ptr<http::httppeer> &peer, std::string_view message)
    {
        peer->type("text/plain; charset=utf-8");
        peer->status(503);
        peer->output = std::string(message);
    }

    // Binary PG rows: int2/int4/int8/bool arrive as int64_t, oid as uint64_t,
    // float4/float8 as double, numeric as a text view; everything not in the
    // driver's binary-decodable set (text/varchar/jsonb/...) arrives as text.
    long long variant_int(const orm::col_value_variant &value)
    {
        if (const auto *p = std::get_if<int64_t>(&value))
        {
            return static_cast<long long>(*p);
        }
        if (const auto *p = std::get_if<uint64_t>(&value))
        {
            return static_cast<long long>(*p);
        }
        if (const auto *p = std::get_if<double>(&value))
        {
            return static_cast<long long>(*p);
        }
        return 0;
    }

    std::string_view variant_text(const orm::col_value_variant &value)
    {
        if (const auto *p = std::get_if<std::string_view>(&value))
        {
            return *p;
        }
        return {};
    }

    void append_json_string(std::string &out, std::string_view value)
    {
        static const char *hex = "0123456789abcdef";
        out.push_back('"');
        for (unsigned char ch : value)
        {
            switch (ch)
            {
                case '"':  out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\b': out += "\\b"; break;
                case '\f': out += "\\f"; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default:
                    if (ch < 0x20)
                    {
                        out += "\\u00";
                        out.push_back(hex[ch >> 4]);
                        out.push_back(hex[ch & 0x0F]);
                    }
                    else
                    {
                        out.push_back(static_cast<char>(ch));
                    }
            }
        }
        out.push_back('"');
    }

    std::string render_fortunes(std::vector<fortune_row> &rows)
    {
        rows.push_back(fortune_row{0, "Additional fortune added at request time."});
        std::sort(rows.begin(), rows.end(), [](const fortune_row &a, const fortune_row &b) {
            return a.message < b.message;  // std::string::compare is byte-ordinal
        });

        std::string out;
        out.reserve(rows.size() * 140 + 256);
        out += "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Fortunes</title></head>";
        out += "<body><table><tr><th>id</th><th>message</th></tr>";
        for (const fortune_row &r : rows)
        {
            out += "<tr><td>";
            out += std::to_string(r.id);
            out += "</td><td>";
            http::html_escape(out, r.message);
            out += "</td></tr>";
        }
        out += "</table></body></html>";
        return out;
    }
}  // namespace

namespace http
{
//@urlpath(null,async-db)
asio::awaitable<std::string> arena_async_db(std::shared_ptr<httppeer> peer)
{
    peer->type("application/json");

    // get is already parsed from the querystring; const operator[] returns a
    // static nil for an absent key (no insert). to_int() yields 0 for nil, so
    // is_null() preserves the 10/50/50 defaults for absent params.
    const obj_val &g = peer->get;
    const long long min_price = g["min"].is_null() ? 10 : g["min"].to_int();
    const long long max_price = g["max"].is_null() ? 50 : g["max"].to_int();
    long long limit           = g["limit"].is_null() ? 50 : g["limit"].to_int();
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;

    // 预处理：参数绑定，驱动按连接缓存 statement，池化连接跨请求复用 warm 路径。
    // PG 直接用 $n 占位符，框架不再做 ? -> $n 转换。
    const std::string sql = "SELECT id,name,category,price,quantity,active,tags,rating_score,rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
    std::vector<http::obj_val> params;
    params.emplace_back(min_price);
    params.emplace_back(max_price);
    params.emplace_back(limit);

    // 二进制行直接渲染进响应，不再经过 item_row 的 9 次字符串拷贝和二次解析。
    // 列位置按首行 col_names 解析一次；SQL 列序变化或列缺失会置 columns_bad。
    constexpr int kColumnCount = 9;
    int col[kColumnCount]     = {-1, -1, -1, -1, -1, -1, -1, -1, -1};
    bool columns_ready        = false;
    bool columns_bad          = false;
    std::size_t row_count     = 0;
    std::string out;
    out.reserve(static_cast<std::size_t>(limit) * 256 + 64);
    out += "{\"items\":[";

    try
    {
        auto link = std::make_unique<orm::db_conn>("pg");
        co_await link->async_query_prepared_binary(
            sql, params,
            [&](int col_count, char **col_names, std::function<orm::col_value_variant(int)> get_data) -> bool
            {
                if (!columns_ready)
                {
                    static constexpr const char *expect[kColumnCount] = {
                        "id", "name", "category", "price", "quantity",
                        "active", "tags", "rating_score", "rating_count"};
                    if (col_count != kColumnCount)
                    {
                        columns_bad = true;
                        return false;
                    }
                    for (int e = 0; e < kColumnCount; ++e)
                    {
                        for (int i = 0; i < col_count; ++i)
                        {
                            if (col_names[i] != nullptr && std::strcmp(col_names[i], expect[e]) == 0)
                            {
                                col[e] = i;
                                break;
                            }
                        }
                        if (col[e] < 0)
                        {
                            columns_bad = true;
                            return false;
                        }
                    }
                    columns_ready = true;
                }

                if (row_count > 0)
                {
                    out.push_back(',');
                }
                out += "{\"id\":";
                out += std::to_string(variant_int(get_data(col[0])));
                out += ",\"name\":";
                append_json_string(out, variant_text(get_data(col[1])));
                out += ",\"category\":";
                append_json_string(out, variant_text(get_data(col[2])));
                out += ",\"price\":";
                out += std::to_string(variant_int(get_data(col[3])));
                out += ",\"quantity\":";
                out += std::to_string(variant_int(get_data(col[4])));
                out += ",\"active\":";
                out += variant_int(get_data(col[5])) != 0 ? "true" : "false";
                out += ",\"tags\":";
                // jsonb arrives as a JSON array in text form; keep it verbatim.
                const std::string_view tags = variant_text(get_data(col[6]));
                if (tags.size() > 1 && tags.front() == '[' && tags.back() == ']')
                {
                    out += tags;
                }
                else
                {
                    out += "[]";
                }
                out += ",\"rating\":{\"score\":";
                out += std::to_string(variant_int(get_data(col[7])));
                out += ",\"count\":";
                out += std::to_string(variant_int(get_data(col[8])));
                out += "}}";
                ++row_count;
                return true;
            });

        if (columns_bad || link->iserror || !link->error_msg.empty())
        {
            respond_db_error(peer, "database query failed");
            co_return "";
        }
    }
    catch (const std::exception &)
    {
        respond_db_error(peer, "database query failed");
        co_return "";
    }

    out += "],\"count\":";
    out += std::to_string(row_count);
    out.push_back('}');
    peer->output = std::move(out);
    co_return "";
}

//@urlpath(null,fortunes)
asio::awaitable<std::string> arena_fortunes(std::shared_ptr<httppeer> peer)
{
    peer->type("text/html; charset=utf-8");

    // 201 = 200 seeded rows + the runtime row appended by render_fortunes().
    // The seed is this repo's own: 12 TechEmpower rows plus
    // generate_series(13,200) in data/pgdb-seed.sql, not the 12-row TE
    // contract; reserve() only sets capacity either way.
    std::vector<fortune_row> rows;
    rows.reserve(201);
    try
    {
        auto link = std::make_unique<orm::db_conn>("pg");
        co_await link->async_query_prepared_binary(
            "SELECT id,message FROM fortune", {},
            [&rows](int col_count, char **, auto get_data) -> bool
            {
                if (col_count < 2)
                {
                    return false;
                }
                fortune_row row;
                row.id = variant_int(get_data(0));
                row.message.assign(variant_text(get_data(1)));
                rows.push_back(std::move(row));
                return true;
            });
        if (link->iserror || !link->error_msg.empty())
        {
            respond_db_error(peer, "database query failed");
            co_return "";
        }
    }
    catch (const std::exception &)
    {
        respond_db_error(peer, "database query failed");
        co_return "";
    }
    if (rows.empty())
    {
        respond_db_error(peer, "fortune table is empty");
        co_return "";
    }

    peer->output = render_fortunes(rows);
    co_return "";
}
}  // namespace http
