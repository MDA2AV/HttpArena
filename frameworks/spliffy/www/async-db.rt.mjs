import { query } from '../lib/db.mjs'

const EMPTY = '{"items":[],"count":0}'
const JSON_TYPE = { 'content-type': 'application/json' }

const ITEM_COLUMNS = 'id, name, category, price, quantity, active, tags, rating_score, rating_count'
export const itemShape = r => ({
  id: r.id,
  name: r.name,
  category: r.category,
  price: r.price,
  quantity: r.quantity,
  active: r.active,
  tags: r.tags,
  rating: { score: r.rating_score, count: r.rating_count }
})

// GET /async-db?min=10&max=50&limit=20: a range scan on the items table through the pool
export default {
  GET: async ({ url }) => {
    const q = url.query
    const min = parseInt(q.min, 10) || 10
    const max = parseInt(q.max, 10) || 50
    let limit = parseInt(q.limit, 10) || 50
    if (limit < 1) limit = 1
    if (limit > 50) limit = 50
    try {
      const result = await query('items-by-price',
        `SELECT ${ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3`, [min, max, limit])
      if (!result) return { headers: JSON_TYPE, body: EMPTY }
      const items = result.rows.map(itemShape)
      return { items, count: items.length }
    } catch (e) {
      return { headers: JSON_TYPE, body: EMPTY }
    }
  }
}
