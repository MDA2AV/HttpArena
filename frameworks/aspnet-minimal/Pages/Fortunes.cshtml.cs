using HttpArena.Services;
using HttpArena.Types;

using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

public sealed class FortunesModel(FortuneService fortuneService) : PageModel
{
    public List<Fortune> Fortunes { get; private set; } = [];

    public async Task<IActionResult> OnGetAsync()
    {
        if (!fortuneService.IsAvailable)
            return new StatusCodeResult(500);

        Fortunes = await fortuneService.GetFortunesAsync();
        return Page();
    }
}
