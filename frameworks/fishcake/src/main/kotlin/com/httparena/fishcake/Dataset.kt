package com.httparena.fishcake

import kotlinx.serialization.json.Json
import java.io.File

/**
 * Loads the JSON dataset (default `/data/dataset.json`, overridable with `DATASET_PATH`)
 * used by the `/json` workload, and exposes the shared JSON configuration.
 */
object Dataset {

    val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    val items: List<DatasetItem> = run {
        val file = File(System.getenv("DATASET_PATH") ?: "/data/dataset.json")
        if (file.exists()) json.decodeFromString<List<DatasetItem>>(file.readText()) else emptyList()
    }
}
