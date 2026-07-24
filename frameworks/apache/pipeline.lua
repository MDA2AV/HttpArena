-- mod_lua handler for GET /pipeline — fixed "ok" body, text/plain.
-- Used by the pipelined profile (16 requests per batch via HTTP/1.1
-- pipelining); response is short enough that many responses fit in a
-- single TCP write.

function handle(r)
    r.content_type = "text/plain"
    r:puts("ok")
    return apache2.OK
end
