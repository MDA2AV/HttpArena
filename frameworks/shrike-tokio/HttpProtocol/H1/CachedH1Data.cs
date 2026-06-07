namespace Shrike;

internal static class CachedH1Data
{
    internal static readonly StringCache CachedRoutes 
        = new(null, 64);
    
    internal static readonly StringCache CachedQueryKeys 
        = new(null, 64);

    internal static readonly StringCache CachedHttpMethods
        = new([
                "GET",
                "POST",
                "PUT",
                "DELETE",
                "PATCH",
                "HEAD",
                "OPTIONS",
                "TRACE"], 
            8);
    
    internal static readonly StringCache CachedHeaderKeys 
        = new([
                "Host",
                "User-Agent",
                "Cookie",
                "Accept",
                "Accept-Language",
                "Connection"], 
            64);
    
    internal static readonly StringCache CachedHeaderValues
        = new([
                "keep-alive",
                "server"], 
            64);
}