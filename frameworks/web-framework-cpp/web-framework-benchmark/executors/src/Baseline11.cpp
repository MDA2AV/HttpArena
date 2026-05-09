#include "Baseline11.hpp"

#include <charconv>

namespace executor
{
	void Baseline11::parseValues(framework::HttpRequest& request, int& a, int& b)
	{
		const std::unordered_map<std::string, std::string>& queryParameters = request.getQueryParameters();

		{
			const std::string& temp = queryParameters.at("a");

			std::from_chars(temp.data(), temp.data() + temp.size(), a);
		}
		
		{
			const std::string& temp = queryParameters.at("b");

			std::from_chars(temp.data(), temp.data() + temp.size(), b);
		}
	}

	void Baseline11::doGet(framework::HttpRequest& request, framework::HttpResponse& response)
	{
		int a;
		int b;

		Baseline11::parseValues(request, a, b);

		response.setBody(std::to_string(a + b));
	}

	void Baseline11::doPost(framework::HttpRequest& request, framework::HttpResponse& response)
	{
		const framework::HttpRequest::HeadersMap& headers = request.getHeaders();

		int a;
		int b;
		int c;

		Baseline11::parseValues(request, a, b);

		if (headers.contains("Transfer-Encoding"))
		{
			std::string_view chunk = request.getChunks()[0];

			std::from_chars(chunk.data(), chunk.data() + chunk.size(), c);
		}
		else
		{
			std::string_view body = request.getBody();

			std::from_chars(body.data(), body.data() + body.size(), c);
		}

		response.setBody(std::to_string(a + b + c));
	}

	DEFINE_EXECUTOR(Baseline11);
}
