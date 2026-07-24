using System.IO.Pipelines;

namespace Minima;

public sealed class ConnectionDualPipe : IDuplexPipe
{
    public PipeReader Input { get; }
    public PipeWriter Output { get; }

    public ConnectionDualPipe(Connection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        Input = new ConnectionPipeReader(connection);
        Output = new ConnectionPipeWriter(connection);
    }
}