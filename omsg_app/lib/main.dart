import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/core/deep_links/deep_link_source.dart';
export 'src/app.dart' show AstraMessengerApp;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const deepLinkSource = PlatformDeepLinkSource();
  runApp(
    ProviderScope(child: AstraMessengerApp(deepLinkSource: deepLinkSource)),
  );
}
