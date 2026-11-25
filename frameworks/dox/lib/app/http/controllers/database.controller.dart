import 'package:dox_core/dox_core.dart';
import 'package:dox_orm/dox_orm.dart';
import 'package:dox_view/dox_view.dart';

class DatabaseController {
  static const List<String> _itemColumns = <String>[
    'id',
    'name',
    'category',
    'price',
    'quantity',
    'active',
    'tags',
    'rating_score',
    'rating_count',
  ];

  /// GET /async-db?min=10&max=50&limit=50
  Future<Map<String, dynamic>> items(DoxRequest req) async {
    try {
      List<Map<String, dynamic>> rows = await QueryBuilder.table('items')
          .select(_itemColumns)
          .whereBetween('price', <int>[
            req.integer('min', 10),
            req.integer('max', 50),
          ])
          .limit(req.integer('limit', 50).clamp(1, 50))
          .get();
      List<Map<String, dynamic>> items = rows.map(_item).toList();
      return <String, dynamic>{'items': items, 'count': items.length};
    } catch (err) {
      return <String, dynamic>{'items': <dynamic>[], 'count': 0};
    }
  }

  Map<String, dynamic> _item(Map<String, dynamic> row) {
    Object? tags = row['tags'];
    return <String, dynamic>{
      'id': row['id'],
      'name': row['name'],
      'category': row['category'],
      'price': row['price'],
      'quantity': row['quantity'],
      'active': row['active'],
      'tags': tags is String ? JSON.parse(tags) : tags,
      'rating': <String, dynamic>{
        'score': row['rating_score'],
        'count': row['rating_count'],
      },
    };
  }

  /// GET /fortunes, rendered by the dox_view template engine.
  Future<DoxResponse> fortunes(DoxRequest req) async {
    List<Map<String, dynamic>> list = <Map<String, dynamic>>[
      ...await QueryBuilder.table('fortune')
          .select(<String>['id', 'message'])
          .get(),
      <String, dynamic>{
        'id': 0,
        'message': 'Additional fortune added at request time.',
      },
    ];
    list.sort(_byMessage);
    return view(req, 'fortunes', <String, dynamic>{'fortunes': list});
  }

  /// Ordinal order, not locale order.
  static int _byMessage(Map<String, dynamic> a, Map<String, dynamic> b) {
    return (a['message'] as String).compareTo(b['message'] as String);
  }
}
