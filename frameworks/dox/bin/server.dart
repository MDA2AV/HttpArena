import 'dart:io';

import 'package:dox_core/dox_core.dart';
import 'package:httparena_dox/config/app.dart';
import 'package:httparena_dox/config/env.dart';
import 'package:httparena_dox/constants/http_ports.dart';

void main() async {
  // Dox serves one port, so a second copy of this binary serves h2c.
  if (env.port == HttpPorts.http1) {
    await Process.start(
      Platform.resolvedExecutable,
      <String>[],
      environment: <String, String>{'PORT': '${HttpPorts.h2c}'},
      mode: ProcessStartMode.inheritStdio,
    );
  }
  Dox().initialize(appConfig);
  await Dox().startServer();
}
