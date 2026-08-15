using HttpArena.Services;

using Microsoft.AspNetCore.Mvc;

public sealed class FortunesController(FortuneService fortunes) : Controller
{

    [HttpGet("/fortunes")]
    public async Task<IActionResult> Index()
    {
        if (!fortunes.IsAvailable)
            return StatusCode(500);

        return View(await fortunes.GetFortunesAsync());
    }

}
