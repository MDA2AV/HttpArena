#include <aegon/http/Server.h>
#include <aegon/http/middleware/Compress.h>
#include <glaze/glaze.hpp>
#include <iostream>
#include <fstream>
#include <string>
#include <string_view>
#include <vector>
#include <charconv>
#include <thread>
#include <chrono>
#include <filesystem>
#include <memory>

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
    int64_t total{0};
    bool active{false};
    std::vector<std::string> tags;
    Rating rating;
};

struct JsonPayload {
    int count{0};
    std::vector<DatasetItem> items;
};

std::vector<DatasetItem> g_dataset;

void load_dataset() {
    const char* env = std::getenv("DATASET_PATH");
    std::string path = env ? env : "/data/dataset.json";
    std::ifstream file(path);
    if (!file) {
        std::cerr << "Warning: Could not open dataset at " << path << "\n";
        return;
    }
    std::string content((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    auto err = glz::read<glz::opts{.error_on_unknown_keys = false}>(g_dataset, content);
    if (err) {
        std::cerr << "Warning: Failed to parse dataset: " << glz::format_error(err, content) << "\n";
    } else {
        std::cout << "Loaded dataset with " << g_dataset.size() << " items\n";
    }
}

long long parse_long(std::string_view sv) noexcept {
    long long val = 0;
    if (sv.empty()) return 0;
    std::from_chars(sv.data(), sv.data() + sv.size(), val);
    return val;
}

long long compute_baseline_sum(const Request& req) {
    long long sum = 0;
    std::string_view q = req.query();
    while (!q.empty()) {
        size_t amp = q.find('&');
        std::string_view pair = (amp != std::string_view::npos) ? q.substr(0, amp) : q;
        size_t eq = pair.find('=');
        if (eq != std::string_view::npos) {
            std::string_view v = pair.substr(eq + 1);
            sum += parse_long(v);
        }
        if (amp == std::string_view::npos) break;
        q.remove_prefix(amp + 1);
    }
    if (req.method() == Method::POST && !req.body().empty()) {
        sum += parse_long(req.body());
    }
    return sum;
}

void register_routes(Router& router) {
    // 1. Pipeline endpoint
    router.get("/pipeline", [](Context& ctx) {
        ctx.res().text("ok");
    });

    // 2. Baseline endpoints (HTTP/1.1)
    router.get("/baseline11", [](Context& ctx) {
        ctx.res().text(std::to_string(compute_baseline_sum(ctx.req())));
    });
    router.post("/baseline11", [](Context& ctx) {
        ctx.res().text(std::to_string(compute_baseline_sum(ctx.req())));
    });

    // 3. Baseline endpoints (HTTP/2)
    router.get("/baseline2", [](Context& ctx) {
        ctx.res().text(std::to_string(compute_baseline_sum(ctx.req())));
    });
    router.post("/baseline2", [](Context& ctx) {
        ctx.res().text(std::to_string(compute_baseline_sum(ctx.req())));
    });

    // 4. Delay endpoint (async wait)
    router.get("/delay/:ms", [](Context& ctx) {
        auto ms_param = ctx.req().param("ms").value_or("0");
        long long ms = parse_long(ms_param);
        if (ms <= 0) {
            ctx.res().text("0");
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(ms));
        ctx.res().text(std::to_string(ms));
    });

    // 5. JSON serialization & compression endpoint
    router.get("/json/:count", [](Context& ctx) {
        auto count_str = ctx.req().param("count").value_or("0");
        int count = static_cast<int>(parse_long(count_str));
        if (count < 0) count = 0;
        if (count > static_cast<int>(g_dataset.size())) count = static_cast<int>(g_dataset.size());

        long long m = 1;
        if (auto m_str = ctx.req().query_param("m")) {
            m = parse_long(*m_str);
        }

        JsonPayload payload;
        payload.count = count;
        payload.items.reserve(static_cast<size_t>(count));

        for (int i = 0; i < count; ++i) {
            DatasetItem item = g_dataset[static_cast<size_t>(i)];
            item.total = item.price * item.quantity * m;
            payload.items.push_back(std::move(item));
        }

        ctx.res().json(payload);
    });

    // 6. Echo endpoint (8gbit)
    router.post("/echo", [](Context& ctx) {
        ctx.res().header("Content-Type", "application/octet-stream");
        ctx.res().body(std::string(ctx.req().body()));
    });
}

} // namespace

int main() {
    load_dataset();

    unsigned int threads = std::thread::hardware_concurrency();
    if (threads == 0) threads = 4;

    const std::string certFile = "/certs/server.crt";
    const std::string keyFile = "/certs/server.key";
    bool has_certs = std::filesystem::exists(certFile) && std::filesystem::exists(keyFile);

    std::vector<std::thread> server_threads;
    std::unique_ptr<Server> server8081;
    std::unique_ptr<Server> server8443;

    if (has_certs) {
        // Port 8081: TLS HTTP/1.1 (for json-tls, 8gbit)
        server8081 = std::make_unique<Server>();
        register_routes(server8081->router());
        server8081->enable_tls(certFile, keyFile);
        server8081->listen(8081);
        server_threads.emplace_back([&]() {
            server8081->run(threads);
        });

        // Port 8443: TLS HTTP/2 (for baseline-h2)
        server8443 = std::make_unique<Server>();
        register_routes(server8443->router());
        server8443->enable_tls(certFile, keyFile);
        server8443->listen(8443);
        server_threads.emplace_back([&]() {
            server8443->run(threads);
        });
    }

    // Port 8080: HTTP/1.1 (main server)
    Server server8080;
    server8080.use(middleware::Compress(middleware::CompressOptions{
        .min_size = 64,
        .gzip = true,
        .deflate = true,
        .prefer_deflate = false
    }));
    register_routes(server8080.router());
    server8080.listen(8080);
    server8080.run(threads);

    for (auto& t : server_threads) {
        if (t.joinable()) t.join();
    }

    return 0;
}
