import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/db.dart';
import 'data/repo.dart';
import 'sync/sync_service.dart';
import 'ui/accounts_page.dart';
import 'ui/invoices_page.dart';
import 'ui/parties_page.dart';
import 'ui/reports_page.dart';
import 'ui/sync_page.dart';
import 'ui/transactions_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initDatabaseFactory();
  final repo = Repo(await AppDb.open());
  final sync = SyncService(repo);
  try {
    await sync.startServer();
  } catch (_) {
    // Port busy or no network permission: the app still works offline and can
    // still push to the other device.
  }
  runApp(AccountingApp(repo: repo, sync: sync));
}

class AccountingApp extends StatelessWidget {
  const AccountingApp({super.key, required this.repo, required this.sync});
  final Repo repo;
  final SyncService sync;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'حسابداری ساده',
        debugShowCheckedModeBanner: false,
        locale: const Locale('fa', 'IR'),
        supportedLocales: const [Locale('fa', 'IR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: HomePage(repo: repo, sync: sync),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.repo, required this.sync});
  final Repo repo;
  final SyncService sync;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;

  static const _items = [
    ('حساب‌ها', Icons.account_balance_wallet_outlined),
    ('تراکنش‌ها', Icons.swap_vert),
    ('فاکتورها', Icons.receipt_long_outlined),
    ('اشخاص', Icons.people_outline),
    ('گزارش', Icons.bar_chart),
    ('همگام‌سازی', Icons.sync),
  ];

  Widget _page() => switch (index) {
        0 => AccountsPage(repo: widget.repo),
        1 => TransactionsPage(repo: widget.repo),
        2 => InvoicesPage(repo: widget.repo),
        3 => PartiesPage(repo: widget.repo),
        4 => ReportsPage(repo: widget.repo),
        _ => SyncPage(repo: widget.repo, sync: widget.sync),
      };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final page = KeyedSubtree(key: ValueKey(index), child: _page());
    return Scaffold(
      appBar: AppBar(title: Text(_items[index].$1)),
      drawer: wide
          ? null
          : NavigationDrawer(
              selectedIndex: index,
              onDestinationSelected: (i) {
                Navigator.pop(context);
                setState(() => index = i);
              },
              children: [
                const SizedBox(height: 16),
                for (final it in _items) NavigationDrawerDestination(icon: Icon(it.$2), label: Text(it.$1)),
              ],
            ),
      body: wide
          ? Row(children: [
              NavigationRail(
                selectedIndex: index,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => setState(() => index = i),
                destinations: [
                  for (final it in _items) NavigationRailDestination(icon: Icon(it.$2), label: Text(it.$1)),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: page),
            ])
          : page,
    );
  }
}
