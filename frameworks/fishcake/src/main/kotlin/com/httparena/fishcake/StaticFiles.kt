package com.httparena.fishcake

import org.codegreen.api.MemoryView
import org.codegreen.api.content.HandlerBuilder
import org.codegreen.api.protocol.Request
import org.codegreen.api.protocol.Response
import org.codegreen.api.protocol.getEntry
import org.codegreen.modules.io.Handler
import org.codegreen.modules.io.Resource
import org.codegreen.modules.io.guessContentType
import org.codegreen.modules.io.streaming.ResourceContent
import java.io.File

/**
 * Serves a directory of static files (the HttpArena "static" profile) with pre-compressed
 * variant selection: when the request carries `Accept-Encoding` and a sibling `<file>.br` or
 * `<file>.gz` exists on disk, that variant is served with the matching `Content-Encoding` and the
 * original file's `Content-Type`. Mirrors GenHTTP's pre-compressed assets (#840) — the bytes are
 * served straight off disk, so no runtime compression is needed here. A missing file yields
 * `null`, which the surrounding layout turns into a 404.
 */
object StaticFiles {

    // Brotli before gzip: Brotli has the higher priority in GenHTTP's compression set, so when the
    // client accepts both we serve the smaller payload.
    private val PRECOMPRESSED = listOf("br" to ".br", "gzip" to ".gz")

    fun from(directory: String): HandlerBuilder {
        val root = File(directory).canonicalFile
        return Handler.from { request -> serve(request, root) }
    }

    private fun serve(request: Request, root: File): Response? {
        val relative = request.header.target.asString(decode = true, remainingOnly = true).trimStart('/')
        if (relative.isEmpty() || relative.endsWith("/")) return null

        val file = File(root, relative)
        // Containment guard: never serve outside the configured root (e.g. via "..").
        if (!file.canonicalFile.path.startsWith(root.path + File.separator)) return null

        // Content-Type comes from the ORIGINAL name, not the .br/.gz variant.
        val contentType = relative.guessContentType()

        val accepted = acceptedEncodings(request)
        for ((algorithm, extension) in PRECOMPRESSED) {
            if (algorithm in accepted) {
                val variant = File(root, relative + extension)
                if (variant.isFile) {
                    return request.respond()
                        .content(ResourceContent(Resource.fromFile(variant).build(), contentType, MemoryView.ofAscii(algorithm)))
                        .build()
                }
            }
        }

        if (!file.isFile) return null

        return request.respond()
            .content(ResourceContent(Resource.fromFile(file).build(), contentType))
            .build()
    }

    private fun acceptedEncodings(request: Request): Set<String> {
        val header = request.header.headers.getEntry("Accept-Encoding") ?: return emptySet()
        return header.split(',')
            .mapNotNull { part -> part.substringBefore(';').trim().lowercase().takeIf(String::isNotEmpty) }
            .toSet()
    }
}
