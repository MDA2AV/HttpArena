import { Content, Resource } from "../seagreen/src/modules/io/index.ts";
import { Layout, type LayoutBuilder } from "../seagreen/src/modules/layouting/index.ts";
import { Service } from "../seagreen/src/modules/webservices/index.ts";
import { AsyncDatabase, Baseline, Crud, JsonService, Upload } from "./services.ts";

export function createApp(): LayoutBuilder {
  return Layout.create()
    .add("pipeline", Content.from(Resource.fromString("ok")))
    .add("baseline11", Service.from(Baseline))
    .add("baseline2", Service.from(Baseline))
    .add("upload", Service.from(Upload))
    .add("json", Service.from(JsonService))
    .add("async-db", Service.from(AsyncDatabase))
    .add("crud", Layout.create().add("items", Service.from(Crud)));
}
