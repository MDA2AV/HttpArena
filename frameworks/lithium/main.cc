// HttpArena entry for Lithium (header-only C++ HTTP framework).
#include <lithium_http_server.hh>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#ifndef LI_SYMBOL_id
#define LI_SYMBOL_id
LI_SYMBOL(id)
#endif
#ifndef LI_SYMBOL_name
#define LI_SYMBOL_name
LI_SYMBOL(name)
#endif
#ifndef LI_SYMBOL_category
#define LI_SYMBOL_category
LI_SYMBOL(category)
#endif
#ifndef LI_SYMBOL_price
#define LI_SYMBOL_price
LI_SYMBOL(price)
#endif
#ifndef LI_SYMBOL_quantity
#define LI_SYMBOL_quantity
LI_SYMBOL(quantity)
#endif
#ifndef LI_SYMBOL_active
#define LI_SYMBOL_active
LI_SYMBOL(active)
#endif
#ifndef LI_SYMBOL_tags
#define LI_SYMBOL_tags
LI_SYMBOL(tags)
#endif
#ifndef LI_SYMBOL_rating
#define LI_SYMBOL_rating
LI_SYMBOL(rating)
#endif
#ifndef LI_SYMBOL_score
#define LI_SYMBOL_score
LI_SYMBOL(score)
#endif
#ifndef LI_SYMBOL_count
#define LI_SYMBOL_count
LI_SYMBOL(count)
#endif
#ifndef LI_SYMBOL_total
#define LI_SYMBOL_total
LI_SYMBOL(total)
#endif
#ifndef LI_SYMBOL_items
#define LI_SYMBOL_items
LI_SYMBOL(items)
#endif
#ifndef LI_SYMBOL_m
#define LI_SYMBOL_m
LI_SYMBOL(m)
#endif

namespace {

struct Rating {
  int64_t score = 0;
  int64_t count = 0;
};

struct Item {
  int64_t id = 0;
  std::string name;
  std::string category;
  int64_t price = 0;
  int64_t quantity = 0;
  bool active = false;
  std::vector<std::string> tags;
  Rating rating;
};

// Field order is the wire order: id..rating then the computed total.
struct OutItem {
  int64_t id = 0;
  std::string name;
  std::string category;
  int64_t price = 0;
  int64_t quantity = 0;
  bool active = false;
  std::vector<std::string> tags;
  Rating rating;
  int64_t total = 0;
};

// Read once before the server starts, then only read from handlers, so every
// thread shares the one copy without locking.
std::vector<Item> g_dataset;

// json_vector(E&& element) stores decltype(element), so handing it a temporary
// makes it hold a dangling rvalue reference and the copy is deleted. Passing a
// named static instead deduces an lvalue reference to something that outlives
// every request.
const auto& item_vector() {
  static auto element = li::json_object(s::id, s::name, s::category, s::price,
                                        s::quantity, s::active, s::tags,
                                        s::rating = li::json_object(s::score, s::count));
  static auto vec = li::json_vector(element);
  return vec;
}

const auto& out_list() {
  static auto element = li::json_object(s::id, s::name, s::category, s::price,
                                        s::quantity, s::active, s::tags,
                                        s::rating = li::json_object(s::score, s::count),
                                        s::total);
  static auto vec = li::json_vector(element);
  static auto list = li::json_object(s::items = vec, s::count);
  return list;
}

void load_dataset() {
  const char* env = std::getenv("DATASET_PATH");
  const std::string path = env ? env : "/data/dataset.json";
  std::ifstream in(path, std::ios::binary);
  if (!in) return;  // no dataset is not fatal: /json answers with an empty list
  std::ostringstream ss;
  ss << in.rdbuf();
  const std::string text = ss.str();
  auto err = item_vector().decode(text, g_dataset);
  if (err.code) {
    std::fprintf(stderr, "dataset decode failed: %s\n", err.what.c_str());
    g_dataset.clear();
  }
}

/// Parses a base-10 integer, surrounding whitespace allowed. Returns false when
/// the text is not a number, so a non-numeric query parameter is just skipped.
bool try_parse(std::string_view s, int64_t& out) {
  size_t b = 0, e = s.size();
  while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) b++;
  while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) e--;
  if (b >= e) return false;
  bool neg = false;
  if (s[b] == '+' || s[b] == '-') { neg = (s[b] == '-'); b++; }
  if (b >= e) return false;
  int64_t acc = 0;
  for (size_t i = b; i < e; i++) {
    if (s[i] < '0' || s[i] > '9') return false;
    acc = acc * 10 + (s[i] - '0');
  }
  out = neg ? -acc : acc;
  return true;
}

int64_t sum_query(std::string_view q) {
  int64_t total = 0;
  size_t i = 0;
  while (i < q.size()) {
    size_t amp = q.find('&', i);
    if (amp == std::string_view::npos) amp = q.size();
    size_t eq = q.find('=', i);
    if (eq != std::string_view::npos && eq < amp) {
      int64_t n = 0;
      if (try_parse(q.substr(eq + 1, amp - eq - 1), n)) total += n;
    }
    i = amp + 1;
  }
  return total;
}

unsigned available_cores() {
  std::ifstream f("/sys/fs/cgroup/cpu.max");
  if (f) {
    std::string quota, period;
    f >> quota >> period;
    if (quota != "max" && !period.empty()) {
      long q = std::strtol(quota.c_str(), nullptr, 10);
      long p = std::strtol(period.c_str(), nullptr, 10);
      if (p > 0 && q / p >= 1) return static_cast<unsigned>(q / p);
    }
  }
  unsigned n = std::thread::hardware_concurrency();
  return n ? n : 1u;
}

li::http_api build_api() {
  li::http_api api;

  // One ANY route rather than a .get() and a .post(): lithium keys routes_map_
  // on the path alone, so registering the second verb silently replaces the
  // first and the other method 404s.
  api(li::http_api::ANY, "/baseline11") = [](li::http_request& req, li::http_response& res) {
    int64_t total = sum_query(req.http_ctx.get_parameters_string());
    int64_t n = 0;
    if (try_parse(req.http_ctx.read_whole_body(), n)) total += n;
    res.set_header("Content-Type", "text/plain");
    res.write(std::to_string(total));
  };

  api.get("/json/{{count}}") = [](li::http_request& req, li::http_response& res) {
    auto params = req.url_parameters(s::count = int());
    int64_t m = 1;
    {
      auto q = req.http_ctx.get_parameters_string();
      size_t i = 0;
      while (i < q.size()) {
        size_t amp = q.find('&', i);
        if (amp == std::string_view::npos) amp = q.size();
        if (amp - i >= 2 && q[i] == 'm' && q[i + 1] == '=') {
          int64_t v = 0;
          if (try_parse(q.substr(i + 2, amp - i - 2), v)) m = v;
          break;
        }
        i = amp + 1;
      }
    }

    size_t n = std::min<size_t>(params.count < 0 ? 0 : params.count, g_dataset.size());
    std::vector<OutItem> items;
    items.reserve(n);
    for (size_t i = 0; i < n; i++) {
      const Item& d = g_dataset[i];
      items.push_back(OutItem{d.id, d.name, d.category, d.price, d.quantity,
                              d.active, d.tags, d.rating, d.price * d.quantity * m});
    }
    res.set_header("Content-Type", "application/json");
    res.write(out_list().encode(li::mmm(s::items = items, s::count = (int)n)));
  };

  api.post("/upload") = [](li::http_request& req, li::http_response& res) {
    res.set_header("Content-Type", "text/plain");
    res.write(std::to_string(req.http_ctx.read_whole_body().size()));
  };

  return api;
}

}  // namespace

int main() {
  load_dataset();
  auto api = build_api();
  const unsigned threads = available_cores();

  // json-tls on 8081. The harness mounts /certs only for the TLS profiles, so a
  // missing pair leaves the listener down rather than aborting startup.
  const std::string cert = "/certs/server.crt";
  const std::string key = "/certs/server.key";
  std::ifstream cf(cert), kf(key);
  if (cf.good() && kf.good()) {
    std::thread([api, threads, cert, key]() mutable {
      li::http_serve(api, 8081, s::nthreads = threads,
                     s::ssl_key = key, s::ssl_certificate = cert);
    }).detach();
  }

  li::http_serve(api, 8080, s::nthreads = threads);
  return 0;
}
