import { sumQuery, TEXT } from '../lib/util.mjs'

export default {
  GET: ({ url }) => ({ headers: TEXT, body: String(sumQuery(url.query)) })
}
