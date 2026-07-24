package com.httparena.fishcake

import java.util.concurrent.ConcurrentHashMap

/**
 * In-process cache-aside with an absolute TTL (200 ms by default), used by the CRUD
 * single-item read endpoint. Stale entries are evicted lazily on access.
 */
class TtlCache(private val ttlMillis: Long = 200L) {

    private class Entry(val body: String, val expiresAt: Long)

    private val entries = ConcurrentHashMap<Int, Entry>()

    fun get(id: Int): String? {
        val entry = entries[id] ?: return null
        if (entry.expiresAt <= System.nanoTime()) {
            entries.remove(id, entry)
            return null
        }
        return entry.body
    }

    fun put(id: Int, body: String) {
        entries[id] = Entry(body, System.nanoTime() + ttlMillis * 1_000_000L)
    }

    fun invalidate(id: Int) {
        entries.remove(id)
    }
}

val crudCache = TtlCache(200L)
