import fs from 'node:fs'
import path from 'node:path'
import ejs from 'ejs'
import { moduleDirname } from '@srfnstack/spliffy'
import { query } from '../lib/db.mjs'
import { HTML, TEXT } from '../lib/util.mjs'

// the template is compiled once, ejs escapes every interpolated value
const template = ejs.compile(fs.readFileSync(path.join(moduleDirname(import.meta.url), '..', 'views', 'fortunes.ejs'), 'utf8'))
const RUNTIME_FORTUNE = 'Additional fortune added at request time.'
// ordinal, not locale aware
const byMessage = (a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0)

export default {
  GET: async () => {
    try {
      const result = await query('fortunes', 'SELECT id, message FROM fortune')
      if (!result) return { statusCode: 500, headers: TEXT, body: 'DB not available' }
      const rows = result.rows
      rows.push({ id: 0, message: RUNTIME_FORTUNE })
      rows.sort(byMessage)
      return { headers: HTML, body: template({ fortunes: rows }) }
    } catch (e) {
      return { statusCode: 500, headers: TEXT, body: 'query failed' }
    }
  }
}
