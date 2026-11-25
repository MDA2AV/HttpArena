import 'dart:io';

/// The environment keys the HttpArena runner sets.
class Env {
  const Env(this._values);

  final Map<String, String> _values;

  /// 8080 for HTTP/1.1. The second process gets 8082 for h2c.
  int get port => int.tryParse(_values['PORT'] ?? '') ?? 8080;

  String get databaseUrl => _values['DATABASE_URL'] ?? '';

  /// The pool size for the whole app.
  int get databaseMaxConn =>
      int.tryParse(_values['DATABASE_MAX_CONN'] ?? '') ?? 256;
}

Env env = Env(Platform.environment);
