import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'bridge/link.dart';
import 'screens/shell.dart';
import 'store.dart';
import 'widgets/neu.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HarnessApp());
}

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orubous Harness',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: Neu.bg,
        colorScheme: ColorScheme.fromSeed(
            seedColor: Neu.accent, brightness: Brightness.light),
      ),
      home: const HarnessHome(),
    );
  }
}

class HarnessHome extends StatefulWidget {
  const HarnessHome({super.key});

  @override
  State<HarnessHome> createState() => _HarnessHomeState();
}

class _HarnessHomeState extends State<HarnessHome> {
  final Store store = Store();
  bool ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await store.load();
    if (!store.hasIdentity) {
      store.generateIdentity();
      await store.save();
    }
    final d = await getApplicationDocumentsDirectory();
    Link.i.workspace = d.path;
    await Link.i.loadHistory();
    // auto-resume: the bridge comes back by itself after app closes/kills
    Link.i.onOnlineChanged = (on) {
      store.wasOnline = on;
      store.save();
    };
    await Link.i.autoResume(store);
    if (!mounted) return;
    setState(() => ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return Scaffold(
        backgroundColor: Neu.bg,
        body: const Center(
          child: CircularProgressIndicator(color: Neu.accentDeep),
        ),
      );
    }
    return HarnessShell(store: store);
  }
}
