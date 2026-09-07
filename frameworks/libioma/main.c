/*
 * HttpArena baseline handler for libioma.
 *
 * baseline profile: GET/POST /baseline11?a=..&b=.. - sum the query parameter values, and on POST
 * add the request body value too. libioma hands the query already split into key/value slices;
 * the body is read on demand (Content-Length or chunked, decoded). The digits are written straight
 * into the reply slab.
 */
#include <ioma.h>

#include <stdlib.h>

static void baseline11(ioma_ctx *c)
{
    int64_t sum = 0, v;
    for (size_t i = 0; i < c->req.n_params; i++)
        if (ioma_to_i64(c->req.params[i].value, &v))
            sum += v;
    if ((c->req.content_length || c->req.chunked) && ioma_to_i64(ioma_slice_trim(ioma_body(c)), &v))
        sum += v;

    /* itoa straight into the reply slab - no snprintf, no copy */
    char         *out = c->res.buf + c->res.len;
    char          tmp[24];
    int           t = 0;
    unsigned long u = (unsigned long)(sum < 0 ? 0 : sum);
    do {
        tmp[t++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    for (int i = 0; i < t; i++)
        out[i] = tmp[t - 1 - i];
    c->res.len += (size_t)t;
}

int main(int argc, char **argv)
{
    int workers = argc > 1 ? atoi(argv[1]) : 0;   /* 0 = one worker per available core */

    ioma_route("GET",  "/baseline11", baseline11);
    ioma_route("POST", "/baseline11", baseline11);

    return ioma_run(workers, 8080);
}
