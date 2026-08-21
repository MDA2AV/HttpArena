#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"

#include "cache/cache.h"

#include "vcc_httparena_if.h"

/* Sum the integer value of every "key=value" pair in a URL's query
 * string. No cross-request state, no allocation. Sets *err if any
 * value is out of range for a long long. */
static long long
parse_query_sum(const char *url, int *err)
{
	long long sum = 0;
	const char *qs;

	if (url == NULL)
		return (0);
	qs = strchr(url, '?');
	if (qs == NULL)
		return (0);
	qs++;

	while (*qs != '\0') {
		const char *amp = strchr(qs, '&');
		const char *end = amp != NULL ? amp : qs + strlen(qs);
		const char *eq = memchr(qs, '=', end - qs);

		if (eq != NULL) {
			long long v;

			errno = 0;
			v = strtoll(eq + 1, NULL, 10);
			if (errno == ERANGE)
				*err = 1;
			sum += v;
		}

		if (amp == NULL)
			break;
		qs = amp + 1;
	}

	return (sum);
}

/* Accumulate up to sizeof(buf)-1 request-body bytes, leaving room for a
 * NUL terminator; the body is just an integer (e.g. "20"), so a small
 * stack buffer is enough. If the body doesn't fit, abort (return
 * non-zero) so VRB_Iterate reports failure instead of us silently
 * summing a truncated body. */
struct httparena_body {
	char	buf[32];
	size_t	len;
};

static int v_matchproto_(objiterate_f)
httparena_collect_body(void *priv, unsigned flush, const void *ptr,
    ssize_t len)
{
	struct httparena_body *b = priv;

	(void)flush;
	if (len <= 0 || ptr == NULL)
		return (0);
	if ((size_t)len > sizeof(b->buf) - 1 - b->len)
		return (1);
	memcpy(b->buf + b->len, ptr, (size_t)len);
	b->len += (size_t)len;
	return (0);
}

VCL_STRING v_matchproto_(td_httparena_baseline_sum)
vmod_baseline_sum(VRT_CTX, VCL_STRING url)
{
	long long sum;
	struct httparena_body body;
	int err = 0;

	CHECK_OBJ_NOTNULL(ctx, VRT_CTX_MAGIC);
	CHECK_OBJ_NOTNULL(ctx->req, REQ_MAGIC);

	sum = parse_query_sum(url, &err);

	memset(&body, 0, sizeof body);
	if (VRB_Iterate(ctx->req->wrk, ctx->vsl, ctx->req,
	    httparena_collect_body, &body) != 0) {
		VRT_fail(ctx, "httparena.baseline_sum: failed to read "
		    "request body (too large?)");
		return (NULL);
	}
	if (body.len > 0) {
		errno = 0;
		sum += strtoll(body.buf, NULL, 10);
		if (errno == ERANGE)
			err = 1;
	}

	if (err) {
		VRT_fail(ctx, "httparena.baseline_sum: integer value out "
		    "of range");
		return (NULL);
	}

	return (VRT_INT_string(ctx, (VCL_INT)sum));
}
