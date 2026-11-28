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
    const std::string PG_DB_TAG = "pg";

    // SQL 是固定文本：提到文件级静态，避免每请求构造超 SSO 的 std::string（堆分配）。
    // prepared 缓存按 SQL 文本哈希，静态串内容不变，缓存键同样稳定。
    const std::string SQL_ITEMS_BY_PRICE =
        "SELECT id,name,category,price,quantity,active,tags,rating_score,rating_count "
        "FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
    const std::string SQL_FORTUNES = "SELECT id,message FROM fortune";

    // 只缓存线程私有的 tag 解析结果；不缓存 db_conn，也不缓存其中的查询连接。
    // 每个协程帧仍创建独立的 db_conn，per_ioc_thread_num=2 时不存在共享请求状态。
    struct pg_db_binding
    {
        std::string dbtag;
        std::shared_ptr<orm::orm_conn_pool> conn_obj;
        orm::DB_TYPE db_type = orm::DB_TYPE::POSTGRESQL;
        bool ready = false;
    };

    void bind_cached_pg(orm::db_conn &link)
    {
        thread_local pg_db_binding binding;
        if (binding.ready)
        {
            link.dbtag   = binding.dbtag;
            link.conn_obj = binding.conn_obj;
            link.db_type  = binding.db_type;
            return;
        }

        link.select_db(PG_DB_TAG);
        if (link.conn_obj && link.db_type == orm::DB_TYPE::POSTGRESQL)
        {
            binding.dbtag    = link.dbtag;
            binding.conn_obj = link.conn_obj;
            binding.db_type  = link.db_type;
            binding.ready    = true;
        }
    }

    std::unique_ptr<orm::db_conn> make_pg_conn()
    {
        auto link = std::make_unique<orm::db_conn>();
        bind_cached_pg(*link);
        return link;
    }

    // 行视图：message 指向结果集缓冲区，排序和渲染期间不拷贝。
    struct fortune_view
    {
        long long id = 0;
        std::string_view message;
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

    // 结果集池：data / row_offsets / 列名向量的容量跨请求复用，数据本身不缓存。
    // 每个在途请求独占一个对象（同一 ioc 上多个请求的续体可能交错，共用会互相覆盖）。
    class result_set_pool
    {
      public:
        orm::pg_result_set &acquire()
        {
            if (free_.empty())
            {
                all_.push_back(std::make_unique<orm::pg_result_set>());
                free_.push_back(all_.back().get());
            }
            orm::pg_result_set *rs = free_.back();
            free_.pop_back();
            return *rs;
        }
        void release(orm::pg_result_set &rs) noexcept
        {
            rs.clear();
            free_.push_back(&rs);
        }

      private:
        std::vector<std::unique_ptr<orm::pg_result_set>> all_;
        std::vector<orm::pg_result_set *> free_;
    };

    result_set_pool &thread_result_sets()
    {
        // 协程在同一 ioc 线程上恢复（per_ioc_thread_num=1），池不需要加锁。
        thread_local result_set_pool pool;
        return pool;
    }

    // 参数组池：vector 容量跨请求复用。注意不能直接 thread_local 覆写一个 vector——
    // 驱动的重试路径（statement 丢失→重 Parse）会在挂起之后再读一次 params，
    // 交错请求会互相覆盖；必须像结果集那样独占租用到协程结束。
    class params_pool
    {
      public:
        std::vector<http::obj_val> &acquire()
        {
            if (free_.empty())
            {
                all_.push_back(std::make_unique<std::vector<http::obj_val>>());
                free_.push_back(all_.back().get());
            }
            std::vector<http::obj_val> *p = free_.back();
            free_.pop_back();
            return *p;
        }
        void release(std::vector<http::obj_val> &v) noexcept
        {
            v.clear();
            free_.push_back(&v);
        }

      private:
        std::vector<std::unique_ptr<std::vector<http::obj_val>>> all_;
        std::vector<std::vector<http::obj_val> *> free_;
    };

    params_pool &thread_params()
    {
        thread_local params_pool pool;
        return pool;
    }

    class params_guard
    {
      public:
        // 成员声明顺序与初始化顺序一致（params 在前），避免 -Wreorder。
        explicit params_guard(params_pool &pool) : params(pool.acquire()), pool_(pool) {}
        ~params_guard() { pool_.release(params); }
        params_guard(const params_guard &)            = delete;
        params_guard &operator=(const params_guard &) = delete;

        std::vector<http::obj_val> &params;

      private:
        params_pool &pool_;
    };

    class result_set_guard
    {
      public:
        // 初始化顺序与成员声明一致（rs 在前），避免 -Wreorder；两者都只用到入参 pool。
        explicit result_set_guard(result_set_pool &pool) : rs(pool.acquire()), pool_(pool) {}
        ~result_set_guard() { pool_.release(rs); }
        result_set_guard(const result_set_guard &)            = delete;
        result_set_guard &operator=(const result_set_guard &) = delete;

        orm::pg_result_set &rs;

      private:
        result_set_pool &pool_;
    };

    void render_fortunes(std::string &out, std::vector<fortune_view> &rows)
    {
        rows.push_back(fortune_view{0, "Additional fortune added at request time."});
        std::sort(rows.begin(), rows.end(), [](const fortune_view &a, const fortune_view &b) {
            return a.message < b.message;  // byte-ordinal, same as std::string::compare
        });

        out.clear();
        out.reserve(rows.size() * 140 + 256);
        out += "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Fortunes</title></head>";
        out += "<body><table><tr><th>id</th><th>message</th></tr>";
        for (const fortune_view &r : rows)
        {
            out += "<tr><td>";
            out += std::to_string(r.id);
            out += "</td><td>";
            http::html_escape(out, r.message);
            out += "</td></tr>";
        }
        out += "</table></body></html>";
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
    // params 从线程本地池租用（容量复用），协程结束才归还——重试路径挂起后还要读它。
    const std::string &sql = SQL_ITEMS_BY_PRICE;
    params_guard leased_params(thread_params());
    std::vector<http::obj_val> &params = leased_params.params;
    params.emplace_back(min_price);
    params.emplace_back(max_price);
    params.emplace_back(limit);

    // 整取：先把所有行读进结果集、连接随即归还，再解码渲染；渲染阶段不再占用连接。
    // 结果集来自线程本地池，缓冲区容量跨请求复用；行数据本身不缓存。
    constexpr int kColumnCount = 9;
    std::string &out       = peer->output;
    out.clear();
    out.reserve(static_cast<std::size_t>(limit) * 256 + 64);
    out += "{\"items\":[";

    try
    {
        auto link = make_pg_conn();
        result_set_guard result(thread_result_sets());
        orm::pg_result_set &rs = result.rs;

        co_await link->async_query_prepared_all(sql, params, rs);
        if (link->iserror || !link->error_msg.empty())
        {
            respond_db_error(peer, "database query failed");
            co_return "";
        }

        // 列位置按列名解析一次；列数或列名不符直接 503，避免按错位渲染。
        static constexpr const char *expect[kColumnCount] = {
            "id", "name", "category", "price", "quantity",
            "active", "tags", "rating_score", "rating_count"};
        int col[kColumnCount] = {-1, -1, -1, -1, -1, -1, -1, -1, -1};
        if (rs.col_names.size() != static_cast<std::size_t>(kColumnCount))
        {
            respond_db_error(peer, "database query failed");
            co_return "";
        }
        for (int e = 0; e < kColumnCount; ++e)
        {
            for (int i = 0; i < kColumnCount; ++i)
            {
                if (rs.col_names[(std::size_t)i] == expect[e])
                {
                    col[e] = i;
                    break;
                }
            }
            if (col[e] < 0)
            {
                respond_db_error(peer, "database query failed");
                co_return "";
            }
        }

        std::vector<orm::col_value_variant> values;
        std::vector<std::string> backing;
        values.reserve(kColumnCount);
        for (std::size_t i = 0; i < rs.row_count(); ++i)
        {
            values.clear();
            backing.clear();
            if (!rs.decode_row(i, values, backing))
            {
                respond_db_error(peer, "database query failed");
                co_return "";
            }
            if (i > 0)
            {
                out.push_back(',');
            }
            out += "{\"id\":";
            out += std::to_string(variant_int(values[(std::size_t)col[0]]));
            out += ",\"name\":";
            append_json_string(out, variant_text(values[(std::size_t)col[1]]));
            out += ",\"category\":";
            append_json_string(out, variant_text(values[(std::size_t)col[2]]));
            out += ",\"price\":";
            out += std::to_string(variant_int(values[(std::size_t)col[3]]));
            out += ",\"quantity\":";
            out += std::to_string(variant_int(values[(std::size_t)col[4]]));
            out += ",\"active\":";
            out += variant_int(values[(std::size_t)col[5]]) != 0 ? "true" : "false";
            out += ",\"tags\":";
            // jsonb arrives as a JSON array in text form; keep it verbatim.
            const std::string_view tags = variant_text(values[(std::size_t)col[6]]);
            if (tags.size() > 1 && tags.front() == '[' && tags.back() == ']')
            {
                out += tags;
            }
            else
            {
                out += "[]";
            }
            out += ",\"rating\":{\"score\":";
            out += std::to_string(variant_int(values[(std::size_t)col[7]]));
            out += ",\"count\":";
            out += std::to_string(variant_int(values[(std::size_t)col[8]]));
            out += "}}";
        }

        out += "],\"count\":";
        out += std::to_string(rs.row_count());
        out.push_back('}');
    }
    catch (const std::exception &)
    {
        respond_db_error(peer, "database query failed");
        co_return "";
    }

    co_return "";
}

//@urlpath(null,fortunes)
asio::awaitable<std::string> arena_fortunes(std::shared_ptr<httppeer> peer)
{
    peer->type("text/html; charset=utf-8");

    // 整取：co_await 返回时连接已归还；排序和 HTML 渲染只读结果集缓冲区，
    // message 不再逐行拷贝。reserve(row_count + 1) 给下面追加的运行时行留位。
    try
    {
        auto link = make_pg_conn();
        result_set_guard result(thread_result_sets());
        orm::pg_result_set &rs = result.rs;

        co_await link->async_query_prepared_all(SQL_FORTUNES, {}, rs);
        if (link->iserror || !link->error_msg.empty())
        {
            respond_db_error(peer, "database query failed");
            co_return "";
        }
        if (rs.col_names.size() < 2 || rs.row_count() == 0)
        {
            respond_db_error(peer, "fortune table is empty");
            co_return "";
        }

        std::vector<fortune_view> rows;
        rows.reserve(rs.row_count() + 1);
        std::vector<orm::col_value_variant> values;
        std::vector<std::string> backing;
        for (std::size_t i = 0; i < rs.row_count(); ++i)
        {
            values.clear();
            backing.clear();
            if (!rs.decode_row(i, values, backing) || values.size() < 2)
            {
                respond_db_error(peer, "database query failed");
                co_return "";
            }
            rows.push_back(fortune_view{variant_int(values[0]), variant_text(values[1])});
        }
        render_fortunes(peer->output, rows);
    }
    catch (const std::exception &)
    {
        respond_db_error(peer, "database query failed");
        co_return "";
    }
    co_return "";
}
}  // namespace http
