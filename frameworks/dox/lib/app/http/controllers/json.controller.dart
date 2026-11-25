import 'package:dox_core/dox_core.dart';
import 'package:httparena_dox/app/services/dataset.service.dart';

class JsonController {
  JsonController(this.dataset);

  final DatasetService dataset;

  /// GET /json/{count}?m=N
  Map<String, dynamic> items(DoxRequest req) {
    int count = int.tryParse('${req.param['count']}') ?? 0;
    List<Map<String, dynamic>> items = dataset.take(count, req.integer('m', 1));
    return <String, dynamic>{'items': items, 'count': items.length};
  }
}
