package com.httparena.fishcake

import com.httparena.fishcake.services.AsyncDatabase
import com.httparena.fishcake.services.Baseline
import com.httparena.fishcake.services.Crud
import com.httparena.fishcake.services.JsonService
import com.httparena.fishcake.services.Upload
import org.codegreen.modules.io.Content
import org.codegreen.modules.io.Resource
import org.codegreen.modules.layouting.Layout
import org.codegreen.modules.layouting.provider.LayoutBuilder
import org.codegreen.modules.webservices.addService

/**
 * Builds the routing tree, mirroring the C# `genhttp-11` entry's `Project.Create()`.
 *
 * `static` serves /data/static with pre-compressed variant selection (see [StaticFiles]).
 * Websockets and HTTP-2/3 from the original entry rely on modules the CodeGreen port does not
 * provide yet and are omitted.
 */
object Project {

    private val STATIC_DIR: String = System.getenv("STATIC_DIR") ?: "/data/static"

    fun create(): LayoutBuilder =
        Layout.create()
            .add("pipeline", Content.from(Resource.fromString("ok")))
            .addService<Baseline>("baseline11")
            .addService<Baseline>("baseline2")
            .addService<Upload>("upload")
            .addService<JsonService>("json")
            .addService<AsyncDatabase>("async-db")
            .add("crud", Layout.create().addService<Crud>("items"))
            .add("static", StaticFiles.from(STATIC_DIR))
}
