import { declarative } from '@srfnstack/spliffy'

// A fixed response is a declarative response: compiled once at startup and answered inside
// uWebSockets.js, no javascript runs per request.
export default {
  GET: declarative().writeHeader('content-type', 'text/plain').end('ok')
}
