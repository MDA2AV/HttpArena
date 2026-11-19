require "etc"
bind "0.0.0.0"
port 8080
workers Etc.nprocessors
