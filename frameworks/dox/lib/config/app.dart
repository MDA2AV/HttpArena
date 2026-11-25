import 'package:dox_core/dox_core.dart';
import 'package:httparena_dox/app/http/controllers/baseline.controller.dart';
import 'package:httparena_dox/app/http/controllers/database.controller.dart';
import 'package:httparena_dox/app/http/controllers/json.controller.dart';
import 'package:httparena_dox/app/services/dataset.service.dart';
import 'package:httparena_dox/config/env.dart';
import 'package:httparena_dox/constants/http_ports.dart';
import 'package:httparena_dox/providers/database_provider.dart';
import 'package:httparena_dox/providers/view_provider.dart';
import 'package:httparena_dox/routes/api.dart';

AppConfig appConfig = AppConfig(
  appKey: 'httparenahttparenahttparena12345',
  serverPort: env.port,
  http2: env.port == HttpPorts.h2c,

  /// gzip a response on a Rust thread when the client asks for gzip.
  compress: true,
  providers: <DoxProvider>[DatabaseProvider(), AppViewProvider()],
  routers: <Router>[
    ApiRouter(
      BaselineController(),
      JsonController(DatasetService('/data/dataset.json')),
      DatabaseController(),
    ),
  ],
);
