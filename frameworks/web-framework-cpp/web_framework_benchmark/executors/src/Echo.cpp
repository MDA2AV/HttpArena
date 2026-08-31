#include "Echo.hpp"

#include <charconv>

namespace executor
{
	// The server hands a body of at least this size to the executor a packet at
	// a time instead of in one piece; it mirrors largeBodySizeThreshold in
	// config.json, and the benchmark's 100 KB body sits exactly on it.
	static constexpr size_t thresholdSize = 102400;

	static void sendEcho(framework::HttpResponse& response, std::string_view body)
	{
		// A body-less response is serialized as 204 with no Content-Length at
		// all, so the status and the framing of an empty echo have to be
		// spelled out here.
		response.setResponseCode(framework::ResponseCodes::ok);
		response.addHeader("Content-Type", "application/octet-stream");

		if (body.size())
		{
			response.setBody(body);
		}
		else
		{
			response.addHeader("Content-Length", "0");
		}
	}

	void Echo::doPost(framework::HttpRequest& request, framework::HttpResponse& response)
	{
		const framework::HttpRequest::HeadersMap& headers = request.getHeaders();

		if (headers.contains("Transfer-Encoding"))
		{
			// A chunked request carries no Content-Length, so the body only
			// exists as the decoded chunks: they are joined here, and the
			// response is framed from what they add up to.
			buffer.clear();

			for (const std::string& chunk : request.getChunks())
			{
				buffer += chunk;
			}

			sendEcho(response, buffer);

			return;
		}

		size_t contentLength = 0;

		if (auto it = headers.find("Content-Length"); it != headers.end())
		{
			std::from_chars(it->second.data(), it->second.data() + it->second.size(), contentLength);
		}

		if (contentLength >= thresholdSize)
		{
			// One packet per call, each pointing at a receive buffer that is
			// reused for the next one, so every packet has to be copied out as
			// it lands. The response can only be written once the last one has
			// arrived.
			const auto& [dataPart, isLastPacket] = request.getLargeData();

			buffer += dataPart;

			if (isLastPacket)
			{
				sendEcho(response, buffer);

				buffer.clear();
			}
		}
		else
		{
			sendEcho(response, request.getBody());
		}
	}

	DEFINE_EXECUTOR(Echo);
}
