// Read-only checks against an address: node tests/smoke.mjs https://http-arena.genhttp.run/

const base = new URL(process.argv[2] ?? "http://localhost:8080/");

let failed = 0;

async function check(name, path, expect) {
    try {
        const response = await fetch(new URL(path, base), { redirect: "manual" });
        const body = await response.text();
        const problem = expect(response, body);
        console.log(`${problem ? "FAIL" : "ok  "} ${name}${problem ? `: ${problem}` : ""}`);
        if (problem) failed++;
    } catch (e) {
        console.log(`FAIL ${name}: ${e.message}`);
        failed++;
    }
}

const status = (code) => (r) => r.status === code ? null : `answered ${r.status}`;

await check("the board", "./", (r, body) => r.status !== 200 ? `answered ${r.status}` : body.includes("HttpArena") ? null : "no HttpArena in it");
await check("a folder answers with its index", "docs/", status(200));
await check("a path that is nothing is 404", "no/such/page/", status(404));
await check("badges for shields.io", "badge/index.json", (r, body) => r.status !== 200 ? `answered ${r.status}` : JSON.parse(body) && null);
await check("the entries", "api/frameworks", (r, body) => r.status !== 200 ? `answered ${r.status}` : typeof JSON.parse(body) === "object" ? null : "not an object");
await check("the publishes", "api/publishes", (r, body) => r.status !== 200 ? `answered ${r.status}` : Array.isArray(JSON.parse(body)) ? null : "not a list");
await check("ingest wants a key", "api/ingest/logs", status(401));

// one entry's results, when anything was published yet
const results = await fetch(new URL("api/results", base)).then((r) => r.json()).catch(() => ({}));
const slug = Object.keys(results)[0];
if (slug) {
    await check(`results of ${slug}`, `api/results/${slug}`, (r, body) => {
        const file = JSON.parse(body);
        return file.framework && file.results ? null : "no framework or results";
    });
}

process.exit(failed ? 1 : 0);
