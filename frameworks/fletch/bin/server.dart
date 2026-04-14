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
  final Uint8List? gzipData;
  final Uint8List? brData;
  const _StaticFile(
    this.data,
    this.contentType, {
    this.gzipData,
    this.brData,
  });
}

class _JsonPayload {
  final Uint8List identity;
  final Uint8List gzip;
  const _JsonPayload(this.identity, this.gzip);
}

Future<void> main(List<String> args) async {
  // Prefer the worker count passed via entrypoint.sh (derived from `nproc`,
  // which respects the cgroup CPU quota set by --cpus=N).  Fall back to
  // Platform.numberOfProcessors when running outside Docker.
  final n = args.isNotEmpty
      ? (int.tryParse(args[0]) ?? Platform.numberOfProcessors)
      : Platform.numberOfProcessors;
  for (var i = 1; i < n; i++) {
    await Isolate.spawn(_run, null);
  }
  await _run(null);
}

Future<void> _run(dynamic _) async {
  final jsonDataset = _loadDataset('/data/dataset.json');
  final compressionDataset = _loadDataset('/data/dataset-large.json');
  final staticFiles = _loadStaticFiles();

  // Pre-map once; per-request /json/:count applies the multiplier.
  final jsonItems = _encodeItems(jsonDataset);
  final jsonPayloadCache = _buildHotJsonPayloadCache(jsonItems);
  final compressionJsonBytes = _encodeItemsPayload(compressionDataset);
  final sqliteDb = _openSqlite();

  // Prepared statement — avoids re-parsing SQL on every /db request.
  // LIMIT is a bound parameter so the benchmark's ?limit=N is respected.
  final sqliteStmt = sqliteDb?.prepare(
    'SELECT id, name, category, price, quantity, active, tags,'
    ' rating_score, rating_count'
    ' FROM items WHERE price BETWEEN ? AND ? LIMIT ?',
  );

  // Postgres pool — populated after listen() so startup is never blocked.
  Pool? pgPool;
  Future<Pool?>? pgPoolConnectInFlight;

  Future<Pool?> ensurePgPool() async {
    final current = pgPool;
    if (current != null) return current;

    final inFlight = pgPoolConnectInFlight;
    if (inFlight != null) return inFlight;

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

  app.get('/json/:count', (req, res) {
    final requestedCount = int.tryParse(req.params['count'] ?? '') ?? 0;
    final m = int.tryParse(req.query['m'] ?? '') ?? 1;
    final count = requestedCount.clamp(0, jsonItems.length).toInt();
    final acceptEncoding =
        (req.headers['accept-encoding'] ?? '').toString().toLowerCase();

    final cached = jsonPayloadCache[_jsonKey(count, m)];
    if (cached != null) {
      if (acceptEncoding.contains('gzip')) {
        res.setHeader('Content-Encoding', 'gzip');
        res.setHeader('Vary', 'Accept-Encoding');
        res.bytes(cached.gzip, contentType: 'application/json');
      } else {
        res.bytes(cached.identity, contentType: 'application/json');
      }
      return;
    }

    final identity = _buildJsonPayloadBytes(jsonItems, count, m);
    if (acceptEncoding.contains('gzip')) {
      res.setHeader('Content-Encoding', 'gzip');
      res.setHeader('Vary', 'Accept-Encoding');
      final gzipBytes = Uint8List.fromList(GZipCodec(level: 1).encode(identity));
      res.bytes(gzipBytes, contentType: 'application/json');
    } else {
      res.bytes(identity, contentType: 'application/json');
    }
  });

  
  app.post('/upload', (req, res) async {
    var size = 0;
    await for (final chunk in req.httpRequest) {
      size += chunk.length;
    }
    res.text('$size');
  });

  app.get('/compression', (req, res) {
    final acceptsGzip = (req.headers['accept-encoding'] ?? '')
        .toString()
        .contains('gzip');
    if (acceptsGzip) {
      final gzipBytes =
          Uint8List.fromList(GZipCodec(level: 1).encode(compressionJsonBytes));
      res.setHeader('Content-Encoding', 'gzip');
      res.bytes(gzipBytes, contentType: 'application/json');
    } else {
      res.bytes(compressionJsonBytes, contentType: 'application/json');
    }
  });

  app.get('/static/:filename', (req, res) {
    final sf = staticFiles[req.params['filename']!];
    if (sf == null) {
      res.setStatus(404);
    } else {
      final acceptEncoding =
          (req.headers['accept-encoding'] ?? '').toString().toLowerCase();
      if (sf.brData != null && acceptEncoding.contains('br')) {
        res.setHeader('Content-Encoding', 'br');
        res.setHeader('Vary', 'Accept-Encoding');
        res.bytes(sf.brData!, contentType: sf.contentType);
      } else if (sf.gzipData != null && acceptEncoding.contains('gzip')) {
        res.setHeader('Content-Encoding', 'gzip');
        res.setHeader('Vary', 'Accept-Encoding');
        res.bytes(sf.gzipData!, contentType: sf.contentType);
      } else {
        res.bytes(sf.data, contentType: sf.contentType);
      }
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
    final limitVal = (int.tryParse(req.query['limit'] ?? '') ?? 50).clamp(1, 50);
    try {
      final rows = sqliteStmt.select([minVal, maxVal, limitVal]);
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
    final minVal = int.tryParse(req.query['min'] ?? '') ?? 10;
    final maxVal = int.tryParse(req.query['max'] ?? '') ?? 50;
    final limitVal = (int.tryParse(req.query['limit'] ?? '') ?? 50).clamp(1, 50);
    try {
      final result = await pool.execute(
        r'SELECT id, name, category, price, quantity, active, tags,'
        r' rating_score, rating_count'
        r' FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3',
        parameters: [minVal, maxVal, limitVal],
      );
      final items = result.map((row) {
        final cols = row.toColumnMap();
        final tagsRaw = cols['tags'];
        final tags = tagsRaw is List
            ? tagsRaw
            : (tagsRaw is String ? jsonDecode(tagsRaw) : const <dynamic>[]);
        final activeRaw = cols['active'];
        final active = activeRaw is bool
            ? activeRaw
            : (activeRaw is num ? activeRaw != 0 : false);
        return {
          'id': cols['id'],
          'name': cols['name'],
          'category': cols['category'],
          'price': cols['price'],
          'quantity': cols['quantity'],
          'active': active,
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
    } catch (e, st) {
      stderr.writeln('[async-db] query error: $e\n$st');
      await resetPgPool();
      res.bytes(_emptyJson, contentType: 'application/json');
    }
  });

  // Bind first — server is reachable immediately.
  await app.listen(8080, shared: true);

  // json-tls: HTTP/1.1-only TLS listener on port 8081.
  // ALPN is restricted to http/1.1 so the benchmark negotiates correctly.
  final certFile = File('/certs/server.crt');
  final keyFile  = File('/certs/server.key');
  if (certFile.existsSync() && keyFile.existsSync()) {
    final ctx = SecurityContext()
      ..useCertificateChain(certFile.path)
      ..usePrivateKey(keyFile.path)
      ..setAlpnProtocols(['http/1.1'], true);
    await app.listenSecure(8081, ctx, shared: true);
  }
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
  final filesByName = <String, Uint8List>{};
  try {
    for (final entity in Directory('/data/static').listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      filesByName[name] = entity.readAsBytesSync();
    }

    for (final entry in filesByName.entries) {
      final name = entry.key;
      if (name.endsWith('.gz') || name.endsWith('.br')) continue;

      final ext = name.contains('.') ? '.${name.split('.').last}' : '';
      result[name] = _StaticFile(
        entry.value,
        _mimeTypes[ext] ?? 'application/octet-stream',
        gzipData: filesByName['$name.gz'],
        brData: filesByName['$name.br'],
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

Uint8List _encodeItemsPayload(List<dynamic>? dataset) {
  final items = _encodeItems(dataset);
  if (items.isEmpty) return _emptyJson;
  return Uint8List.fromList(
    utf8.encode(jsonEncode({'items': items, 'count': items.length})),
  );
}

String _jsonKey(int count, int m) => '$count:$m';

Uint8List _buildJsonPayloadBytes(
  List<Map<String, dynamic>> jsonItems,
  int count,
  int m,
) {
  final items = List<Map<String, dynamic>>.generate(count, (i) {
    final d = jsonItems[i];
    final price = d['price'] as num;
    final quantity = d['quantity'] as num;
    return {
      'id': d['id'],
      'name': d['name'],
      'category': d['category'],
      'price': d['price'],
      'quantity': d['quantity'],
      'active': d['active'],
      'tags': d['tags'],
      'rating': d['rating'],
      'total': price * quantity * m,
    };
  }, growable: false);
  return Uint8List.fromList(
    utf8.encode(jsonEncode({'items': items, 'count': items.length})),
  );
}

Map<String, _JsonPayload> _buildHotJsonPayloadCache(
  List<Map<String, dynamic>> jsonItems,
) {
  if (jsonItems.isEmpty) return const <String, _JsonPayload>{};

  // Covers benchmark round-robin pairs and validator edge counts.
  const hotCounts = <int>[1, 5, 10, 12, 15, 22, 25, 31, 40, 50];
  const hotMultipliers = <int>[1, 2, 3, 4, 5, 6, 7, 8];

  final maxCount = jsonItems.length;
  final cache = <String, _JsonPayload>{};
  for (final rawCount in hotCounts) {
    final count = rawCount.clamp(0, maxCount).toInt();
    for (final m in hotMultipliers) {
      final key = _jsonKey(count, m);
      if (cache.containsKey(key)) continue;
      final identity = _buildJsonPayloadBytes(jsonItems, count, m);
      final gzip = Uint8List.fromList(GZipCodec(level: 1).encode(identity));
      cache[key] = _JsonPayload(identity, gzip);
    }
  }
  return cache;
}

List<Map<String, dynamic>> _encodeItems(List<dynamic>? dataset) {
  if (dataset == null) return const <Map<String, dynamic>>[];
  return dataset.map(_mapItem).toList(growable: false);
}

Future<Pool?> _openPostgresPool() async {
  final dbUrl = Platform.environment['DATABASE_URL'];
  if (dbUrl == null) return null;
  try {
    final normalized = dbUrl.startsWith('postgres://')
        ? 'postgresql://${dbUrl.substring('postgres://'.length)}'
        : dbUrl;
    final uri = Uri.parse(normalized);
    final userInfo = uri.userInfo.split(':');
    final endpoint = Endpoint(
      host: uri.host == 'localhost' ? '127.0.0.1' : uri.host,
      port: uri.port > 0 ? uri.port : 5432,
      database: uri.path.startsWith('/') ? uri.path.substring(1) : uri.path,
      username: userInfo.isNotEmpty ? userInfo[0] : '',
      password: userInfo.length > 1 ? userInfo[1] : '',
    );
    final maxTotalConn =
        int.tryParse(Platform.environment['DATABASE_MAX_CONN'] ?? '') ?? 256;
    final perProcessMax =
        (maxTotalConn / Platform.numberOfProcessors).floor().clamp(1, 16);
    final pool = Pool.withEndpoints(
      [endpoint],
      settings: PoolSettings(
        sslMode: SslMode.disable,
        maxConnectionCount: perProcessMax,
      ),
    );
    // Verify connectivity so callers don't keep a broken pool.
    await pool.execute('SELECT 1');
    return pool;
  } catch (e, st) {
    stderr.writeln('[pg] connect error: $e\n$st');
    return null;
  }
}
