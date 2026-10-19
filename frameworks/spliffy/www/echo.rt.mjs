import { OCTET } from '../lib/util.mjs'

// POST /echo: the body comes back as it arrived. An application/octet-stream body is the Buffer
// of the bytes sent, content-length or chunked alike, and an empty body is an empty Buffer.
export default {
  POST: ({ body }) => ({ headers: OCTET, body })
}
