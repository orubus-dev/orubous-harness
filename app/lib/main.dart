import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'bridge/link.dart';
import 'screens/bridge.dart';
import 'screens/chat.dart';
import 'screens/settings.dart';
import 'store.dart';

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
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7C4DFF), brightness: Brightness.dark),
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
  String docsDir = '';
  bool ready = false;
  int tab = 1; // start on Bridge — that's the heart of the harness

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
    if (!mounted) return;
    setState(() {
      docsDir = d.path;
      ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final pages = [
      ChatScreen(store: store),
      BridgeScreen(store: store, workspace: docsDir),
      SettingsScreen(store: store, docsDir: docsDir),
    ];
    return Scaffold(
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.settings_remote), label: 'Bridge'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
        ],
      ),
    );
  }
}
