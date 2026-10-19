import { compression } from '@srfnstack/spliffy'
import { dataset } from '../../lib/dataset.mjs'

// GET /json/{count}?m=N: the first count items with total = price * quantity * m. The returned
// object is serialized to json by the framework. The compression middleware on this route
// compresses it when the request accepts gzip or brotli, and leaves it alone otherwise.
export default {
  middleware: [compression()],
  GET: ({ url }) => {
    let count = parseInt(url.param('count'), 10) || 0
    if (count < 0) count = 0
    if (count > dataset.length) count = dataset.length
    const m = parseInt(url.query.m, 10) || 1
    const items = new Array(count)
    for (let i = 0; i < count; i++) {
      const d = dataset[i]
      items[i] = {
        id: d.id,
        name: d.name,
        category: d.category,
        price: d.price,
        quantity: d.quantity,
        active: d.active,
        tags: d.tags,
        rating: d.rating,
        total: d.price * d.quantity * m
      }
    }
    return { items, count }
  }
}
