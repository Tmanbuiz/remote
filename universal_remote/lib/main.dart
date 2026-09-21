import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/remote_controller.dart';
import 'storage/device_store.dart';
import 'ui/device_list_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await DeviceStore.open();
  runApp(UniversalRemoteApp(store: store));
}

class UniversalRemoteApp extends StatelessWidget {
  const UniversalRemoteApp({super.key, required this.store});

  final DeviceStore store;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => RemoteController(store)..loadSaved(),
      child: MaterialApp(
        title: 'Universal Remote',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        // A remote is used in a dark room more often than not, so the dark
        // theme is the one that gets the attention.
        themeMode: ThemeMode.system,
        home: const DeviceListPage(),
      ),
    );
  }

  static ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3B6EF5),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF0E1116)
          : scheme.surface,
    );
  }
}
