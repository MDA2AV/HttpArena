using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

public sealed class FortunesModel : PageModel
{
    public List<Fortune> Fortunes { get; private set; } = [];

    public async Task<IActionResult> OnGetAsync()
    {
        if (AppData.PgDataSource is null)
            return new StatusCodeResult(500);

        var list = new List<Fortune>(201);
        await using (var cmd = AppData.PgDataSource.CreateCommand("SELECT id, message FROM fortune"))
        await using (var reader = await cmd.ExecuteReaderAsync())
        {
            while (await reader.ReadAsync())
            {
                list.Add(new Fortune(reader.GetInt32(0), reader.GetString(1)));
            }
        }

        // Runtime-injected row defeats whole-page memoization: the rendered
        // HTML must vary per request, even though the seeded rows don't.
        list.Add(new Fortune(0, "Additional fortune added at request time."));
        list.Sort(static (a, b) => string.CompareOrdinal(a.Message, b.Message));

        Fortunes = list;
        return Page();
    }
}
