import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/data/local_inventory_database.dart';
import 'src/ui/app_home.dart';
import 'src/ui/login_page.dart';

void main() async {
  // 确保 Flutter Engine 初始化，以便进行本地 SQFlite 数据库操作
  WidgetsFlutterBinding.ensureInitialized();

  final database = LocalInventoryDatabase();
  await database.open();

  var activeShopId = await database.loadActiveShopId();

  if (activeShopId.isEmpty) {
    // 首次启动，后台默认静默激活“本地默认店铺”，免密直达主页
    const defaultLocalShopId = '00000000-0000-0000-0000-000000000000';
    await database.saveAuthMode('offline');
    await database.saveActiveShopId(defaultLocalShopId);
    await database.saveActiveShopName('本地默认店铺');
    await database.saveAuthToken('');
    await database.saveSyncServerUrl('');
    activeShopId = defaultLocalShopId;
  }

  // 只要拥有已激活的店铺（无论是默认本地店铺还是云端店铺），直接进入 AppHome ；否则进入登录网关
  final Widget homeScreen = activeShopId.isNotEmpty
      ? const AppHome()
      : const LoginPage();

  runApp(InventoryApp(homeScreen: homeScreen));
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
