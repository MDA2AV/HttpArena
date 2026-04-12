using ServiceStack;
using ServiceStack.Benchmarks;

[Route("/baseline11", "GET")]
public class Baseline11Get : IReturn<HttpResult>
{
    public int A { get; set; }
    public int B { get; set; }
}

[Route("/baseline11", "POST")]
public class Baseline11Post : IReturn<HttpResult>
{
    public int A { get; set; }
    public int B { get; set; }
}

[Route("/baseline2", "GET")]
public class Baseline2Get : IReturn<HttpResult>
{
    public int A { get; set; }
    public int B { get; set; }
}

[Route("/pipeline", "GET")]
public class PipelineGet : IReturn<string> { }

[Route("/upload", "POST")]
public class UploadPost : IReturn<HttpResult> { }

[Route("/json/{Count}", "GET")]
public class JsonGet : IReturn<ListWithCount<ProcessedItem>>
{
    public int Count { get; set; }
}

[Route("/db", "GET")]
public class DbGet : IReturn<ListWithCount<ProcessedItem>>
{
    public int Min { get; set; } = 10;
    public int Max { get; set; } = 50;
}

[Route("/async-db", "GET")]
public class AsyncDbGet : IReturn<ListWithCount<object>>
{
    public int Min { get; set; } = 10;
    public int Max { get; set; } = 50;
    public int Limit { get; set; } = 50;
}
