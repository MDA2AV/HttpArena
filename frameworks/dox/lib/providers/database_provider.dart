import 'package:dox_core/dox_core.dart';
import 'package:dox_orm/dox_orm.dart';
import 'package:httparena_dox/config/database.dart';
import 'package:httparena_dox/config/env.dart';

class DatabaseProvider extends DoxProvider {
  @override
  void setup() {
    if (env.databaseUrl.isEmpty) return;
    SqlQueryBuilder.initializeWithDatabaseConfig(databaseConfig);
  }
}
