import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/ui/workspace_bootstrap_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InventoryApp(homeScreen: WorkspaceBootstrapPage()));
}

class InventoryApp extends StatelessWidget {
  const InventoryApp({super.key, required this.homeScreen});

  final Widget homeScreen;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '云推推库存管理',
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      scrollBehavior: const _NoStretchScrollBehavior(),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2d6a4f)),
        scaffoldBackgroundColor: const Color(0xFFF4F9F4),
        useMaterial3: true,
      ),
      home: homeScreen,
    );
  }
}

class _NoStretchScrollBehavior extends MaterialScrollBehavior {
  const _NoStretchScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
