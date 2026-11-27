import 'dart:math';

import 'package:dox_core/dox_core.dart';
import 'package:dox_orm/dox_orm.dart';
import 'package:httparena_dox/config/env.dart';

/// Each isolate has its own pool, so the app total is split between them.
int _pool = max(1, env.databaseMaxConn ~/ Processors.available);

DatabaseConfig databaseConfig = DatabaseConfig(
  connection: 'postgres',
  connections: <String, ConnectionConfig>{
    'postgres': ConnectionConfig.fromUrl(
      env.databaseUrl,
      extra: <String, dynamic>{
        'maxConnectionCount': _pool,
        'sslWarning': false,
      },
    ),
  },
);
