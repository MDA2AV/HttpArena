import 'dart:io';

import 'package:dox_core/dox_core.dart';

/// The items of the dataset file, with a total for a multiplier.
class DatasetService {
  DatasetService(this.path);

  final String path;

  /// Read once per isolate, on first use.
  late final List<Map<String, dynamic>> _items = _load();

  List<Map<String, dynamic>> _load() {
    try {
      List<dynamic> list =
          JSON.parse(File(path).readAsBytesSync()) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } catch (err) {
      return <Map<String, dynamic>>[];
    }
  }

  /// The first [count] items, each with `total = price * quantity * m`.
  List<Map<String, dynamic>> take(int count, int m) {
    int n = count.clamp(0, _items.length);
    List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (int i = 0; i < n; i++) {
      Map<String, dynamic> item = _items[i];
      out.add(<String, dynamic>{
        ...item,
        'total': (item['price'] as num) * (item['quantity'] as num) * m,
      });
    }
    return out;
  }
}
