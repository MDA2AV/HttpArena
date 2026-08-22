module HttpArena.Views

open Oxpecker.ViewEngine

let private layout =
    prerenderAround (fun content ->
        html () {
            head () {
                title () { "Fortunes" }
            }
            body () {
                table () {
                    thead () {
                        tr () {
                            th () { "id" }
                            th () { "message" }
                        }
                    }
                    content
                }
            }
        }
    )

let fortunes (rows: ResizeArray<Fortune>) =
    layout() {
        for row in rows do
            tr () {
                td () { row.Id }
                td () { row.Message }
            }
    }
