#include <galay/cpp/galay-http/server/http_server.h>

#include <charconv>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <pthread.h>
#include <string>
#include <string_view>
#include <system_error>

namespace {

using galay::http::Http1_1ResponseBuilder;
using galay::http::HttpMethod;
using galay::http::HttpRequest;
using galay::http::HttpResponseResult;
using galay::kernel::Task;

std::optional<std::int32_t> parse_operand(std::string_view value)
{
    if (value.empty()) return std::nullopt;
    std::int32_t number{};
    const auto end = value.data() + value.size();
    const auto parsed = std::from_chars(value.data(), end, number);
    if (parsed.ec != std::errc{} || parsed.ptr != end) return std::nullopt;
    return number;
}

Task<HttpResponseResult> baseline(HttpRequest request)
{
    const auto& query = request.header().args();
    const auto left = query.find("a");
    const auto right = query.find("b");
    const auto first = left == query.end() ? std::nullopt : parse_operand(left->second);
    const auto second = right == query.end() ? std::nullopt : parse_operand(right->second);
    const auto body = request.header().method() == HttpMethod::POST
        ? parse_operand(request.body_str()) : std::optional<std::int32_t>{0};

    if (!first || !second || !body) {
        co_return Http1_1ResponseBuilder::bad_request().text("Invalid integer operand").build();
    }

    const auto sum = static_cast<std::int64_t>(*first) + *second + *body;
    co_return Http1_1ResponseBuilder::ok().text(std::to_string(sum)).build();
}

}

int main()
{
    sigset_t signals;
    if (sigemptyset(&signals) != 0 || sigaddset(&signals, SIGINT) != 0 || sigaddset(&signals, SIGTERM) != 0) {
        std::perror("signal set");
        return EXIT_FAILURE;
    }
    if (const int error = pthread_sigmask(SIG_BLOCK, &signals, nullptr); error != 0) {
        std::cerr << "pthread_sigmask: " << std::system_category().message(error) << '\n';
        return EXIT_FAILURE;
    }

    galay::http::HttpServerBuilder<> builder;
    if (const auto result = builder.add_request_handler<HttpMethod::GET, HttpMethod::POST>("/baseline11", baseline);
        !result) {
        std::cerr << result.error().message << '\n';
        return EXIT_FAILURE;
    }

    auto server = builder.build();
    if (!server) {
        std::cerr << server.error().message << '\n';
        return EXIT_FAILURE;
    }
    if (const auto result = (*server)->start(); !result) {
        std::cerr << result.error().message << '\n';
        return EXIT_FAILURE;
    }

    int signal_number{};
    if (const int error = sigwait(&signals, &signal_number); error != 0) {
        std::cerr << "sigwait: " << std::system_category().message(error) << '\n';
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
