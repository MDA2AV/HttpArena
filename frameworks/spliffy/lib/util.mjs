// headers are plain objects, built once
export const TEXT = { 'content-type': 'text/plain' }
export const JSON_TYPE = { 'content-type': 'application/json' }
export const OCTET = { 'content-type': 'application/octet-stream' }
export const HTML = { 'content-type': 'text/html; charset=utf-8' }

export function sumQuery (query) {
  let sum = 0
  for (const k in query) {
    const n = parseInt(query[k], 10)
    if (n === n) sum += n
  }
  return sum
}
