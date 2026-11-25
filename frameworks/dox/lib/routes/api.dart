import 'package:dox_core/dox_core.dart';
import 'package:httparena_dox/app/http/controllers/baseline.controller.dart';
import 'package:httparena_dox/app/http/controllers/database.controller.dart';
import 'package:httparena_dox/app/http/controllers/json.controller.dart';

class ApiRouter extends Router {
  ApiRouter(this.baseline, this.json, this.database);

  final BaselineController baseline;
  final JsonController json;
  final DatabaseController database;

  @override
  void register() {
    Route.get('/baseline11', baseline.querySum);
    Route.post('/baseline11', baseline.sum);
    Route.get('/baseline2', baseline.querySum);
    Route.get('/pipeline', baseline.pipeline);
    Route.get('/delay/{ms}', baseline.delay);
    Route.get('/json/{count}', json.items);
    Route.get('/async-db', database.items);
    Route.get('/fortunes', database.fortunes);
  }
}
