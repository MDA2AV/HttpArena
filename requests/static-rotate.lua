local paths = {
  "/static/reset.css",
  "/static/layout.css",
  "/static/theme.css",
  "/static/components.css",
  "/static/utilities.css",
  "/static/analytics.js",
  "/static/helpers.js",
  "/static/app.js",
  "/static/vendor.js",
  "/static/router.js",
  "/static/header.html",
  "/static/footer.html",
  "/static/regular.woff2",
  "/static/bold.woff2",
  "/static/logo.svg",
  "/static/icon-sprite.svg",
  "/static/hero.webp",
  "/static/thumb1.webp",
  "/static/thumb2.webp",
  "/static/manifest.json",
}

local ae_header = "br;q=1, gzip;q=0.8"
local counter = 0

request = function()
  counter = counter + 1
  local path = paths[((counter - 1) % 20) + 1]
  return wrk.format("GET", path, {["Accept-Encoding"] = ae_header})
end
