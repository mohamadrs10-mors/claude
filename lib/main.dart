import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/db.dart';
import 'data/repo.dart';
import 'sync/sync_service.dart';
import 'ui/accounts_page.dart';
import 'ui/app_theme.dart';
import 'ui/cheques_page.dart';
import 'ui/costing_page.dart';
import 'ui/dashboard_page.dart';
import 'ui/invoices_page.dart';
import 'ui/parties_page.dart';
import 'ui/products_page.dart';
import 'ui/reports_page.dart';
import 'ui/settings_page.dart';
import 'ui/sync_page.dart';
import 'ui/transactions_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initDatabaseFactory();
  final repo = Repo(await AppDb.open());
  await repo.init();
  final theme = AppTheme(repo.store);
  await theme.load();
  final sync = SyncService(repo);
  try {
    await sync.startServer();
  } catch (_) {
    // Port busy or no network permission: the app still works offline and can
    // still push to the other device.
  }
  runApp(AccountingApp(repo: repo, sync: sync, theme: theme));
}

class AccountingApp extends StatelessWidget {
  const AccountingApp({super.key, required this.repo, required this.sync, required this.theme});
  final Repo repo;
  final SyncService sync;
  final AppTheme theme;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: theme,
        builder: (context, _) => MaterialApp(
          title: 'حسابداری ساده',
          debugShowCheckedModeBanner: false,
          locale: const Locale('fa', 'IR'),
          supportedLocales: const [Locale('fa', 'IR')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          themeMode: theme.mode,
          theme: theme.build(Brightness.light),
          darkTheme: theme.build(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(theme.fontScale)),
            child: child!,
          ),
          home: HomePage(repo: repo, sync: sync, theme: theme),
        ),
      );
}

class _Dest {
  const _Dest(this.id, this.label, this.icon, this.selectedIcon);
  final String id, label;
  final IconData icon, selectedIcon;
}

const _dests = [
  _Dest('dashboard', 'داشبورد', Icons.space_dashboard_outlined, Icons.space_dashboard),
  _Dest('transactions', 'تراکنش‌ها', Icons.swap_vert, Icons.swap_vert),
  _Dest('invoices', 'فاکتورها', Icons.receipt_long_outlined, Icons.receipt_long),
  _Dest('products', 'کالاها و انبار', Icons.inventory_2_outlined, Icons.inventory_2),
  _Dest('pricing', 'قیمت‌گذاری', Icons.calculate_outlined, Icons.calculate),
  _Dest('parties', 'اشخاص', Icons.people_outline, Icons.people),
  _Dest('cheques', 'چک‌ها', Icons.payments_outlined, Icons.payments),
  _Dest('accounts', 'حساب‌ها', Icons.account_balance_wallet_outlined, Icons.account_balance_wallet),
  _Dest('reports', 'گزارش‌ها', Icons.bar_chart_outlined, Icons.bar_chart),
  _Dest('sync', 'همگام‌سازی', Icons.sync, Icons.sync),
  _Dest('settings', 'تنظیمات', Icons.settings_outlined, Icons.settings),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.repo, required this.sync, required this.theme});
  final Repo repo;
  final SyncService sync;
  final AppTheme theme;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String page = 'dashboard';

  void _go(String id) {
    if (id == 'new_invoice') {
      openInvoiceEditor(context, widget.repo);
      return;
    }
    setState(() => page = id);
  }

  Widget _body() => switch (page) {
        'dashboard' => DashboardPage(repo: widget.repo, onNavigate: _go),
        'transactions' => TransactionsPage(repo: widget.repo),
        'invoices' => InvoicesPage(repo: widget.repo),
        'products' => ProductsPage(repo: widget.repo),
        'pricing' => CostingPage(repo: widget.repo, embedded: true),
        'parties' => PartiesPage(repo: widget.repo),
        'cheques' => ChequesPage(repo: widget.repo),
        'accounts' => AccountsPage(repo: widget.repo),
        'reports' => ReportsPage(repo: widget.repo),
        'sync' => SyncPage(repo: widget.repo, sync: widget.sync),
        _ => SettingsPage(repo: widget.repo, theme: widget.theme),
      };

  Widget _sidebar({bool inDrawer = false}) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(12)),
              child: Icon(Icons.calculate_outlined, color: scheme.onPrimary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(widget.repo.setting('business_name', 'حسابداری ساده'),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final d in _dests)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: ListTile(
                  dense: true,
                  selected: page == d.id,
                  selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.7),
                  selectedColor: scheme.onPrimaryContainer,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: Icon(page == d.id ? d.selectedIcon : d.icon),
                  title: Text(d.label, style: TextStyle(fontWeight: page == d.id ? FontWeight.w700 : FontWeight.w500)),
                  onTap: () {
                    if (inDrawer) Navigator.pop(context);
                    _go(d.id);
                  },
                ),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: IconButton(
            tooltip: 'تغییر حالت روشن/تیره',
            icon: Icon(Theme.of(context).brightness == Brightness.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: () => widget.theme.setMode(Theme.of(context).brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 820;
    final dest = _dests.firstWhere((d) => d.id == page);
    final content = KeyedSubtree(key: ValueKey(page), child: _body());
    return Scaffold(
      appBar: wide ? null : AppBar(title: Text(dest.label)),
      drawer: wide ? null : Drawer(child: _sidebar(inDrawer: true)),
      body: wide
          ? Row(children: [
              SizedBox(width: 248, child: Material(color: Theme.of(context).colorScheme.surfaceContainerLow, child: _sidebar())),
              VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
              Expanded(
                child: Column(children: [
                  Container(
                    height: 64,
                    alignment: AlignmentDirectional.centerStart,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(dest.label, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  Expanded(child: content),
                ]),
              ),
            ])
          : content,
    );
  }
}
