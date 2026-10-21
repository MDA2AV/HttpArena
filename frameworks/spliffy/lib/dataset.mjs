import fs from 'node:fs'

// the 50 item dataset the json routes serve, read once at startup
let items = []
try {
  items = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'))
} catch {}

export const dataset = items
