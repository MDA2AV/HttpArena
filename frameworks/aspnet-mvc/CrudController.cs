using HttpArena.Services;
using HttpArena.Types;

using Microsoft.AspNetCore.Mvc;

[ApiController]
[Route("/crud/items")]
public sealed class CrudController(ItemService items) : ControllerBase
{

    [HttpGet]
    public async Task<IActionResult> List([FromQuery] string? category, [FromQuery] int page, [FromQuery] int limit)
    {
        if (!items.IsAvailable)
            return Problem("DB not available");

        return Ok(await items.ListAsync(category, page, limit));
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> Read(int id)
    {
        if (!items.IsAvailable)
            return Problem("DB not available");

        var result = await items.ReadAsync(id);
        if (result is null) return NotFound();

        Response.Headers["X-Cache"] = result.CacheHit ? "HIT" : "MISS";

        return result.Json is not null
            ? Content(result.Json, "application/json")
            : Ok(result.Item!);
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] CrudItemInput input)
    {
        if (!items.IsAvailable)
            return Problem("DB not available");

        var created = await items.CreateAsync(input);

        return StatusCode(StatusCodes.Status201Created, created);
    }

    [HttpPut("{id:int}")]
    public async Task<IActionResult> Update(int id, [FromBody] CrudItemInput input)
    {
        if (!items.IsAvailable)
            return Problem("DB not available");

        var updated = await items.UpdateAsync(id, input);
        if (updated is null) return NotFound();

        return Ok(updated);
    }

}
