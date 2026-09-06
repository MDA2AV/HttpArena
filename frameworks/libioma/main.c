/*
 * HttpArena baseline handler for ioma.
 *
 * baseline profile: GET/POST /baseline11?a=..&b=.. — sum the query parameter values, and on POST
 * add the request body value too. The body arrives as Content-Length or Transfer-Encoding: chunked;
 * ioma decodes both, so the same handler serves all three request shapes the profile rotates.
 */
#include <ioma.h>

#include <stdlib.h>

/* Sum the integer values of the query parameters, e.g. "a=13&b=42" -> 55. */
static long sum_query(const char *q, size_t n)
{
    long   sum = 0;
    size_t i = 0;
    while (i < n) {
        while (i < n && q[i] != '=') i++;      /* to this parameter's '=' */
        if (i >= n) break;
        i++;                                    /* past '=' */

        long v = 0;
        int  any = 0;
        while (i < n && q[i] != '&') {
            if (q[i] >= '0' && q[i] <= '9') {
                v = v * 10 + (q[i] - '0');
                any = 1;
            }
            i++;
        }
        if (any) sum += v;
        if (i < n && q[i] == '&') i++;
    }
    return sum;
}

/* Leading integer of a body like "20". */
static long body_int(const char *b, size_t n)
{
    long v = 0;
    for (size_t i = 0; i < n; i++) {
        if (b[i] < '0' || b[i] > '9') break;
        v = v * 10 + (b[i] - '0');
    }
    return v;
}

/* GET / POST /baseline11 - the summed response, formatted straight into the request scratch. */
static ioma_response baseline11(ioma_request *req)
{
    long sum = 0;
    if (req->query_len) sum += sum_query(req->query, req->query_len);
    if (req->body_len)  sum += body_int(req->body, req->body_len);

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
    int workers = argc > 1 ? atoi(argv[1]) : 64;
    if (workers < 1) workers = 64;

    ioma_route("GET",  "/baseline11", baseline11);
    ioma_route("POST", "/baseline11", baseline11);

    return ioma_run(workers, 8080);
}
