local config = require("lapis.config")

config("production", {
  port = 8080,
  num_workers = "auto",
  code_cache = "on"
})
