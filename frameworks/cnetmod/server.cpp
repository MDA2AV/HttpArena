#include <cnetmod/config.hpp>
#include <cnetmod/json.hpp>
#ifdef __linux__
#include <sched.h>
#endif

import std;
import cnetmod.core.log;
import cnetmod.core.net_init;
import cnetmod.core.ssl;
import cnetmod.coro.spawn;
import cnetmod.coro.task;
import cnetmod.coro.timer;
import cnetmod.executor.pool;
import cnetmod.io.io_context;
import cnetmod.json;
import cnetmod.protocol.grpc;
import cnetmod.protocol.http;
import cnetmod.protocol.http.middleware.compress;
import cnetmod.protocol.postgresql;
import cnetmod.protocol.redis;
import cnetmod.protocol.websocket;
import cnetmod.utils.concurrent_containers.striped_hash_map;

namespace cn = cnetmod;
namespace grpc = cnetmod::grpc;
namespace http = cnetmod::http;
namespace pg = cnetmod::postgresql;
namespace redis = cnetmod::redis;
namespace ws = cnetmod::ws;

namespace arena {

struct rating {
  std::int64_t score{};
  std::int64_t count{};
};

struct item {
  std::int64_t id{};
  std::string name;
  std::string category;
  std::int64_t price{};
  std::int64_t quantity{};
  bool active{};
  std::vector<std::string> tags;
  rating rating_value;
  std::optional<std::int64_t> total;
};

struct item_list {
  std::vector<item> items;
  std::size_t count{};
};

// Serialization view over a dataset item: the response is still serialized
// per request, but without copying each item's strings and tags first.
struct item_view {
  std::int64_t id{};
  std::string_view name;
  std::string_view category;
  std::int64_t price{};
  std::int64_t quantity{};
  bool active{};
  std::span<const std::string> tags;
  rating rating_value;
  std::int64_t total{};
};

struct item_view_list {
  std::span<const item_view> items;
  std::size_t count{};
};

// One /async-db row, borrowed from the query result: the text columns are
// views and the jsonb tags column is embedded as Postgres rendered it.
struct database_item {
  std::int64_t id{};
  std::string_view name;
  std::string_view category;
  std::int64_t price{};
  std::int64_t quantity{};
  bool active{};
  cnetmod::json::raw_json tags{"[]"};
  rating rating_value;
};

struct database_item_list {
  std::span<const database_item> items;
  std::size_t count{};
};

struct item_update {
  std::string name;
  std::int64_t price{};
  std::int64_t quantity{};
};

struct user {
  std::int64_t id{};
  std::string name;
  std::string email;
  std::string plan;
};

} // namespace arena

CNETMOD_JSON(arena::rating, CNETMOD_JSON_FIELD(score),
             CNETMOD_JSON_FIELD(count))

template <> struct cnetmod::json::document_traits<arena::item> {
  using _cnetmod_json_type = arena::item;

  static constexpr auto fields() {
    return std::tuple{
        cnetmod::json::field("id", &_cnetmod_json_type::id),
        cnetmod::json::field("name", &_cnetmod_json_type::name),
        cnetmod::json::field("category", &_cnetmod_json_type::category),
        cnetmod::json::field("price", &_cnetmod_json_type::price),
        cnetmod::json::field("quantity", &_cnetmod_json_type::quantity),
        cnetmod::json::field("active", &_cnetmod_json_type::active),
        cnetmod::json::field("tags", &_cnetmod_json_type::tags),
        cnetmod::json::field("rating", &_cnetmod_json_type::rating_value),
        cnetmod::json::field("total", &_cnetmod_json_type::total)};
  }
};

CNETMOD_JSON(arena::item_list, CNETMOD_JSON_FIELD(items),
             CNETMOD_JSON_FIELD(count))

template <> struct cnetmod::json::document_traits<arena::item_view> {
  using _cnetmod_json_type = arena::item_view;

  static constexpr auto fields() {
    return std::tuple{
        cnetmod::json::field("id", &_cnetmod_json_type::id),
        cnetmod::json::field("name", &_cnetmod_json_type::name),
        cnetmod::json::field("category", &_cnetmod_json_type::category),
        cnetmod::json::field("price", &_cnetmod_json_type::price),
        cnetmod::json::field("quantity", &_cnetmod_json_type::quantity),
        cnetmod::json::field("active", &_cnetmod_json_type::active),
        cnetmod::json::field("tags", &_cnetmod_json_type::tags),
        cnetmod::json::field("rating", &_cnetmod_json_type::rating_value),
        cnetmod::json::field("total", &_cnetmod_json_type::total)};
  }
};

CNETMOD_JSON(arena::item_view_list, CNETMOD_JSON_FIELD(items),
             CNETMOD_JSON_FIELD(count))

template <> struct cnetmod::json::document_traits<arena::database_item> {
  using _cnetmod_json_type = arena::database_item;

  static constexpr auto fields() {
    return std::tuple{
        cnetmod::json::field("id", &_cnetmod_json_type::id),
        cnetmod::json::field("name", &_cnetmod_json_type::name),
        cnetmod::json::field("category", &_cnetmod_json_type::category),
        cnetmod::json::field("price", &_cnetmod_json_type::price),
        cnetmod::json::field("quantity", &_cnetmod_json_type::quantity),
        cnetmod::json::field("active", &_cnetmod_json_type::active),
        cnetmod::json::field("tags", &_cnetmod_json_type::tags),
        cnetmod::json::field("rating", &_cnetmod_json_type::rating_value)};
  }
};

CNETMOD_JSON(arena::database_item_list, CNETMOD_JSON_FIELD(items),
             CNETMOD_JSON_FIELD(count))

CNETMOD_JSON(arena::item_update, CNETMOD_JSON_FIELD(name),
             CNETMOD_JSON_FIELD(price), CNETMOD_JSON_FIELD(quantity))

CNETMOD_JSON(arena::user, CNETMOD_JSON_FIELD(id), CNETMOD_JSON_FIELD(name),
             CNETMOD_JSON_FIELD(email), CNETMOD_JSON_FIELD(plan))

namespace {

[[nodiscard]] auto parse_integer(std::string_view text) noexcept
    -> std::int64_t {
  std::int64_t value{};
  const auto [end, error] =
      std::from_chars(text.data(), text.data() + text.size(), value);
  return error == std::errc{} && end == text.data() + text.size() ? value : 0;
}

[[nodiscard]] auto sum_query(std::string_view query) noexcept -> std::int64_t {
  std::int64_t sum{};
  while (!query.empty()) {
    const auto separator = query.find('&');
    const auto field = query.substr(0, separator);
    const auto equals = field.find('=');
    if (equals != std::string_view::npos)
      sum += parse_integer(field.substr(equals + 1));
    if (separator == std::string_view::npos)
      break;
    query.remove_prefix(separator + 1);
  }
  return sum;
}

[[nodiscard]] auto query_integer(std::string_view query, std::string_view name,
                                 std::int64_t fallback) noexcept
    -> std::int64_t {
  while (!query.empty()) {
    const auto separator = query.find('&');
    const auto field = query.substr(0, separator);
    const auto equals = field.find('=');
    if (equals != std::string_view::npos && field.substr(0, equals) == name)
      return parse_integer(field.substr(equals + 1));
    if (separator == std::string_view::npos)
      break;
    query.remove_prefix(separator + 1);
  }
  return fallback;
}

[[nodiscard]] auto parse_database_url(std::string_view url)
    -> std::optional<pg::connection_options> {
  constexpr std::string_view scheme{"postgres://"};
  if (!url.starts_with(scheme))
    return std::nullopt;
  url.remove_prefix(scheme.size());

  const auto at = url.find('@');
  const auto slash = at == std::string_view::npos ? std::string_view::npos
                                                  : url.find('/', at + 1);
  if (at == std::string_view::npos || slash == std::string_view::npos)
    return std::nullopt;

  const auto credentials = url.substr(0, at);
  const auto separator = credentials.find(':');
  if (separator == std::string_view::npos)
    return std::nullopt;

  auto authority = url.substr(at + 1, slash - at - 1);
  auto database = url.substr(slash + 1);
  if (database.empty())
    return std::nullopt;

  pg::connection_options result;
  result.username = credentials.substr(0, separator);
  result.password = credentials.substr(separator + 1);
  result.database = database;
  result.tls = pg::tls_mode::disable;
  result.application_name = "cnetmod-httparena";
  result.maximum_connect_attempts = 1;

  const auto colon = authority.rfind(':');
  if (colon == std::string_view::npos)
    result.host = authority;
  else {
    result.host = authority.substr(0, colon);
    unsigned port{};
    const auto port_text = authority.substr(colon + 1);
    const auto [end, error] = std::from_chars(
        port_text.data(), port_text.data() + port_text.size(), port);
    if (error != std::errc{} || end != port_text.data() + port_text.size() ||
        port == 0 || port > std::numeric_limits<std::uint16_t>::max())
      return std::nullopt;
    result.port = static_cast<std::uint16_t>(port);
  }
  if (result.host.empty() || result.username.empty())
    return std::nullopt;
  return result;
}

class postgres_shards {
public:
  explicit postgres_shards(cn::server_context &runtime) {
    const auto *database_url = std::getenv("DATABASE_URL");
    if (database_url == nullptr)
      return;
    auto connection = parse_database_url(database_url);
    if (!connection) {
      logger::error{"invalid DATABASE_URL"};
      return;
    }

    auto workers = runtime.worker_ios();
    auto connection_limit = std::size_t{256};
    if (const auto *configured = std::getenv("DATABASE_MAX_CONN")) {
      const auto text = std::string_view{configured};
      const auto [end, error] = std::from_chars(
          text.data(), text.data() + text.size(), connection_limit);
      if (error != std::errc{} || end != text.data() + text.size() ||
          connection_limit == 0)
        connection_limit = 256;
    }

    const auto per_worker =
        std::max(std::size_t{1},
                 connection_limit / std::max(std::size_t{1}, workers.size()));
    shards_.reserve(workers.size());
    for (auto *worker : workers) {
      pg::connection_pool_options options;
      options.connection = *connection;
      options.minimum_connections = 1;
      options.maximum_connections = per_worker;
      options.acquire_timeout = std::chrono::milliseconds{5000};
      shards_.push_back({worker, std::make_unique<pg::connection_pool>(
                                     *worker, std::move(options))});
    }
  }

  [[nodiscard]] auto for_context(cn::io_context &context) noexcept
      -> pg::connection_pool * {
    for (auto &shard : shards_)
      if (shard.context == &context)
        return shard.pool.get();
    return nullptr;
  }

private:
  struct shard {
    cn::io_context *context{};
    std::unique_ptr<pg::connection_pool> pool;
  };
  std::vector<shard> shards_;
};

class redis_cache {
public:
  explicit redis_cache(cn::server_context &runtime) {
    const auto *redis_url = std::getenv("REDIS_URL");
    if (redis_url == nullptr)
      return;
    auto url = std::string_view{redis_url};
    constexpr std::string_view scheme{"redis://"};
    if (!url.starts_with(scheme))
      return;
    url.remove_prefix(scheme.size());

    redis::pool_params options;
    const auto colon = url.rfind(':');
    if (colon == std::string_view::npos)
      options.host = url;
    else {
      options.host = url.substr(0, colon);
      unsigned port{};
      const auto text = url.substr(colon + 1);
      const auto [end, error] =
          std::from_chars(text.data(), text.data() + text.size(), port);
      if (error != std::errc{} || end != text.data() + text.size() ||
          port == 0 || port > std::numeric_limits<std::uint16_t>::max())
        return;
      options.port = static_cast<std::uint16_t>(port);
    }
    options.initial_size = 1;
    options.max_size = 8;
    options.connect_timeout = std::chrono::seconds{2};
    options.pool_timeout = std::chrono::seconds{2};
    for (auto *worker : runtime.worker_ios())
      shards_.push_back(
          {worker, std::make_unique<redis::connection_pool>(*worker, options)});
  }

  [[nodiscard]] auto enabled() const noexcept -> bool {
    return !shards_.empty();
  }

  void start() {
    for (auto &shard : shards_)
      cn::spawn(*shard.context, shard.pool->async_run());
  }

  // L1: process-wide, shared by every worker so a write on one worker is
  // visible to all others as soon as it erases the entry.
  [[nodiscard]] auto local(std::int64_t id, bool user) const
      -> std::shared_ptr<const std::string> {
    auto found = (user ? users_ : items_).find(id);
    if (!found || std::chrono::steady_clock::now() >= found->expires)
      return {};
    return std::move(found->body);
  }

  void store_local(std::int64_t id, bool user, std::string body,
                   std::chrono::steady_clock::duration ttl) {
    (user ? users_ : items_)
        .insert_or_assign(
            id, local_entry{std::make_shared<const std::string>(std::move(body)),
                            std::chrono::steady_clock::now() + ttl});
  }

  void erase_local(std::int64_t id) { (void)items_.erase(id); }

  auto get(cn::io_context &context, std::string_view key)
      -> cn::task<std::optional<std::string>> {
    if (!l2_)
      co_return std::nullopt;
    auto *pool = for_context(context);
    if (pool == nullptr)
      co_return std::nullopt;
    auto lease = co_await pool->async_get_connection();
    if (!lease)
      co_return std::nullopt;
    auto reply = co_await lease->get().cmd({"GET", key});
    if (!reply || reply->empty() || reply->front().is_null() ||
        reply->front().is_error())
      co_return std::nullopt;
    co_return reply->front().value;
  }

  auto set(cn::io_context &context, std::string_view key,
           std::string_view value, std::chrono::seconds ttl) -> cn::task<void> {
    if (!l2_)
      co_return;
    auto *pool = for_context(context);
    if (pool == nullptr)
      co_return;
    auto lease = co_await pool->async_get_connection();
    if (!lease)
      co_return;
    const auto seconds = std::to_string(ttl.count());
    (void)co_await lease->get().cmd({"SET", key, value, "EX", seconds});
  }

  auto erase(cn::io_context &context, std::string_view key) -> cn::task<void> {
    if (!l2_)
      co_return;
    auto *pool = for_context(context);
    if (pool == nullptr)
      co_return;
    auto lease = co_await pool->async_get_connection();
    if (!lease)
      co_return;
    (void)co_await lease->get().cmd({"DEL", key});
  }

private:
  struct shard {
    cn::io_context *context{};
    std::unique_ptr<redis::connection_pool> pool;
  };

  struct local_entry {
    std::shared_ptr<const std::string> body;
    std::chrono::steady_clock::time_point expires;
  };

  using local_map =
      cn::concurrent_containers::striped_hash_map<std::int64_t, local_entry>;
  local_map items_{16384U, 64U};
  local_map users_{1024U, 16U};
  // Redis as a second tier is opt-in (CACHE_L2=redis). The profile allows an
  // in-process-only cache, and the shared cache container runs Redis with
  // four I/O threads on a two-thread cpuset, which stalls replies for tens of
  // milliseconds once eight clients are active.
  bool l2_ = [] {
    const auto *configured = std::getenv("CACHE_L2");
    return configured != nullptr && std::string_view{configured} == "redis";
  }();

  [[nodiscard]] auto for_context(cn::io_context &context) noexcept
      -> redis::connection_pool * {
    for (auto &shard : shards_)
      if (shard.context == &context)
        return shard.pool.get();
    return nullptr;
  }

  std::vector<shard> shards_;
};

void respond_database_result(http::request_context &request,
                             arena::database_item_list output = {}) {
  auto encoded = cnetmod::json::write(output);
  if (!encoded) {
    request.text(http::status::internal_server_error, "serialization failed");
    return;
  }
  request.json(http::status::ok, *encoded);
}

auto async_database(http::request_context &request, postgres_shards &database)
    -> cn::task<void> {
  auto *pool = database.for_context(request.io_ctx());
  if (pool == nullptr) {
    respond_database_result(request);
    co_return;
  }

  const auto minimum = query_integer(request.query_string(), "min", 10);
  const auto maximum = query_integer(request.query_string(), "max", 50);
  const auto limit =
      std::clamp(query_integer(request.query_string(), "limit", 50),
                 std::int64_t{1}, std::int64_t{50});

  auto lease = co_await pool->acquire();
  if (!lease) {
    respond_database_result(request);
    co_return;
  }

  auto result = co_await lease->get().execute(pg::with_params(
      "SELECT id, name, category, price, quantity, active, tags, "
      "rating_score, rating_count FROM items "
      "WHERE price BETWEEN $1 AND $2 LIMIT $3",
      {pg::param_value::from_int(minimum), pg::param_value::from_int(maximum),
       pg::param_value::from_int(limit)}));
  if (result.is_err()) {
    lease->discard();
    respond_database_result(request);
    co_return;
  }

  // LIMIT is clamped to 50, so the rows fit a fixed buffer.
  std::array<arena::database_item, 50> items{};
  std::size_t count = 0;
  for (const auto &row : result.rows) {
    if (row.size() != 9 || count == items.size())
      continue;
    items[count++] = {.id = row[0].get_int64(),
                      .name = row[1].get_string(),
                      .category = row[2].get_string(),
                      .price = row[3].get_int64(),
                      .quantity = row[4].get_int64(),
                      .active = row[5].get_int64() != 0,
                      // jsonb text from the server is always valid JSON.
                      .tags = {row[6].get_string()},
                      .rating_value = {.score = row[7].get_int64(),
                                       .count = row[8].get_int64()}};
  }
  respond_database_result(
      request, {.items = std::span{items}.first(count), .count = count});
}

[[nodiscard]] auto database_item_from_row(const pg::row &row)
    -> std::optional<arena::item> {
  if (row.size() != 9)
    return std::nullopt;
  auto tags =
      cnetmod::json::parse<std::vector<std::string>>(row[6].get_string());
  if (!tags)
    return std::nullopt;
  arena::item result{.id = row[0].get_int64(),
                     .name = std::string{row[1].get_string()},
                     .category = std::string{row[2].get_string()},
                     .price = row[3].get_int64(),
                     .quantity = row[4].get_int64(),
                     .active = row[5].get_int64() != 0,
                     .tags = std::move(*tags),
                     .rating_value = {.score = row[7].get_int64(),
                                      .count = row[8].get_int64()}};
  result.total = result.price * result.quantity;
  return result;
}

[[nodiscard]] auto verified_user(const http::request_context &request)
    -> std::string_view {
  return request.get_header("X-User-Id");
}

auto api_item_get(http::request_context &request, postgres_shards &database,
                  redis_cache &cache) -> cn::task<void> {
  if (verified_user(request).empty()) {
    request.text(http::status::unauthorized, "unauthorized");
    co_return;
  }
  const auto id = parse_integer(request.param("id"));
  if (auto local = cache.local(id, false)) {
    request.resp().set_header("X-Cache", "HIT");
    request.json(http::status::ok, *local);
    co_return;
  }
  const auto key = std::format("httparena:item:{}", id);
  if (auto cached = co_await cache.get(request.io_ctx(), key)) {
    request.resp().set_header("X-Cache", "HIT");
    request.json(http::status::ok, *cached);
    cache.store_local(id, false, std::move(*cached), std::chrono::seconds{1});
    co_return;
  }

  request.resp().set_header("X-Cache", "MISS");
  auto *pool = database.for_context(request.io_ctx());
  if (pool == nullptr) {
    request.text(http::status::service_unavailable, "database unavailable");
    co_return;
  }
  auto lease = co_await pool->acquire();
  if (!lease) {
    request.text(http::status::service_unavailable, "database unavailable");
    co_return;
  }
  auto rows = co_await lease->get().execute(pg::with_params(
      "SELECT id, name, category, price, quantity, active, tags, "
      "rating_score, rating_count FROM items WHERE id = $1",
      {pg::param_value::from_int(id)}));
  if (rows.is_err() || rows.rows.empty()) {
    request.text(http::status::not_found, "item not found");
    co_return;
  }
  auto item = database_item_from_row(rows.rows.front());
  auto encoded =
      item ? cnetmod::json::write(*item)
           : std::unexpected(std::make_error_code(std::errc::invalid_argument));
  if (!encoded) {
    request.text(http::status::internal_server_error, "serialization failed");
    co_return;
  }
  co_await cache.set(request.io_ctx(), key, *encoded, std::chrono::seconds{1});
  request.json(http::status::ok, *encoded);
  cache.store_local(id, false, std::move(*encoded), std::chrono::seconds{1});
}

auto api_item_update(http::request_context &request, postgres_shards &database,
                     redis_cache &cache) -> cn::task<void> {
  if (verified_user(request).empty()) {
    request.text(http::status::unauthorized, "unauthorized");
    co_return;
  }
  auto input = cnetmod::json::parse<arena::item_update>(request.body());
  if (!input) {
    request.text(http::status::bad_request, "invalid item update");
    co_return;
  }
  const auto id = parse_integer(request.param("id"));
  auto *pool = database.for_context(request.io_ctx());
  if (pool != nullptr) {
    auto lease = co_await pool->acquire();
    if (lease) {
      (void)co_await lease->get().execute(pg::with_params(
          "UPDATE items SET name = $1, price = $2, quantity = $3 "
          "WHERE id = $4",
          {pg::param_value::from_string(std::move(input->name)),
           pg::param_value::from_int(input->price),
           pg::param_value::from_int(input->quantity),
           pg::param_value::from_int(id)}));
    }
  }
  // Clear L2 first so a concurrent L1 miss cannot refill L1 from a stale L2.
  co_await cache.erase(request.io_ctx(), std::format("httparena:item:{}", id));
  cache.erase_local(id);
  request.resp()
      .set_status(http::status::no_content)
      .set_body(std::string_view{});
}

auto api_me(http::request_context &request, postgres_shards &database,
            redis_cache &cache) -> cn::task<void> {
  const auto identity = verified_user(request);
  if (identity.empty()) {
    request.text(http::status::unauthorized, "unauthorized");
    co_return;
  }
  const auto id = parse_integer(identity);
  if (auto local = cache.local(id, true)) {
    request.resp().set_header("X-Cache", "HIT");
    request.json(http::status::ok, *local);
    co_return;
  }
  const auto key = std::format("httparena:user:{}", id);
  if (auto cached = co_await cache.get(request.io_ctx(), key)) {
    request.resp().set_header("X-Cache", "HIT");
    request.json(http::status::ok, *cached);
    cache.store_local(id, true, std::move(*cached), std::chrono::seconds{30});
    co_return;
  }

  auto *pool = database.for_context(request.io_ctx());
  if (pool == nullptr) {
    request.text(http::status::service_unavailable, "database unavailable");
    co_return;
  }
  auto lease = co_await pool->acquire();
  if (!lease) {
    request.text(http::status::service_unavailable, "database unavailable");
    co_return;
  }
  auto rows = co_await lease->get().execute(
      pg::with_params("SELECT id, name, email, plan FROM users WHERE id = $1",
                      {pg::param_value::from_int(id)}));
  if (rows.is_err() || rows.rows.empty() || rows.rows.front().size() != 4) {
    request.text(http::status::not_found, "user not found");
    co_return;
  }
  const auto &row = rows.rows.front();
  arena::user output{.id = row[0].get_int64(),
                     .name = std::string{row[1].get_string()},
                     .email = std::string{row[2].get_string()},
                     .plan = std::string{row[3].get_string()}};
  auto encoded = cnetmod::json::write(output);
  if (!encoded) {
    request.text(http::status::internal_server_error, "serialization failed");
    co_return;
  }
  request.resp().set_header("X-Cache", "MISS");
  co_await cache.set(request.io_ctx(), key, *encoded, std::chrono::seconds{30});
  request.json(http::status::ok, *encoded);
  cache.store_local(id, true, std::move(*encoded), std::chrono::seconds{30});
}

void respond_integer(http::request_context &request, std::int64_t value) {
  std::array<char, 32> storage{};
  const auto [end, error] =
      std::to_chars(storage.data(), storage.data() + storage.size(), value);
  if (error != std::errc{}) {
    request.text(http::status::internal_server_error, "conversion failed");
    return;
  }
  request.text(http::status::ok,
               std::string_view{storage.data(), static_cast<std::size_t>(
                                                    end - storage.data())});
}

void baseline(http::request_context &request) {
  auto sum = sum_query(request.query_string());
  if (request.method_enum() == http::http_method::POST)
    sum += parse_integer(request.body());
  respond_integer(request, sum);
}

[[nodiscard]] auto load_dataset()
    -> std::expected<std::vector<arena::item>, std::error_code> {
  std::ifstream input{"/data/dataset.json", std::ios::binary};
  if (!input)
    return std::unexpected(
        std::make_error_code(std::errc::no_such_file_or_directory));

  std::string source{std::istreambuf_iterator<char>{input}, {}};
  return cnetmod::json::parse<std::vector<arena::item>>(source);
}

void json_response(http::request_context &request,
                   const std::vector<arena::item> &dataset) {
  const auto requested = parse_integer(request.param("count"));
  if (requested < 1 || requested > static_cast<std::int64_t>(dataset.size())) {
    request.text(http::status::bad_request, "invalid item count");
    return;
  }

  const auto multiplier = query_integer(request.query_string(), "m", 1);
  const auto count = static_cast<std::size_t>(requested);
  std::array<arena::item_view, 50> views{};
  for (std::size_t index = 0; index < count; ++index) {
    const auto &source = dataset[index];
    views[index] = {.id = source.id,
                    .name = source.name,
                    .category = source.category,
                    .price = source.price,
                    .quantity = source.quantity,
                    .active = source.active,
                    .tags = source.tags,
                    .rating_value = source.rating_value,
                    .total = source.price * source.quantity * multiplier};
  }

  auto encoded = cnetmod::json::write(arena::item_view_list{
      .items = std::span{views.data(), count}, .count = count});
  if (!encoded) {
    request.text(http::status::internal_server_error, "serialization failed");
    return;
  }
  request.json(http::status::ok, std::move(*encoded));
}

auto get_sum(std::span<const std::byte> payload)
    -> std::expected<grpc::byte_buffer, grpc::status> {
  std::uint32_t left{}, right{};
  auto decoded = grpc::proto::visit_message(
      payload, [&](const grpc::proto::field_view &field) {
        if (field.type != grpc::proto::wire_type::varint)
          return;
        if (field.number == 1)
          left = static_cast<std::uint32_t>(field.varint_value);
        else if (field.number == 2)
          right = static_cast<std::uint32_t>(field.varint_value);
      });
  if (!decoded)
    return std::unexpected(grpc::make_status(
        grpc::status_code::invalid_argument, "invalid SumRequest"));

  grpc::byte_buffer response;
  const auto result = std::bit_cast<std::int32_t>(left + right);
  if (result != 0)
    grpc::proto::append_int64(response, 1, result);
  return response;
}

auto echo(ws::ws_context &connection) -> cn::task<void> {
  (void)co_await connection.raw_connection().async_process_messages(
      [](ws::opcode op, std::span<const std::byte> payload,
         ws::message_writer &output) -> std::expected<void, std::error_code> {
        return output.send(op, payload);
      });
}

auto make_router(grpc::service_router &grpc_service, bool websocket,
                 const std::vector<arena::item> &dataset,
                 postgres_shards &database, redis_cache &cache)
    -> http::router {
  http::router routes;
  routes.get("/static/*filepath", http::serve_dir({.root = "/data/static"}));
  routes.get_sync("/baseline11", baseline);
  routes.post_sync("/baseline11", baseline);
  routes.get_sync("/baseline2", baseline);
  routes.get_sync("/pipeline", [](http::request_context &request) {
    request.text(http::status::ok, "ok");
  });
  routes.get("/delay/:ms",
             [](http::request_context &request) -> cn::task<void> {
               const auto delay = parse_integer(request.param("ms"));
               if (delay < 0 || delay > 60'000) {
                 request.text(http::status::bad_request, "invalid delay");
                 co_return;
               }
               co_await cn::async_sleep(request.io_ctx(),
                                        std::chrono::milliseconds{delay});
               respond_integer(request, delay);
             });

  auto compression =
      cn::compress({.min_size = 1,
                    .level = 6,
                    .brotli_quality = 2,
                    .max_concurrency = 256});
  routes.get("/json/:count",
             [&dataset, compression = std::move(compression)](
                 http::request_context &request) mutable -> cn::task<void> {
               co_await compression(request,
                                    [&request, &dataset]() -> cn::task<void> {
                                      json_response(request, dataset);
                                      co_return;
                                    });
             });
  routes.get_sync("/public/baseline", baseline);
  routes.get_sync("/public/json/:count",
                  [&dataset](http::request_context &request) {
                    json_response(request, dataset);
                  });

  routes.post_sync("/echo", [](http::request_context &request) {
    request.resp()
        .set_status(http::status::ok)
        .set_header("Content-Type", "application/octet-stream")
        .set_body(request.body());
  });
  routes.get("/async-db",
             [&database](http::request_context &request) -> cn::task<void> {
               co_await async_database(request, database);
             });
  routes.get(
      "/api/items/:id",
      [&database, &cache](http::request_context &request) -> cn::task<void> {
        co_await api_item_get(request, database, cache);
      });
  routes.post(
      "/api/items/:id",
      [&database, &cache](http::request_context &request) -> cn::task<void> {
        co_await api_item_update(request, database, cache);
      });
  routes.get(
      "/api/me",
      [&database, &cache](http::request_context &request) -> cn::task<void> {
        co_await api_me(request, database, cache);
      });
  routes.any_sync("/benchmark.BenchmarkService/GetSum",
                  grpc_service.make_http_sync_handler());
  if (websocket) {
    routes.get("/ws", [](http::request_context &request) -> cn::task<void> {
      auto accepted = ws::accept_upgrade(request, echo);
      if (!accepted)
        request.text(http::status::bad_request, "Bad WebSocket handshake");
      co_return;
    });
  }
  return routes;
}

void configure_server(http::server &server, grpc::service_router &service,
                      bool websocket, const std::vector<arena::item> &dataset,
                      postgres_shards &database, redis_cache &cache) {
  server.set_response_header_options(
      {.emit_server = false, .emit_date = false});
  server.set_router(make_router(service, websocket, dataset, database, cache));
  server.set_h2_sync_adapter(service.make_h2_sync_handler(),
                             service.make_h2_request_filter());
}

[[nodiscard]] auto available_processors() -> std::vector<unsigned> {
  std::vector<unsigned> eligible;
#ifdef __linux__
  cpu_set_t affinity;
  CPU_ZERO(&affinity);
  if (::sched_getaffinity(0, sizeof(affinity), &affinity) == 0) {
    for (unsigned processor = 0; processor < CPU_SETSIZE; ++processor)
      if (CPU_ISSET(processor, &affinity))
        eligible.push_back(processor);
  }
#endif
  if (eligible.empty()) {
    const auto count = std::max(std::thread::hardware_concurrency(), 1U);
    eligible.resize(count);
    std::iota(eligible.begin(), eligible.end(), 0U);
  }

#ifdef __linux__
  auto read_topology_id =
      [](unsigned processor,
         std::string_view field) -> std::optional<unsigned> {
    std::ifstream input{std::format("/sys/devices/system/cpu/cpu{}/topology/{}",
                                    processor, field)};
    unsigned value{};
    if (input >> value)
      return value;
    return std::nullopt;
  };

  std::set<std::pair<unsigned, unsigned>> physical_cores;
  std::vector<unsigned> primary_threads;
  std::vector<unsigned> sibling_threads;
  primary_threads.reserve(eligible.size());
  sibling_threads.reserve(eligible.size());
  for (const auto processor : eligible) {
    const auto package = read_topology_id(processor, "physical_package_id");
    const auto core = read_topology_id(processor, "core_id");
    if (!package || !core || physical_cores.emplace(*package, *core).second)
      primary_threads.push_back(processor);
    else
      sibling_threads.push_back(processor);
  }

  // One worker per assigned logical CPU. The benchmark gives the server both
  // SMT threads of each core, and the I/O-bound workers scale across them.
  // Primary threads come first so a smaller CNETMOD_HTTP_WORKERS keeps one
  // worker per physical core before doubling up on a sibling.
  primary_threads.insert(primary_threads.end(), sibling_threads.begin(),
                         sibling_threads.end());
  if (const auto *configured = std::getenv("CNETMOD_HTTP_WORKERS")) {
    unsigned requested{};
    const auto text = std::string_view{configured};
    const auto [end, error] =
        std::from_chars(text.data(), text.data() + text.size(), requested);
    if (error == std::errc{} && end == text.data() + text.size() &&
        requested > 0 && requested <= eligible.size())
      primary_threads.resize(requested);
  }

  if (!primary_threads.empty())
    return primary_threads;
#endif
  return eligible;
}

auto listen(http::server &server, std::uint16_t port) -> bool {
  auto result = server.listen("0.0.0.0", port,
                              {.reuse_address = true, .no_delay = true}, 4096);
  if (!result)
    logger::error{"listen {} failed: {}", port, result.error().message()};
  return result.has_value();
}

[[nodiscard]] auto environment_port(const char *name,
                                    std::uint16_t fallback) noexcept
    -> std::uint16_t {
  const auto *configured = std::getenv(name);
  if (configured == nullptr)
    return fallback;
  const auto text = std::string_view{configured};
  unsigned value{};
  const auto [end, error] =
      std::from_chars(text.data(), text.data() + text.size(), value);
  if (error != std::errc{} || end != text.data() + text.size() || value == 0 ||
      value > std::numeric_limits<std::uint16_t>::max())
    return fallback;
  return static_cast<std::uint16_t>(value);
}

} // namespace

auto main() -> int {
  cn::net_init network;
  logger::init("cnetmod-httparena", logger::level::warn);

  auto processors = available_processors();
  cn::server_context runtime{
      static_cast<unsigned>(processors.size()),
      1U,
      {.enabled = true, .worker_processors = std::move(processors)}};
  postgres_shards database{runtime};
  redis_cache cache{runtime};

  grpc::service_router grpc_service;
  grpc_service.add_unary_sync("benchmark.BenchmarkService", "GetSum", get_sum);

  auto dataset = load_dataset();
  if (!dataset || dataset->size() != 50U) {
    logger::error{"failed to load the HttpArena JSON dataset"};
    logger::shutdown();
    return 2;
  }

  http::server public_server{runtime};
  http::server h2c_server{runtime};
  http::server h1_tls_server{runtime};
  http::server h2_tls_server{runtime};
  std::unique_ptr<http::server> probe_server;
  configure_server(public_server, grpc_service, true, *dataset, database,
                   cache);
  configure_server(h2c_server, grpc_service, false, *dataset, database, cache);
  configure_server(h1_tls_server, grpc_service, false, *dataset, database,
                   cache);
  configure_server(h2_tls_server, grpc_service, false, *dataset, database,
                   cache);

  const auto public_port = environment_port("H1_PORT", 8080);
  const auto h2c_port = environment_port("H2C_PORT", 8082);
  const auto probe_port = environment_port("H1_PROBE_PORT", public_port);
  const auto has_certificates =
      std::filesystem::is_regular_file("/certs/server.crt") &&
      std::filesystem::is_regular_file("/certs/server.key");

  std::optional<cn::ssl_context> h1_tls;
  std::optional<cn::ssl_context> h2_tls;
  if (has_certificates) {
    auto h1_result = cn::ssl_context::server();
    auto h2_result = cn::ssl_context::server();
    if (!h1_result || !h2_result) {
      logger::error{"failed to create HttpArena TLS context"};
      logger::shutdown();
      return 2;
    }
    h1_tls.emplace(std::move(*h1_result));
    h2_tls.emplace(std::move(*h2_result));
    if (!h1_tls->load_cert_file("/certs/server.crt") ||
        !h1_tls->load_key_file("/certs/server.key") ||
        !h2_tls->load_cert_file("/certs/server.crt") ||
        !h2_tls->load_key_file("/certs/server.key")) {
      logger::error{"failed to load HttpArena TLS certificate"};
      logger::shutdown();
      return 2;
    }
    h1_tls->configure_alpn_server({"http/1.1"});
    h2_tls->configure_alpn_server({"h2"});
    h1_tls_server.set_ssl_context(*h1_tls);
    h2_tls_server.set_ssl_context(*h2_tls);
  }

  if (!listen(public_server, public_port) || !listen(h2c_server, h2c_port) ||
      (has_certificates &&
       (!listen(h1_tls_server, 8081) || !listen(h2_tls_server, 8443)))) {
    logger::shutdown();
    return 3;
  }

  if (probe_port != public_port) {
    probe_server = std::make_unique<http::server>(runtime);
    configure_server(*probe_server, grpc_service, false, *dataset, database,
                     cache);
    if (!listen(*probe_server, probe_port))
      probe_server.reset();
  }

  cn::spawn(runtime.accept_io(), public_server.run());
  cn::spawn(runtime.accept_io(), h2c_server.run());
  if (has_certificates) {
    cn::spawn(runtime.accept_io(), h1_tls_server.run());
    cn::spawn(runtime.accept_io(), h2_tls_server.run());
  }
  if (probe_server)
    cn::spawn(runtime.accept_io(), probe_server->run());
  if (cache.enabled())
    cache.start();
  runtime.run();
  logger::shutdown();
  return 0;
}
