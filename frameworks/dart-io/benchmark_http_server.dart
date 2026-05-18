import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

int _sumQuery(Uri uri) {
  var sum = 0;
  for (final value in uri.queryParameters.values) {
    final parsed = int.tryParse(value);
    if (parsed != null) sum += parsed;
  }
  return sum;
}

int _bodyValue(List<int> bytes) {
  if (bytes.isEmpty) return 0;
  return int.tryParse(utf8.decode(bytes).trim()) ?? 0;
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
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
  print('dart:io benchmark HTTP server on port $port');

  await for (final req in server) {
    final uri = req.uri;
    if (uri.path == '/pipeline') {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
        ..write('ok');
      await req.response.close();
      continue;
    }

    if (uri.path == '/baseline11') {
      final body = await req.fold<List<int>>(<int>[], (acc, chunk) {
        acc.addAll(chunk);
        return acc;
      });
      final total = _sumQuery(uri) + _bodyValue(body);
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
        ..write(total);
      await req.response.close();
      continue;
    }

    if (uri.pathSegments.length == 2 && uri.pathSegments[0] == 'json') {
      final requestedCount = int.tryParse(uri.pathSegments[1]) ?? 0;
      final multiplier = int.tryParse(uri.queryParameters['m'] ?? '') ?? 1;
      final payload = _jsonPayload(jsonItems, requestedCount, multiplier);
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
        ..add(payload);
      await req.response.close();
      continue;
    }

    req.response
      ..statusCode = 404
      ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
      ..write('not found');
    await req.response.close();
  }
}
