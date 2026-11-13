package genhttp

import genhttp.tests.AsyncDatabase
import genhttp.tests.Baseline
import genhttp.tests.Delay
import genhttp.tests.Echo
import genhttp.tests.EchoHandler
import genhttp.tests.Json

import org.genhttp.api.content.HandlerBuilder
import org.genhttp.api.content.io.Resource
import org.genhttp.modules.compression.algorithms.BrotliAlgorithm
import org.genhttp.modules.files.Assets
import org.genhttp.modules.io.Content
import org.genhttp.modules.io.fromString
import org.genhttp.modules.layouting.Layout
import org.genhttp.modules.layouting.provider.LayoutBuilder
import org.genhttp.modules.webservices.addService
import org.genhttp.modules.websockets.Websocket

import java.io.File

object Project {

    fun create(): HandlerBuilder {
        val app = Layout.create()
            .add("pipeline", Content.from(Resource.fromString("ok")))
            .addService<Baseline>("baseline11")
            .addService<Baseline>("baseline2")
            .addService<Echo>("echo")
            .addService<Json>("json")
            .addService<Delay>("delay")
            .addService<AsyncDatabase>("async-db")
            .addStaticFiles()
            .addWebsocket()

        return app
    }

    private fun LayoutBuilder.addStaticFiles(): LayoutBuilder {
        if (File("/data/static").isDirectory) {
            val handler = Assets.from("/data/static")
                .allowPrecompressed(BrotliAlgorithm())

            add("static", handler)
        }

        return this
    }

    private fun LayoutBuilder.addWebsocket(): LayoutBuilder {
        val websocket = Websocket.imperative()
            .doNotAllocateFrameData()
            .handler(EchoHandler())

        return add("ws", websocket)
    }

}
