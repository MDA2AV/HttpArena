module HttpArena.Views

open Oxpecker.ViewEngine


let private pageHead = 
    head () {
        title () { "Fortunes" }
    }
    
let private tableHead = 
    thead () {
        tr () {
            th () { "id" }
            th () { "message" }
        }
    }

let fortunes (rows: ResizeArray<Fortune>) =
    html () {
        pageHead

        body () {
            table () {
                tableHead

                for row in rows do
                    tr () {
                        td () { row.Id }
                        td () { row.Message }
                    }
            }
        }
    }
