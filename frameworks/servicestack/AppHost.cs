using Microsoft.AspNetCore.Server.Kestrel.Core;
using ServiceStack.Benchmarks;

[assembly: HostingStartup(typeof(AppHost))]
namespace ServiceStack.Benchmarks;

public class AppHost() : AppHostBase("ServiceStack.Benchmark", typeof(AppHost).Assembly), IHostingStartup
{
    
    public void Configure(IWebHostBuilder builder) => builder
        .ConfigureServices((_, services) =>
        {
            var poolFactory = PgPoolFactory.Open();

            if (poolFactory is not null)
            {
                services.AddSingleton(poolFactory);
            }
            
            services.Configure<KestrelServerOptions>(options =>
            {
                options.Limits.MaxRequestBodySize = 25 * 1024 * 1024;
            });
        });
    
    public override void Configure()
    {
        SetConfig(new HostConfig
        {
            EnableAutoHtmlResponses = false,
            EnableFeatures = Feature.All.Remove(Feature.Html | Feature.Metadata),
        });
    }
    
}
