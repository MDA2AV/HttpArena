# Gleam + Mist — BEAM VM HTTP Server

[Mist](https://github.com/rawhat/mist) is a glistening HTTP server for the [Gleam](https://gleam.run/) programming language, running on the BEAM (Erlang VM).

## Why it's interesting

- **First Gleam framework** in HttpArena
- **First BEAM VM entry** — adds a completely new runtime to the mix
- Gleam compiles to Erlang bytecode and runs on the battle-tested BEAM VM
- Mist uses OTP processes for concurrency — one lightweight process per connection
- The BEAM's preemptive scheduling and per-process GC is a fundamentally different concurrency model than async/await or OS threads
- Type-safe, functional language with exhaustive pattern matching

## Stack

- **Language:** Gleam
- **Runtime:** BEAM (Erlang VM / OTP)
- **HTTP server:** Mist
- **JSON:** gleam_json
- **SQLite:** sqlight (NIF bindings)
- **Compression:** Erlang's built-in zlib
