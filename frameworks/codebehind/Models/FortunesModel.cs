using CodeBehind;

using HttpArena.Data;

namespace HttpArena.Models;

public sealed class FortunesModel : CodeBehindModel
{
    public IReadOnlyList<Fortune> Fortunes { get; init; } = [];
}
