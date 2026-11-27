import 'package:dox_view/dox_view.dart';

/// Templates in resources/views, parsed once and cached.
class AppViewProvider extends ViewProvider {
  AppViewProvider() : super(const ViewConfig(cache: true));
}
