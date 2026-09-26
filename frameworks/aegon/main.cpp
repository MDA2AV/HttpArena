#include <sys/resource.h>
#include <aegon/http/Server.h>
#include <aegon/http/middleware/Compress.h>
#include <aegon/core/Task.h>
#include <aegon/core/EventLoop.h>
#include <glaze/glaze.hpp>
#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <string_view>
#include <span>
#include <array>
#include <vector>
#include <charconv>
#include <cctype>
#include <thread>
#include <chrono>
#include <filesystem>
#include <memory>
#include <algorithm>
#include <sched.h>

using namespace aegon::http;

namespace {

struct Rating {
    int64_t score{0};
    int64_t count{0};
};

struct DatasetItem {
    int64_t id{0};
    std::string name;
    std::string category;
    int64_t price{0};
    int64_t quantity{0};
    bool active{false};
    std::vector<std::string> tags;
    Rating rating;
};

// Zero-copy view into dataset item with per-request total calculation
struct ProcessedItem {
    int64_t id{0};
    std::string_view name;
    std::string_view category;
    int64_t price{0};
    int64_t quantity{0};
    int64_t total{0};
    bool active{false};
    std::span<const std::string> tags;
    Rating rating;
};

struct JsonPayload {
    int count{0};
    std::span<const ProcessedItem> items;
};

static std::vector<DatasetItem> g_dataset;
inline thread_local std::array<ProcessedItem, 128> tls_processed_items;

static void load_dataset() {
    std::vector<std::string> paths = {
        "/data/dataset.json",
        "data/dataset.json",
        "../data/dataset.json"
    };

    std::string content;
    for (const auto& p : paths) {
        std::ifstream f(p);
        if (f.is_open()) {
            std::ostringstream ss;
            ss << f.rdbuf();
            content = ss.str();
            break;
        }
    }

    if (content.empty()) {
        std::cerr << "Warning: Could not open dataset.json" << std::endl;
        return;
    }

    auto ec = glz::read_json(g_dataset, content);
    if (ec) {
        std::cerr << "Failed to parse dataset.json: " << glz::format_error(ec, content) << std::endl;
    }
}

void handle_baseline_get(Context& ctx) {
    int64_t sum = 0;
    std::string_view q = ctx.req().query();
    while (!q.empty()) {
        size_t amp = q.find('&');
        std::string_view pair = (amp != std::string_view::npos) ? q.substr(0, amp) : q;
        size_t eq = pair.find('=');
        if (eq != std::string_view::npos) {
            int64_t val = 0;
            std::from_chars(pair.data() + eq + 1, pair.data() + pair.size(), val);
            sum += val;
        }
        if (amp == std::string_view::npos) break;
        q.remove_prefix(amp + 1);
    }
    char buf[32];
    auto [p, _] = std::to_chars(buf, buf + sizeof(buf), sum);
    ctx.res().text(std::string_view(buf, p - buf));
}

void handle_baseline_post(Context& ctx) {
    int64_t sum = 0;
    std::string_view q = ctx.req().query();
    while (!q.empty()) {
        size_t amp = q.find('&');
        std::string_view pair = (amp != std::string_view::npos) ? q.substr(0, amp) : q;
        size_t eq = pair.find('=');
        if (eq != std::string_view::npos) {
            int64_t val = 0;
            std::from_chars(pair.data() + eq + 1, pair.data() + pair.size(), val);
            sum += val;
        }
        if (amp == std::string_view::npos) break;
        q.remove_prefix(amp + 1);
    }
    std::string_view body = ctx.req().body();
    while (!body.empty() && std::isspace(static_cast<unsigned char>(body.front()))) body.remove_prefix(1);
    while (!body.empty() && std::isspace(static_cast<unsigned char>(body.back()))) body.remove_suffix(1);
    if (!body.empty()) {
        int64_t body_val = 0;
        auto [ptr, ec] = std::from_chars(body.data(), body.data() + body.size(), body_val);
        if (ec == std::errc()) {
            sum += body_val;
        }
    }
    char buf[32];
    auto [p, _] = std::to_chars(buf, buf + sizeof(buf), sum);
    ctx.res().text(std::string_view(buf, p - buf));
}

aegon::core::Task<void> handle_delay(Context& ctx) {
    uint64_t ms = 0;
    if (auto ms_str = ctx.req().param("ms")) {
        std::from_chars(ms_str->data(), ms_str->data() + ms_str->size(), ms);
    }
    if (ms > 0) {
        co_await aegon::core::EventLoop::current()->ring().timeout(ms * 1'000'000ULL);
    }
    char buf[32];
    auto [p, _] = std::to_chars(buf, buf + sizeof(buf), ms);
    ctx.res().text(std::string_view(buf, p - buf));
}

void register_routes(Router& router) {
    // 1. Pipeline endpoint
    router.get("/pipeline", [](Context& ctx) {
        ctx.res().text("ok");
    });

    // 2. Baseline endpoints (HTTP/1.1)
    router.get("/baseline11", handle_baseline_get);
    router.post("/baseline11", handle_baseline_post);

    // 3. Baseline endpoints (HTTP/2)
    router.get("/baseline2", handle_baseline_get);
    router.post("/baseline2", handle_baseline_post);

    // 4. Async delay endpoint (non-blocking io_uring timeout coroutine)
    router.get("/delay/:ms", handle_delay);

    // 5. JSON serialization & compression endpoint (zero-copy view)
    router.get("/json/:count", {aegon::http::middleware::Compress({
        .min_size = 64,
        .gzip = true,
        .deflate = true,
        .prefer_deflate = false
    })}, [](Context& ctx) {
        size_t count = 0;
        if (auto count_str = ctx.req().param("count")) {
            std::from_chars(count_str->data(), count_str->data() + count_str->size(), count);
        }
        int64_t m = 1;
        if (auto m_str = ctx.req().query_param("m")) {
            std::from_chars(m_str->data(), m_str->data() + m_str->size(), m);
        }

        size_t n = std::min(count, std::min(g_dataset.size(), tls_processed_items.size()));
        for (size_t i = 0; i < n; ++i) {
            const auto& d = g_dataset[i];
            tls_processed_items[i] = ProcessedItem{
                .id = d.id,
                .name = d.name,
                .category = d.category,
                .price = d.price,
                .quantity = d.quantity,
                .total = d.price * d.quantity * m,
                .active = d.active,
                .tags = std::span<const std::string>(d.tags.data(), d.tags.size()),
                .rating = d.rating
            };
        }

        JsonPayload payload{
            .count = static_cast<int>(n),
            .items = std::span<const ProcessedItem>(tls_processed_items.data(), n)
        };
        ctx.res().json(payload);
    });

    // 6. Echo endpoint (8gbit)
    router.post("/echo", [](Context& ctx) {
        ctx.res().header("Content-Type", "application/octet-stream");
        ctx.res().body(std::string(ctx.req().body()));
    });

    // 7. Static file serving (static-h2, static-h3) - Aegon core static_files API
    const char* static_dir = std::filesystem::exists("/data/static") ? "/data/static" : "data/static";
    router.static_files("/static", static_dir);

    // 8. WebSocket Echo endpoint
    router.ws("/ws");
}

unsigned int cgroup_cpus() {
    unsigned int quota_limit = 0;

    // 1. cgroup v2: /sys/fs/cgroup/cpu.max contains "<quota> <period>" or "max <period>"
    {
        std::ifstream f("/sys/fs/cgroup/cpu.max");
        if (f.is_open()) {
            std::string quota, period;
            if (f >> quota >> period && quota != "max" && !period.empty()) {
                long long q = std::strtoll(quota.c_str(), nullptr, 10);
                long long p = std::strtoll(period.c_str(), nullptr, 10);
                if (p > 0 && q > 0) {
                    quota_limit = static_cast<unsigned int>(q / p);
                }
            }
        }
    }

    // 2. cgroup v1: /sys/fs/cgroup/cpu/cpu.cfs_quota_us and cpu.cfs_period_us
    if (quota_limit == 0) {
        std::ifstream qf("/sys/fs/cgroup/cpu/cpu.cfs_quota_us");
        std::ifstream pf("/sys/fs/cgroup/cpu/cpu.cfs_period_us");
        if (qf.is_open() && pf.is_open()) {
            long long q = -1, p = -1;
            if (qf >> q && pf >> p && q > 0 && p > 0) {
                quota_limit = static_cast<unsigned int>(q / p);
            }
        }
    }

    // 3. CPU affinity mask (e.g. taskset or container cpuset)
    unsigned int affinity_limit = 0;
    cpu_set_t cs;
    CPU_ZERO(&cs);
    if (sched_getaffinity(0, sizeof(cs), &cs) == 0) {
        int count = CPU_COUNT(&cs);
        if (count > 0) {
            affinity_limit = static_cast<unsigned int>(count);
        }
    }

    // 4. Fallback to hardware concurrency
    unsigned int hw = std::thread::hardware_concurrency();
    if (hw == 0) hw = 1;

    unsigned int effective = hw;
    if (affinity_limit > 0 && affinity_limit < effective) {
        effective = affinity_limit;
    }
    if (quota_limit > 0 && quota_limit < effective) {
        effective = quota_limit;
    }

    return std::max(1u, effective);
}

} // namespace

int main() {
    load_dataset();

    unsigned int threads = cgroup_cpus();

    const std::string certFile = "/certs/server.crt";
    const std::string keyFile = "/certs/server.key";
    bool has_certs = std::filesystem::exists(certFile) && std::filesystem::exists(keyFile);

    struct rlimit rl{};
    bool low_memlock = false;
    if (getrlimit(RLIMIT_MEMLOCK, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur < 64 * 1024 * 1024) {
        low_memlock = true;
    }

    Server server;
    if (low_memlock) {
        server.ring_entries(512);
        server.buffer_pool_entries(256);
    } else {
        server.ring_entries(8192);
        server.buffer_pool_entries(16384);
    }
    register_routes(server.router());

    // Port 8080: Plaintext HTTP/1.1 (main benchmarks)
    server.listen(8080);
    // Port 8082: Plaintext HTTP/2 prior-knowledge (baseline-h2c, json-h2c)
    server.listen(8082);

    if (has_certs) {
        server.enable_tls(certFile, keyFile);
        server.enable_http3(true);
        // Port 8081: TLS HTTP/1.1 (json-tls, 8gbit)
        server.listen_tls(8081);
        // Port 8443: TLS HTTP/2 & HTTP/3 (baseline-h2, static-h2, baseline-h3, static-h3)
        server.listen_tls(8443);
    }

    server.run(threads);

    return 0;
}
