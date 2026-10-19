@page
@model HttpArena.Models.FortunesModel
@break
<!DOCTYPE html>
<html>
<head><title>Fortunes</title></head>
<body>
<table>
<tr><th>id</th><th>message</th></tr>
@foreach (var fortune in model.Fortunes)
{
<tr><td>@fortune.Id</td><td>@System.Net.WebUtility.HtmlEncode(fortune.Message)</td></tr>
}
</table>
</body>
</html>
