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
#include <memory>
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

    // paozhu's ORM pool already enforces per-slot quotas with asynchronous
    // backoff in async_get_pg_select_conn(). What the handlers still need is a
    // process-wide ceiling under Postgres' max_connections: the pool's TOTAL
    // select quota (parsed from orm.conf) minus 24 backends reserved for the
    // edit pool, readiness probes and PG maintenance. Never use the smallest
    // per-slot quota here: budget/slots shrinks as orm_ioc_num grows
    // (4 slots -> 63, 16 -> 15, 64 -> 3), so adding io threads would lower the
    // cap while the pool itself can still serve 255 queries.
    // Waiting must be a coroutine on the request's own executor: paozhu runs
    // one thread per io_context, so a blocking semaphore would pin that thread
    // and the coroutine holding a ticket could never resume to release it.
    class db_gate
    {
        static std::atomic<int> &in_flight()
        {
            static std::atomic<int> count{0};
            return count;
        }

        static int limit()
        {
            static const int value = [] {
                // Single source of truth: the pool's parsed quota, i.e. the
                // maxpool that entrypoint.sh rendered into orm.conf. The pool
                // splits it across slots, so sum the slots back up instead of
                // copying one slot's quota (which would scale the cap down as
                // orm_ioc_num grows). DATABASE_MAX_CONN is only a fallback for
                // a process started without orm.conf (no DB profile).
                const char *env = std::getenv("DATABASE_MAX_CONN");
                int fallback = std::clamp(env ? std::atoi(env) : 256, 8, 256);
                int cap = fallback > 24 ? fallback - 24 : fallback;

                auto &pools = orm::get_orm_conn_pool_obj();
                auto it     = pools.find("pg");
                if (it != pools.end() && it->second && !it->second->slots.empty())
                {
                    const auto &pool = *it->second;
                    long long total = 0;
                    for (std::size_t i = 0; i < pool.slots.size(); ++i)
                    {
                        total += pool.slot_max_of(1, static_cast<unsigned int>(i));// 1 = select role
                    }
                    if (total > 0)
                    {
                        // Leave 24 backends for the edit pool, readiness probes
                        // and PG maintenance: orm.conf's 255 would otherwise
                        // consume all of max_connections=256.
                        const long long usable = total > 24 ? total - 24 : total;
                        if (usable < cap)
                        {
                            cap = static_cast<int>(usable);
                        }
                    }
                }
                return cap;
            }();
            return value;
        }

        static bool try_acquire()
        {
            int current = in_flight().load(std::memory_order_relaxed);
            while (current < limit())
            {
                if (in_flight().compare_exchange_weak(current, current + 1,
                                                      std::memory_order_relaxed))
                {
                    return true;
                }
            }
            return false;
        }

        static void release()
        {
            in_flight().fetch_sub(1, std::memory_order_relaxed);
        }

      public:
        class ticket
        {
            bool owns_ = false;

          public:
            ticket() = default;
            ticket(const ticket &) = delete;
            ticket &operator=(const ticket &) = delete;
            ~ticket()
            {
                if (owns_)
                {
                    db_gate::release();
                }
            }

            bool try_acquire()
            {
                if (!db_gate::try_acquire())
                {
                    return false;
                }
                owns_ = true;
                return true;
            }
        };

        // Bounded wait with 1..8 ms backoff. A single timer is reused so a
        // suspended request owns no per-attempt allocation. 500 ms is the same
        // ceiling as the old fixed 250 x 2 ms loop, but short waits now resolve
        // quickly instead of always paying a full 2 ms slot.
        static asio::awaitable<bool> enter(ticket &t)
        {
            if (t.try_acquire())
            {
                co_return true;
            }
            auto executor = co_await asio::this_coro::executor;
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
            std::chrono::milliseconds backoff{1};
            asio::steady_timer timer(executor);
            for (;;)
            {
                const auto now = std::chrono::steady_clock::now();
                if (now >= deadline)
                {
                    co_return false;
                }
                auto remain = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
                const auto wait = std::min(backoff, std::max(remain, std::chrono::milliseconds{1}));
                timer.expires_after(wait);
                co_await timer.async_wait(asio::use_awaitable);
                if (t.try_acquire())
                {
                    co_return true;
                }
                backoff = std::min(backoff * 2, std::chrono::milliseconds{8});
            }
        }
    };

    void respond_db_error(const std::shared_ptr<http::httppeer> &peer, std::string_view message)
    {
        peer->type("text/plain; charset=utf-8");
        peer->status(503);
        peer->output = std::string(message);
    }

    // One query path for both DB routes: gate -> driver -> explicit failure.
    // pg_async_query_vec_impl() catches driver exceptions into error_msg and
    // returns 0 rows, so checking rows.empty() would mistake a legitimate
    // empty /async-db result for an error; iserror / error_msg are the signal.
    template <typename Row>
    asio::awaitable<bool> fetch_rows(const std::shared_ptr<http::httppeer> &peer,
                                     const std::string &sql,
                                     std::vector<Row> &rows)
    {
        db_gate::ticket ticket;
        if (!co_await db_gate::enter(ticket))
        {
            respond_db_error(peer, "database busy");
            co_return false;
        }

        try
        {
            auto link = std::make_unique<orm::db_conn>("pg");
            co_await link->async_query(sql, rows);
            if (link->iserror || !link->error_msg.empty())
            {
                rows.clear();
                respond_db_error(peer, "database query failed");
                co_return false;
            }
        }
        catch (const std::exception &)
        {
            rows.clear();
            respond_db_error(peer, "database query failed");
            co_return false;
        }
        co_return true;
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

    const long long min_price = query_int(peer->querystring, "min", 10);
    const long long max_price = query_int(peer->querystring, "max", 50);
    long long limit           = query_int(peer->querystring, "limit", 50);
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
    if (!co_await fetch_rows(peer, sql, rows))
    {
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
    if (!co_await fetch_rows(peer, "SELECT id,message FROM fortune", rows))
    {
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
