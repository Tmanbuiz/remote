import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/home_monitor.dart';
import 'core/remote_controller.dart';
import 'storage/device_store.dart';
import 'ui/device_list_page.dart';
import 'ui/theme.dart';

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
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => RemoteController(store)..loadSaved()),
        // Lives for the whole app so the monitor survives leaving its page.
        ChangeNotifierProvider(create: (_) => HomeMonitor()),
      ],
      child: MaterialApp(
        title: 'Universal Remote',
        debugShowCheckedModeBanner: false,
        theme: RemoteTheme.build(),
        darkTheme: RemoteTheme.build(),
        // Deliberately not ThemeMode.system — see RemoteTheme.
        themeMode: ThemeMode.dark,
        home: const DeviceListPage(),
      ),
    );
  }
}
