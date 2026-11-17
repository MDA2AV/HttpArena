#include "httppeer.h"
#include "orm_query.h"

#include <algorithm>
#include <charconv>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace
{
    // paozhu's Postgres driver hands every column back as text. Supplying a
    // `set_val` row type is enough for orm::db_conn::async_query() — no
    // generated ORM model is needed (mini_project.sh empties orm/ + models/).
    struct item_row
    {
        std::string id, name, category, price, quantity, active, tags, rating_score, rating_count;

        void set_val(const std::string &col, const unsigned char *data, std::size_t len, unsigned char)
        {
            std::string value(reinterpret_cast<const char *>(data), len);
            if (col == "id")                 { id = std::move(value); }
            else if (col == "name")         { name = std::move(value); }
            else if (col == "category")     { category = std::move(value); }
            else if (col == "price")        { price = std::move(value); }
            else if (col == "quantity")     { quantity = std::move(value); }
            else if (col == "active")       { active = std::move(value); }
            else if (col == "tags")         { tags = std::move(value); }
            else if (col == "rating_score") { rating_score = std::move(value); }
            else if (col == "rating_count") { rating_count = std::move(value); }
        }
    };

    struct fortune_row
    {
        long long id = 0;
        std::string message;

        void set_val(const std::string &col, const unsigned char *data, std::size_t len, unsigned char)
        {
            std::string value(reinterpret_cast<const char *>(data), len);
            if (col == "id")
            {
                long long parsed = 0;
                std::from_chars(value.data(), value.data() + value.size(), parsed);
                id = parsed;
            }
            else if (col == "message")
            {
                message = std::move(value);
            }
        }
    };

    void respond_db_error(const std::shared_ptr<http::httppeer> &peer, std::string_view message)
    {
        peer->type("text/plain; charset=utf-8");
        peer->status(503);
        peer->output = std::string(message);
    }

    // Both DB routes query through orm::db_conn("pg")->async_query() inline.
    // The process-wide ceiling under Postgres' max_connections is the ORM
    // select pool itself: entrypoint.sh renders its maxpool to
    // DATABASE_MAX_CONN - 24, and async_get_pg_select_conn() parks (woken on
    // connection return) once that quota is full, so no separate gate is needed.
    // pg_async_query_vec_impl() catches driver exceptions into error_msg and
    // returns 0 rows, so a legitimate empty result is not an error;
    // iserror / error_msg are the failure signal (503 via respond_db_error).

    long long to_int(std::string_view value, long long fallback = 0)
    {
        long long parsed = 0;
        auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
        return result.ec == std::errc{} ? parsed : fallback;
    }

    std::string integer_or_zero(const std::string &value)
    {
        return std::to_string(to_int(value));
    }

    bool is_true(const std::string &value)
    {
        return value == "t" || value == "T" || value == "true" ||
               value == "TRUE" || value == "1";
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

    void append_html_escaped(std::string &out, std::string_view value)
    {
        if (value.empty())
        {
            return;
        }
        // Copy the plain runs in bulk; only the five escaped bytes need per-
        // character work. The seed puts &, ', " and multi-byte UTF-8 in almost
        // every row, so this is the hot loop of /fortunes.
        std::size_t plain_begin = 0;
        for (std::size_t i = 0; i < value.size(); ++i)
        {
            const char *escaped = nullptr;
            switch (value[i])
            {
                case '&':  escaped = "&amp;";  break;
                case '<':  escaped = "&lt;";   break;
                case '>':  escaped = "&gt;";   break;
                case '"':  escaped = "&quot;"; break;
                case '\'': escaped = "&#39;";  break;
                default:   continue;
            }
            out.append(value.data() + plain_begin, i - plain_begin);
            out += escaped;
            plain_begin = i + 1;
        }
        out.append(value.data() + plain_begin, value.size() - plain_begin);
    }

    std::string render_items(const std::vector<item_row> &rows)
    {
        std::string out;
        out.reserve(rows.size() * 256 + 64);
        out += "{\"items\":[";
        for (std::size_t i = 0; i < rows.size(); ++i)
        {
            const item_row &r = rows[i];
            if (i > 0)
            {
                out.push_back(',');
            }
            out += "{\"id\":";
            out += integer_or_zero(r.id);
            out += ",\"name\":";
            append_json_string(out, r.name);
            out += ",\"category\":";
            append_json_string(out, r.category);
            out += ",\"price\":";
            out += integer_or_zero(r.price);
            out += ",\"quantity\":";
            out += integer_or_zero(r.quantity);
            out += ",\"active\":";
            out += is_true(r.active) ? "true" : "false";
            out += ",\"tags\":";
            // jsonb arrives as a JSON array in text form; keep it verbatim.
            if (r.tags.size() > 1 && r.tags.front() == '[' && r.tags.back() == ']')
            {
                out += r.tags;
            }
            else
            {
                out += "[]";
            }
            out += ",\"rating\":{\"score\":";
            out += integer_or_zero(r.rating_score);
            out += ",\"count\":";
            out += integer_or_zero(r.rating_count);
            out += "}}";
        }
        out += "],\"count\":";
        out += std::to_string(rows.size());
        out.push_back('}');
        return out;
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
            append_html_escaped(out, r.message);
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

    std::string sql = "SELECT id,name,category,price,quantity,active,tags,rating_score,rating_count FROM items WHERE price BETWEEN ";
    sql += std::to_string(min_price);
    sql += " AND ";
    sql += std::to_string(max_price);
    sql += " LIMIT ";
    sql += std::to_string(limit);

    std::vector<item_row> rows;
    rows.reserve(static_cast<std::size_t>(limit));
    try
    {
        auto link = std::make_unique<orm::db_conn>("pg");
        co_await link->async_query(sql, rows);
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

    peer->output = render_items(rows);
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
        co_await link->async_query("SELECT id,message FROM fortune", rows);
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
