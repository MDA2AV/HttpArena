import { TEXT } from '../../lib/util.mjs'

// GET /delay/{ms}: answered once ms milliseconds have gone by. A pending request is a timer and
// a promise, the worker stays free for the next one. The value is read before the timer is
// armed and lives in this request's closure, so overlapping requests each wait their own time.
export default {
  GET: ({ url }) => {
    const ms = parseInt(url.param('ms'), 10) || 0
    return new Promise(resolve => setTimeout(resolve, ms, { headers: TEXT, body: String(ms) }))
  }
}
