// HttpArena benchmark app for dart-zig.
// This source is owned by HttpArena. The framework Dockerfile compiles it in
// a builder stage, then copies the generated .dill into the runtime image.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'zig_http_server.dart';

int _sumQuery(Uri uri) {
  var sum = 0;
  for (final value in uri.queryParameters.values) {
    final parsed = int.tryParse(value);
    if (parsed != null) sum += parsed;
  }
  return sum;
}

int _bodyValue(ZigHttpRequest req) {
  if (req.bodyBytes.isEmpty) return 0;
  return int.tryParse(req.bodyText.trim()) ?? 0;
}

List<Map<String, dynamic>> _loadDataset(String path) {
  try {
    final decoded = jsonDecode(File(path).readAsStringSync()) as List;
    return decoded
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
  } catch (_) {
    return const <Map<String, dynamic>>[];
  }
}

Uint8List _jsonPayload(List<Map<String, dynamic>> items, int count, int m) {
  final clamped = count.clamp(0, items.length).toInt();
  final out = List<Map<String, dynamic>>.generate(clamped, (i) {
    final item = items[i];
    final price = item['price'] as num;
    final quantity = item['quantity'] as num;
    return <String, dynamic>{
      'id': item['id'],
      'name': item['name'],
      'category': item['category'],
      'price': item['price'],
      'quantity': item['quantity'],
      'active': item['active'],
      'tags': item['tags'],
      'rating': item['rating'],
      'total': price * quantity * m,
    };
  }, growable: false);

  return Uint8List.fromList(
    utf8.encode(jsonEncode(<String, dynamic>{'items': out, 'count': out.length})),
  );
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;
  final jsonItems = _loadDataset('/data/dataset.json');
  final server = await ZigHttpServer.bind('0.0.0.0', port);
  print('dart-zig benchmark HTTP server on port $port');

  final done = Completer<void>();
  server.stream.listen(
    (req) {
      switch (req.path) {
        case '/pipeline':
          req.response
            ..statusCode = 200
            ..headers.set('content-type', 'text/plain; charset=utf-8')
            ..write('ok')
            ..close();
          break;
        default:
          final uri = req.uri;
          if (uri.path == '/baseline11') {
            final total = _sumQuery(uri) + _bodyValue(req);
            req.response
              ..statusCode = 200
              ..headers.set('content-type', 'text/plain; charset=utf-8')
              ..write(total)
              ..close();
          } else if (uri.pathSegments.length == 2 &&
              uri.pathSegments[0] == 'json') {
            final requestedCount = int.tryParse(uri.pathSegments[1]) ?? 0;
            final multiplier = int.tryParse(uri.queryParameters['m'] ?? '') ?? 1;
            final payload = _jsonPayload(jsonItems, requestedCount, multiplier);
            req.response
              ..statusCode = 200
              ..headers.set('content-type', 'application/json')
              ..add(payload)
              ..close();
          } else {
            req.response
              ..statusCode = 404
              ..headers.set('content-type', 'text/plain; charset=utf-8')
              ..write('not found')
              ..close();
          }
      }
    },
    onDone: done.complete,
  );

  await done.future;
}
