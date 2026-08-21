/// Loads and prepares the fortune rows for the /fortunes HTML workload.
module HttpArena.Services.Fortunes

open System

open HttpArena

let isAvailable = Database.isAvailable

let getRows () =
    task {
        let rows = ResizeArray<Fortune> 201

        use cmd = Database.command "SELECT id, message FROM fortune"
        use! reader = cmd.ExecuteReaderAsync()

        while! reader.ReadAsync() do
            rows.Add { Id = reader.GetInt32 0; Message = reader.GetString 1 }

        // Runtime-injected row defeats whole-page memoization: the rendered
        // HTML must vary per request, even though the seeded rows don't.
        rows.Add { Id = 0; Message = "Additional fortune added at request time." }
        rows.Sort(fun a b -> String.CompareOrdinal(a.Message, b.Message))

        return rows
    }
