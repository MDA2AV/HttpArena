import { sumQuery, TEXT } from '../lib/util.mjs'

// GET /baseline11?a=13&b=42 -> 55, POST adds the body. The body is parsed before the handler runs,
// so both handlers are synchronous and the response is one write.
export default {
  GET: ({ url }) => ({ headers: TEXT, body: String(sumQuery(url.query)) }),
  POST: ({ url, body }) => {
    let total = sumQuery(url.query)
    const n = parseInt(typeof body === 'string' ? body : body.toString(), 10)
    if (n === n) total += n
    return { headers: TEXT, body: String(total) }
  }
}
