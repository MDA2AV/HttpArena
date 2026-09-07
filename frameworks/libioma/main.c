/*
 * HttpArena baseline handler for libioma.
 *
 * baseline profile: GET/POST /baseline11?a=..&b=.. - sum the query parameter values, and on POST
 * add the request body value too. libioma hands the query already split into key/value slices and
 * the body as a slice (Content-Length or chunked, decoded); the digits go straight into the reply.
 */
#include <ioma.h>

#include <stdlib.h>

static void baseline11(ioma_ctx *c)
{
    long sum = 0;
    for (size_t i = 0; i < c->req.n_params; i++)
        sum += ioma_slice_int(c->req.params[i].value);
    if (c->req.body.len)
        sum += ioma_slice_int(c->req.body);

    /* itoa, then one write into the reply buffer - no snprintf on the hot path */
    char          tmp[24], digits[24];
    int           t = 0;
    unsigned long u = (unsigned long)(sum < 0 ? 0 : sum);
    do {
        tmp[t++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    for (int i = 0; i < t; i++)
        digits[i] = tmp[t - 1 - i];
    ioma_write(c, digits, (size_t)t);
}

int main(int argc, char **argv)
{
    int workers = argc > 1 ? atoi(argv[1]) : 0;   /* 0 = one worker per available core */

    ioma_route("GET",  "/baseline11", baseline11);
    ioma_route("POST", "/baseline11", baseline11);

    return ioma_run(workers, 8080);
}
