var builder = WebApplication.CreateBuilder(args);

builder.Services.AddCodeBehind(!builder.Environment.IsDevelopment());

builder.Services.AddSingleton<DatasetService>();

var app = builder.Build();

app.UseCodeBehindAsync();

app.Run();