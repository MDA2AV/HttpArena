/*
 * HttpArena baseline handler for libioma.
 *
 * baseline profile: GET/POST /baseline11?a=..&b=.. - sum the query parameter values, and on POST
 * add the request body value too. libioma hands the query already split into key/value slices and
 * the body as a slice (Content-Length or chunked, decoded), so this is a loop and an itoa.
 */
#include <ioma.h>

#include <stdlib.h>

static ioma_response baseline11(ioma_request *req)
{
    long sum = 0;
    for (size_t i = 0; i < req->n_params; i++)
        sum += ioma_slice_int(req->params[i].value);
    if (req->body.len)
        sum += ioma_slice_int(req->body);

    /* itoa into scratch (alive until the reply is sent) - no snprintf on the hot path */
    char         *p = req->scratch;
    char          tmp[24];
    int           t = 0;
    unsigned long u = (unsigned long)(sum < 0 ? 0 : sum);
    do {
        tmp[t++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    for (int i = 0; i < t; i++)
        p[i] = tmp[t - 1 - i];

    return ioma_bytes(200, "text/plain", req->scratch, (size_t)t);
}

int main(int argc, char **argv)
{
    int workers = argc > 1 ? atoi(argv[1]) : 0;   /* 0 = one worker per available core */

    ioma_route("GET",  "/baseline11", baseline11);
    ioma_route("POST", "/baseline11", baseline11);

    return ioma_run(workers, 8080);
}
