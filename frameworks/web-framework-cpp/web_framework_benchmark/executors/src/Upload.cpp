#include "Upload.hpp"

#include <charconv>

namespace executor
{
	Upload::Upload() :
		currentSize(0)
	{

	}

	void Upload::doPost(framework::HttpRequest& request, framework::HttpResponse& response)
	{
		constexpr size_t thresholdSize = 102400;

		const framework::HttpRequest::HeadersMap& headers = request.getHeaders();
		const std::string& temp = headers.at("Content-Length");
		size_t contentLength;

		std::from_chars(temp.data(), temp.data() + temp.size(), contentLength);
		
		if (contentLength >= thresholdSize)
		{
			const auto& [dataPart, isLastPacket] = request.getLargeData();

			currentSize += dataPart.size();

			if (isLastPacket)
			{
				response.setBody(std::to_string(currentSize));
			}
		}
		else
		{
			currentSize = request.getBody().size();

			response.setBody(std::to_string(currentSize));
		}
	}

	DEFINE_EXECUTOR(Upload);
}
