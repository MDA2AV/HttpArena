import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fletch/fletch.dart';
import 'package:logger/logger.dart';
import 'package:postgres/postgres.dart';
import 'package:sqlite3/sqlite3.dart';

const _mimeTypes = <String, String>{
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.html': 'text/html',
  '.woff2': 'font/woff2',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.json': 'application/json',
};

// Pre-computed once; reused on every request that needs an empty result.
final _emptyJson = Uint8List.fromList(utf8.encode('{"items":[],"count":0}'));

class _StaticFile {
  final Uint8List data;
  final String contentType;
  const _StaticFile(this.data, this.contentType);
}

Future<void> main() async {
  final n = Platform.numberOfProcessors;
  for (var i = 1; i < n; i++) {
    await Isolate.spawn(_run, null);
  }
  await _run(null);
}

Future<void> _run(dynamic _) async {
  final jsonDataset = _loadDataset('/data/dataset.json');
  final compressionDataset = _loadDataset('/data/dataset-large.json');
  final staticFiles = _loadStaticFiles();
  final sqliteDb = _openSqlite();

  // Prepared statement — avoids re-parsing SQL on every /db request.
  final sqliteStmt = sqliteDb?.prepare(
    'SELECT id, name, category, price, quantity, active, tags,'
    ' rating_score, rating_count'
    ' FROM items WHERE price BETWEEN ? AND ? LIMIT 50',
  );

  // Postgres pool — populated after listen() so startup is never blocked.
  Pool? pgPool;
  Future<Pool?>? pgPoolConnectInFlight;
  DateTime? pgLastConnectAttempt;
  const pgRetryInterval = Duration(milliseconds: 500);

  Future<Pool?> ensurePgPool() async {
    final current = pgPool;
    if (current != null) return current;

    final inFlight = pgPoolConnectInFlight;
    if (inFlight != null) return inFlight;

    final now = DateTime.now();
    final lastAttempt = pgLastConnectAttempt;
    if (lastAttempt != null && now.difference(lastAttempt) < pgRetryInterval) {
      return null;
    }
    pgLastConnectAttempt = now;

    final connectFuture = _openPostgresPool().then((pool) {
      if (pool != null) pgPool = pool;
      return pool;
    }).whenComplete(() {
      pgPoolConnectInFlight = null;
    });
    pgPoolConnectInFlight = connectFuture;
    return connectFuture;
  }

  Future<void> resetPgPool() async {
    final oldPool = pgPool;
    pgPool = null;
    if (oldPool != null) {
      try {
        await oldPool.close();
      } catch (_) {}
    }
  }

  final app = Fletch(
    requestTimeout: null,
    secureCookies: false,
    sessionSecret: 'httparena-bench-secret-key-fletch32!',
    maxBodySize: 100 * 1024 * 1024,
    maxFileSize: 100 * 1024 * 1024,
    // Cookie parsing is unused in the benchmark; skip that middleware hop.
    useCookieParser: false,
    logger: Logger(level: Level.off),
  );

  app.get('/pipeline', (req, res) {
    res.text('ok');
  });

  app.get('/baseline11', (req, res) {
    var sum = 0;
    for (final v in req.query.values) {
      final n = int.tryParse(v);
      if (n != null) sum += n;
    }
    res.text('$sum');
  });

  app.post('/baseline11', (req, res) async {
    var sum = 0;
    for (final v in req.query.values) {
      final n = int.tryParse(v);
      if (n != null) sum += n;
    }
    final body = await req.body;
    if (body != null) {
      final s = body is String
          ? body.trim()
          : utf8.decode(body as List<int>).trim();
      final n = int.tryParse(s);
      if (n != null) sum += n;
    }
    res.text('$sum');
  });

  app.get('/json', (req, res) {
    if (jsonDataset == null) {
      res.bytes(_emptyJson, contentType: 'application/json');
      return;
    }
    final items = jsonDataset.map(_mapItem).toList();
    res.bytes(
      utf8.encode(jsonEncode({'items': items, 'count': items.length})),
      contentType: 'application/json',
    );
  });

  // Use Content-Length header when available — avoids buffering the entire
  // upload body just to count bytes, which matters for large payloads.
  app.post('/upload', (req, res) async {
    final cl = req.httpRequest.contentLength;
    if (cl >= 0) {
      res.text('$cl');
      return;
    }
    // Fallback for chunked transfers: buffer and count.
    final body = await req.body;
    int size = 0;
    if (body is Uint8List) {
      size = body.length;
    } else if (body is String) {
      size = utf8.encode(body).length;
    } else if (body is List<int>) {
      size = body.length;
    }
    res.text('$size');
  });

  app.get('/compression', (req, res) {
    if (compressionDataset == null) {
      res.bytes(Uint8List.fromList(GZipCodec(level: 1).encode(_emptyJson)),
          contentType: 'application/json');
      res.setHeader('Content-Encoding', 'gzip');
      return;
    }
    final items = compressionDataset.map(_mapItem).toList();
    final jsonBytes = utf8.encode(jsonEncode({'items': items, 'count': items.length}));
    final gzipBytes = Uint8List.fromList(GZipCodec(level: 1).encode(jsonBytes));
    res.bytes(gzipBytes, contentType: 'application/json');
    res.setHeader('Content-Encoding', 'gzip');
  });

  app.get('/static/:filename', (req, res) {
    final sf = staticFiles[req.params['filename']!];
    if (sf == null) {
      res.setStatus(404);
    } else {
      res.bytes(sf.data, contentType: sf.contentType);
    }
  });

  app.get('/db', (req, res) {
    if (sqliteStmt == null) {
      stderr.writeln('[db] sqliteStmt is null — sqlite3 may not have loaded');
      res.bytes(_emptyJson, contentType: 'application/json');
      return;
    }
    final minVal = double.tryParse(req.query['min'] ?? '') ?? 10.0;
    final maxVal = double.tryParse(req.query['max'] ?? '') ?? 50.0;
    try {
      final rows = sqliteStmt.select([minVal, maxVal]);
      final items = rows
          .map((row) => {
                'id': row['id'],
                'name': row['name'],
                'category': row['category'],
                'price': row['price'],
                'quantity': row['quantity'],
                'active': row['active'] == 1,
                'tags': jsonDecode(row['tags'] as String),
                'rating': {
                  'score': row['rating_score'],
                  'count': row['rating_count'],
                },
              })
          .toList();
      res.bytes(
        utf8.encode(jsonEncode({'items': items, 'count': items.length})),
        contentType: 'application/json',
      );
    } catch (e, st) {
      stderr.writeln('[db] error: $e\n$st');
      res.bytes(_emptyJson, contentType: 'application/json');
    }
  });

  app.get('/async-db', (req, res) async {
    final pool = await ensurePgPool();
    if (pool == null) {
      res.bytes(_emptyJson, contentType: 'application/json');
      return;
    }
    final minVal = double.tryParse(req.query['min'] ?? '') ?? 10.0;
    final maxVal = double.tryParse(req.query['max'] ?? '') ?? 50.0;
    try {
      final result = await pool.execute(
        r'SELECT id, name, category, price, quantity, active, tags,'
        r' rating_score, rating_count'
        r' FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50',
        parameters: [minVal, maxVal],
      );
      final items = result.map((row) {
        final cols = row.toColumnMap();
        final tagsRaw = cols['tags'];
        final tags =
            tagsRaw is List ? tagsRaw : jsonDecode(tagsRaw as String);
        return {
          'id': cols['id'],
          'name': cols['name'],
          'category': cols['category'],
          'price': cols['price'],
          'quantity': cols['quantity'],
          'active': cols['active'],
          'tags': tags,
          'rating': {
            'score': cols['rating_score'],
            'count': cols['rating_count'],
          },
        };
      }).toList();
      res.bytes(
        utf8.encode(jsonEncode({'items': items, 'count': items.length})),
        contentType: 'application/json',
      );
    } catch (_) {
      await resetPgPool();
      res.bytes(_emptyJson, contentType: 'application/json');
    }
  });

  // Bind first — server is reachable immediately.
  await app.listen(8080, shared: true);

  // Kick off async-db pool warmup, but keep lazy retries in request path.
  unawaited(ensurePgPool());
}

// ---------------------------------------------------------------------------
// Data helpers
// ---------------------------------------------------------------------------

List<dynamic>? _loadDataset(String path) {
  try {
    return jsonDecode(File(path).readAsStringSync()) as List;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _mapItem(dynamic d) => {
      'id': d['id'],
      'name': d['name'],
      'category': d['category'],
      'price': d['price'],
      'quantity': d['quantity'],
      'active': d['active'],
      'tags': d['tags'],
      'rating': d['rating'],
      'total':
          ((d['price'] as num) * (d['quantity'] as num) * 100).round() / 100,
    };

Map<String, _StaticFile> _loadStaticFiles() {
  final result = <String, _StaticFile>{};
  try {
    for (final entity in Directory('/data/static').listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final ext = name.contains('.') ? '.${name.split('.').last}' : '';
      result[name] = _StaticFile(
        entity.readAsBytesSync(),
        _mimeTypes[ext] ?? 'application/octet-stream',
      );
    }
  } catch (_) {}
  return result;
}

Database? _openSqlite() {
  try {
    return sqlite3.open('/data/benchmark.db', mode: OpenMode.readOnly);
  } catch (e) {
    stderr.writeln('[sqlite] failed to open: $e');
    return null;
  }
}

Future<Pool?> _openPostgresPool() async {
  final dbUrl = Platform.environment['DATABASE_URL'];
  if (dbUrl == null) return null;
  try {
    final uri = Uri.parse(dbUrl);
    final userInfo = uri.userInfo.split(':');
    final endpoint = Endpoint(
      host: uri.host,
      port: uri.port > 0 ? uri.port : 5432,
      database: uri.path.substring(1),
      username: userInfo[0],
      password: userInfo.length > 1 ? userInfo[1] : '',
    );
    // 4 connections per isolate; with N isolates total = 4N concurrent queries.
    final pool = Pool.withEndpoints(
      [endpoint],
      settings: const PoolSettings(
        sslMode: SslMode.disable,
        maxConnectionCount: 4,
      ),
    );
    // Warm up one connection to catch auth/config errors early.
    await pool.execute('SELECT 1');
    return pool;
  } catch (_) {
    return null;
  }
}
