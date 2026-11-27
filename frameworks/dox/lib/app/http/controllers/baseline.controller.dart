import 'dart:convert';
import 'dart:math';

import 'package:dox_core/dox_core.dart';

class BaselineController {
  /// POST /baseline11?a=1&b=2: the sum of a, b and the body number.
  Future<String> sum(DoxRequest req) async {
    int total = req.integer('a') + req.integer('b');
    // Dox does not read a text/plain body, so read it here.
    String body = await utf8.decoder.bind(req.httpRequest).join();
    return (total + (int.tryParse(body.trim()) ?? 0)).toString();
  }

  /// GET /baseline11?a=1&b=2 and GET /baseline2?a=1&b=1 (h2c): the sum
  /// of a and b. A GET has no body, so there is nothing to read.
  String querySum(DoxRequest req) {
    return (req.integer('a') + req.integer('b')).toString();
  }

  String pipeline(DoxRequest req) {
    return 'ok';
  }

  /// GET /delay/{ms}: waits ms with a real timer.
  Future<String> delay(DoxRequest req) async {
    int ms = max(0, int.tryParse('${req.param['ms']}') ?? 0);
    await Future<void>.delayed(Duration(milliseconds: ms));
    return ms.toString();
  }
}
