import { Host } from "../seagreen/src/engine/internal/index.ts";
import { dbAvailable } from "./data.ts";
import { createApp } from "./project.ts";

const port = Number(process.env.PORT ?? 8080);
const workers = Number(process.env.WORKERS) || navigator.hardwareConcurrency || 1;

if (!process.env.SEAGREEN_WORKER) {
  console.log(`bananabread (Seagreen) → :${port}, ${workers} workers, database: ${dbAvailable ? "connected" : "disabled"}`);
}

await Host.create().handler(createApp()).port(port).workers(workers).run();
