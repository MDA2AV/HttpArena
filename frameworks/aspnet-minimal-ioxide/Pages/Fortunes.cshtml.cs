using System.Buffers.Text;
using System.Text;
using ioxide.pg;
using ioxide.Kestrel;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

public sealed class FortunesModel : PageModel
{
    public List<Fortune> Fortunes { get; private set; } = [];

    public async Task<IActionResult> OnGetAsync()
    {
        if (!AppData.PgEnabled)
            return new StatusCodeResult(500);

        // Query runs on the connection's reactor via ioxide.pg.
        var list = await HttpContext.OnReactor(async r =>
        {
            var pool = r.GetService<PgPool>();
            var fortunes = new List<Fortune>(201);
            await pool.QueryRowsAsync("SELECT id, message FROM fortune",
                row => fortunes.Add(new Fortune(
                    Utf8Parser.TryParse(row.Field(0), out int fid, out _) ? fid : 0,
                    Encoding.UTF8.GetString(row.Field(1)))));
            return fortunes;
        });

        // Runtime-injected row defeats whole-page memoization: the rendered HTML must vary per request.
        list.Add(new Fortune(0, "Additional fortune added at request time."));
        list.Sort(static (a, b) => string.CompareOrdinal(a.Message, b.Message));

        Fortunes = list;
        return Page();
    }
}
