using Framework;
using Framework.Utility;

try
{
	Config config = new("config.json");

	string? threads = Environment.GetEnvironmentVariable("THREADS");

	if (threads != null)
	{
		int value = int.Parse(threads);

		if (value > 8)
		{
			config.OverrideConfiguration("threadCount", value - 8);
		}
	}

	threads = Environment.GetEnvironmentVariable("H2THREADS");

	if (threads != null)
	{
		// TODO: HTTP/2.0
	}

	WebFramework server = new(config);

	server.Start(true, () => Console.WriteLine("Server is running..."));
}
catch (Exception e)
{
	Console.WriteLine(e.Message);

	Environment.Exit(1);
}
