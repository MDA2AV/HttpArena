-- mod_lua handler for GET|POST /baseline11
--
-- Contract:
--   - Sum all integer query parameter values (a, b, ...).
--   - If method is POST and a body is present, parse it as an integer
--     and add to the sum.
--   - Respond 200 text/plain with the decimal sum (no trailing newline).

local function to_int(v)
    if v == nil then return 0 end
    local n = tonumber(v)
    if n == nil then return 0 end
    -- Truncate toward zero for floats; benchmarks only send integers.
    if n >= 0 then
        return math.floor(n)
    else
        return -math.floor(-n)
    end
end

function handle(r)
    local sum = 0

    -- Query args: r:parseargs() returns (table, multitable); the first is
    -- the last-value map, which is what array_sum-style behavior expects.
    local args = r:parseargs()
    if args ~= nil then
        for _, v in pairs(args) do
            sum = sum + to_int(v)
        end
    end

    -- POST body: r:parsebody() handles application/x-www-form-urlencoded and
    -- multipart. For raw integer bodies (text/plain), read r:requestbody().
    if r.method == "POST" then
        local body = r:requestbody()
        if body ~= nil and #body > 0 then
            sum = sum + to_int(body)
        end
    end

    r.content_type = "text/plain"
    r:puts(tostring(sum))
    return apache2.OK
end
