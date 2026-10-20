#include <cnetmod/config.hpp>
#ifdef __linux__
#include <sched.h>
#endif

import std;
import cnetmod.core.log;
import cnetmod.core.net_init;
import cnetmod.core.ssl;
import cnetmod.coro.spawn;
import cnetmod.coro.task;
import cnetmod.executor.pool;
import cnetmod.protocol.grpc;
import cnetmod.protocol.http;
import cnetmod.protocol.websocket;

namespace cn = cnetmod;
namespace grpc = cnetmod::grpc;
namespace http = cnetmod::http;
namespace ws = cnetmod::ws;

namespace {

[[nodiscard]] auto parse_integer(std::string_view text) noexcept
    -> std::int64_t
{
    std::int64_t value{};
    const auto [end, error] =
        std::from_chars(text.data(), text.data() + text.size(), value);
    return error == std::errc{} && end == text.data() + text.size()
        ? value
        : 0;
}

[[nodiscard]] auto sum_query(std::string_view query) noexcept -> std::int64_t
{
    std::int64_t sum{};
    while (!query.empty())
    {
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

void respond_integer(http::request_context& request, std::int64_t value)
{
    std::array<char, 32> storage{};
    const auto [end, error] =
        std::to_chars(storage.data(), storage.data() + storage.size(), value);
    if (error != std::errc{})
    {
        request.text(http::status::internal_server_error,
            "conversion failed");
        return;
    }
    request.text(http::status::ok,
        std::string_view{storage.data(),
            static_cast<std::size_t>(end - storage.data())});
}

void baseline(http::request_context& request)
{
    auto sum = sum_query(request.query_string());
    if (request.method_enum() == http::http_method::POST)
        sum += parse_integer(request.body());
    respond_integer(request, sum);
}

auto get_sum(std::span<const std::byte> payload)
    -> std::expected<grpc::byte_buffer, grpc::status>
{
    std::uint32_t left{}, right{};
    auto decoded = grpc::proto::visit_message(payload,
        [&](const grpc::proto::field_view& field)
        {
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

auto echo(ws::ws_context& connection) -> cn::task<void>
{
    (void)co_await connection.raw_connection().async_process_messages(
        [](ws::opcode op, std::span<const std::byte> payload,
            ws::message_writer& output)
            -> std::expected<void, std::error_code>
        {
            return output.send(op, payload);
        });
}

auto make_router(grpc::service_router& grpc_service, bool websocket)
    -> http::router
{
    http::router routes;
    routes.get_sync("/baseline11", baseline);
    routes.post_sync("/baseline11", baseline);
    routes.get_sync("/baseline2", baseline);
    routes.get_sync("/pipeline", [](http::request_context& request)
        { request.text(http::status::ok, "ok"); });
    routes.any_sync("/benchmark.BenchmarkService/GetSum",
        grpc_service.make_http_sync_handler());
    if (websocket)
    {
        routes.get("/ws", [](http::request_context& request)
            -> cn::task<void>
            {
                auto accepted = ws::accept_upgrade(request, echo);
                if (!accepted)
                    request.text(http::status::bad_request,
                        "Bad WebSocket handshake");
                co_return;
            });
    }
    return routes;
}

void configure_server(http::server& server, grpc::service_router& service,
    bool websocket)
{
    server.set_response_header_options(
        {.emit_server = false, .emit_date = false});
    server.set_router(make_router(service, websocket));
    server.set_h2_sync_adapter(service.make_h2_sync_handler(),
        service.make_h2_request_filter());
}

[[nodiscard]] auto available_processors() -> std::vector<unsigned>
{
    std::vector<unsigned> processors;
#ifdef __linux__
    cpu_set_t affinity;
    CPU_ZERO(&affinity);
    if (::sched_getaffinity(0, sizeof(affinity), &affinity) == 0)
    {
        for (unsigned processor = 0; processor < CPU_SETSIZE; ++processor)
            if (CPU_ISSET(processor, &affinity))
                processors.push_back(processor);
    }
#endif
    if (processors.empty())
    {
        const auto count = std::max(std::thread::hardware_concurrency(), 1U);
        processors.resize(count);
        std::iota(processors.begin(), processors.end(), 0U);
    }
    return processors;
}

auto listen(http::server& server, std::uint16_t port) -> bool
{
    auto result = server.listen("0.0.0.0", port,
        {.reuse_address = true, .no_delay = true}, 4096);
    if (!result)
        logger::error{"listen {} failed: {}", port, result.error().message()};
    return result.has_value();
}

} // namespace

auto main() -> int
{
    cn::net_init network;
    logger::init("cnetmod-httparena", logger::level::warn);

    auto processors = available_processors();
    cn::server_context runtime{static_cast<unsigned>(processors.size()), 1U,
        {.enabled = true, .worker_processors = std::move(processors)}};

    grpc::service_router grpc_service;
    grpc_service.add_unary_sync(
        "benchmark.BenchmarkService", "GetSum", get_sum);

    http::server public_server{runtime};
    http::server h2c_server{runtime};
    http::server h1_tls_server{runtime};
    http::server h2_tls_server{runtime};
    configure_server(public_server, grpc_service, true);
    configure_server(h2c_server, grpc_service, false);
    configure_server(h1_tls_server, grpc_service, false);
    configure_server(h2_tls_server, grpc_service, false);

    auto h1_tls = cn::ssl_context::server();
    auto h2_tls = cn::ssl_context::server();
    if (!h1_tls || !h2_tls ||
        !h1_tls->load_cert_file("/certs/server.crt") ||
        !h1_tls->load_key_file("/certs/server.key") ||
        !h2_tls->load_cert_file("/certs/server.crt") ||
        !h2_tls->load_key_file("/certs/server.key"))
    {
        logger::error{"failed to load HttpArena TLS certificate"};
        logger::shutdown();
        return 2;
    }
    h1_tls->configure_alpn_server({"http/1.1"});
    h2_tls->configure_alpn_server({"h2"});
    h1_tls_server.set_ssl_context(*h1_tls);
    h2_tls_server.set_ssl_context(*h2_tls);

    if (!listen(public_server, 8080) || !listen(h1_tls_server, 8081) ||
        !listen(h2c_server, 8082) || !listen(h2_tls_server, 8443))
    {
        logger::shutdown();
        return 3;
    }

    cn::spawn(runtime.accept_io(), public_server.run());
    cn::spawn(runtime.accept_io(), h1_tls_server.run());
    cn::spawn(runtime.accept_io(), h2c_server.run());
    cn::spawn(runtime.accept_io(), h2_tls_server.run());
    runtime.run();
    logger::shutdown();
    return 0;
}
