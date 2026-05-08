#include "Static.hpp"

#include <filesystem>
#include <array>

namespace executor
{
	void Static::doGet(framework::HttpRequest& request, framework::HttpResponse& response)
	{
		constexpr std::array<std::pair<std::string_view, std::string_view>, 8> contentTypes =
		{
			std::make_pair(".css", "text/css"),
			std::make_pair(".js", "application/javascript"),
			std::make_pair(".html", "text/html"),
			std::make_pair(".woff2", "font/woff2"),
			std::make_pair(".svg", "image/svg+xml"),
			std::make_pair(".webp", "image/webp"),
			std::make_pair(".json", "application/json"),
			std::make_pair(".txt", "text/plain")
		};

		std::filesystem::path filePath = "static/" + request.getRouteParameter<std::string>("filePath");
		std::string extension = filePath.extension().string();
		std::string_view contentType = std::ranges::find_if(contentTypes, [&extension](const std::pair<std::string_view, std::string_view>& contentType) { return contentType.first == extension; })->second;

		response.addHeader("Content-Type", contentType);
		request.sendAssetFile(filePath.string(), response);
	}

	DEFINE_EXECUTOR(Static);
};
