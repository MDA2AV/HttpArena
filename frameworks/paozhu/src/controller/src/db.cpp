#include "httppeer.h"
#include "orm_query.h"

#include <asio/steady_timer.hpp>
#include <asio/this_coro.hpp>
#include <asio/use_awaitable.hpp>

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cstdlib>
#include <string>
#include <string_view>
#include <system_error>
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

    // The framework splits orm.conf's maxpool budget across io_context slots
    // (per-slot quota = budget / slot count). Cap global in-flight queries at
    // the smallest slot quota so even a fully skewed request distribution
    // never pushes a slot into the pool's wait-timeout path; the env-derived
    // budget stays as the ceiling and as the fallback when no pool exists.
    // Waiting uses an asio timer, never a blocking semaphore: blocking an io
    // thread can deadlock the coroutine that holds a ticket.
    class db_ticket
    {
        static std::atomic<int> &in_flight()
        {
            static std::atomic<int> count{0};
            return count;
        }

        static int limit()
        {
            static const int value = [] {
                const char *env = std::getenv("DATABASE_MAX_CONN");
                int n = env ? std::atoi(env) : 256;
                if (n < 8) n = 8;
                if (n > 256) n = 256;
                int cap = n > 24 ? n - 24 : n;

                auto &pools = orm::get_orm_conn_pool_obj();
                auto it     = pools.find("pg");
                if (it != pools.end() && it->second && !it->second->slots.empty())
                {
                    const auto &pool = *it->second;
                    unsigned int smallest = pool.slot_max_of(1, 0);// 1 = select role
                    for (unsigned int i = 1; i < pool.slots.size(); ++i)
                    {
                        const unsigned int q = pool.slot_max_of(1, i);
                        if (q < smallest) smallest = q;
                    }
                    if (smallest >= 1 && static_cast<int>(smallest) < cap)
                    {
                        cap = static_cast<int>(smallest);
                    }
                }
                return cap;
            }();
            return value;
        }

        bool owns_ = false;

      public:
        db_ticket() = default;
        db_ticket(const db_ticket &) = delete;
        db_ticket &operator=(const db_ticket &) = delete;
        ~db_ticket()
        {
            if (owns_)
            {
                in_flight().fetch_sub(1, std::memory_order_relaxed);
            }
        }

        bool try_enter()
        {
            int current = in_flight().load(std::memory_order_relaxed);
            while (current < limit())
            {
                if (in_flight().compare_exchange_weak(current, current + 1,
                                                      std::memory_order_relaxed))
                {
                    owns_ = true;
                    return true;
                }
            }
            return false;
        }
    };

    asio::awaitable<bool> enter_db_gate(db_ticket &ticket)
    {
        if (ticket.try_enter())
        {
            co_return true;
        }
        auto executor = co_await asio::this_coro::executor;
        for (unsigned attempt = 0; attempt < 250; ++attempt)
        {
            asio::steady_timer timer(executor);
            timer.expires_after(std::chrono::milliseconds(2));
            co_await timer.async_wait(asio::use_awaitable);
            if (ticket.try_enter())
            {
                co_return true;
            }
        }
        co_return false;
    }

    long long to_int(std::string_view value, long long fallback = 0)
    {
        long long parsed = 0;
        auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
        return result.ec == std::errc{} ? parsed : fallback;
    }

    long long query_int(const std::string &query, std::string_view key, long long fallback)
    {
        std::size_t pos = 0;
        while (pos < query.size())
        {
            const std::size_t amp = query.find('&', pos);
            const std::size_t end = amp == std::string::npos ? query.size() : amp;
            std::string_view pair(query.data() + pos, end - pos);
            const std::size_t eq = pair.find('=');
            if (eq != std::string_view::npos && pair.substr(0, eq) == key)
            {
                return to_int(pair.substr(eq + 1), fallback);
            }
            if (amp == std::string::npos)
            {
                break;
            }
            pos = amp + 1;
        }
        return fallback;
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
        for (char ch : value)
        {
            switch (ch)
            {
                case '&':  out += "&amp;"; break;
                case '<':  out += "&lt;"; break;
                case '>':  out += "&gt;"; break;
                case '"':  out += "&quot;"; break;
                case '\'': out += "&#39;"; break;
                default:   out.push_back(ch);
            }
        }
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

    const long long min_price = query_int(peer->querystring, "min", 10);
    const long long max_price = query_int(peer->querystring, "max", 50);
    long long limit           = query_int(peer->querystring, "limit", 50);
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;

    db_ticket ticket;
    std::vector<item_row> rows;
    if (co_await enter_db_gate(ticket))
    {
        try
        {
            std::string sql = "SELECT id,name,category,price,quantity,active,tags,rating_score,rating_count FROM items WHERE price BETWEEN ";
            sql += std::to_string(min_price);
            sql += " AND ";
            sql += std::to_string(max_price);
            sql += " LIMIT ";
            sql += std::to_string(limit);

            auto link = std::make_unique<orm::db_conn>("pg");
            rows.reserve(static_cast<std::size_t>(limit));
            co_await link->async_query(sql, rows);
        }
        catch (const std::exception &)
        {
            rows.clear();
        }
    }

    peer->output = render_items(rows);
    co_return "";
}

//@urlpath(null,fortunes)
asio::awaitable<std::string> arena_fortunes(std::shared_ptr<httppeer> peer)
{
    peer->type("text/html; charset=utf-8");

    db_ticket ticket;
    std::vector<fortune_row> rows;
    if (co_await enter_db_gate(ticket))
    {
        try
        {
            auto link = std::make_unique<orm::db_conn>("pg");
            // 201 = 200 seeded rows + the runtime row appended below. The seed is
            // this repo's own: 12 TechEmpower rows plus generate_series(13,200) in
            // data/pgdb-seed.sql. It is not the 12-row TE contract, so revisit this
            // if the seed changes; reserve() only sets capacity either way.
            rows.reserve(201);
            co_await link->async_query("SELECT id,message FROM fortune", rows);
        }
        catch (const std::exception &)
        {
            rows.clear();
        }
    }

    peer->output = render_fortunes(rows);
    co_return "";
}
}  // namespace http
