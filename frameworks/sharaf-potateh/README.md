# Sharaf on Potateh

Sharaf is a simple Scala 3 web server. This version uses Sharaf 0.22.0, Scala
3.10.0, sbt 1.12 and Scala Native 0.5.12. The executable is linked in
`release-full` mode. The image is built and runs on Alpine, so the runtime
contains no JVM.

```bash
./scripts/validate.sh sharaf-potateh
./scripts/benchmark-lite.sh sharaf-potateh baseline
```

The connection limit is raised to 8192 for HttpArena, so this is a tuned entry.
Potateh backend uses one worker per connection.
High connection counts require substantial memory and may exceed system thread limits.

The server also exposes `/json/{count}?m=N` and `/delay/{ms}` for local experimentation. The entry subscribes to the plaintext baseline and pipelining profiles.
