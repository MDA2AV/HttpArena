# Sharaf on Potateh

Sharaf is a simple Scala 3 web server. This version is compiled to native code with Scala Native.

```bash
./scripts/validate.sh sharaf-potateh
./scripts/benchmark-lite.sh sharaf-potateh baseline
```

The connection limit is raised to 8192 for HttpArena, so this is a tuned entry.
Potateh backend uses one worker per connection.
High connection counts require substantial memory and may exceed system thread limits.

The server also exposes `/json/{count}?m=N` and `/delay/{ms}` for local experimentation. The entry subscribes to the plaintext baseline and pipelining profiles.
