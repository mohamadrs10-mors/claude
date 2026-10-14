import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/app_lock.dart';
import 'data/backup_service.dart';
import 'data/company_manager.dart';
import 'data/db.dart';
import 'data/repo.dart';
import 'sync/sync_service.dart';
import 'ui/accounts_page.dart';
import 'ui/app_theme.dart';
import 'ui/cheques_page.dart';
import 'ui/companies_page.dart';
import 'ui/costing_page.dart';
import 'ui/dashboard_page.dart';
import 'ui/deliveries_page.dart';
import 'ui/invoices_page.dart';
import 'ui/lock_screen.dart';
import 'ui/parties_page.dart';
import 'ui/products_page.dart';
import 'ui/reports_page.dart';
import 'ui/settings_page.dart';
import 'ui/sync_page.dart';
import 'ui/transactions_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initDatabaseFactory();
  final companies = await CompanyManager.open();
  final theme = AppTheme(companies.prefs);
  await theme.load();
  final sync = SyncService(companies);
  try {
    await sync.startServer();
  } catch (_) {
    // Port busy or no network permission: the app still works offline and can
    // still push to the other device.
  }
  final lock = AppLock(companies.prefs);
  final backups = BackupService(companies);
  // Daily automatic backups: once shortly after start, then every few hours.
  Timer(const Duration(seconds: 8), backups.runIfDue);
  Timer.periodic(const Duration(hours: 3), (_) => backups.runIfDue());
  runApp(AccountingApp(companies: companies, sync: sync, theme: theme, lock: lock, backups: backups));
}

class AccountingApp extends StatelessWidget {
  const AccountingApp({super.key, required this.companies, required this.sync, required this.theme, required this.lock, required this.backups});
  final AppLock lock;
  final BackupService backups;
  final CompanyManager companies;
  final SyncService sync;
  final AppTheme theme;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([theme, companies, lock]),
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
          // A new key per company rebuilds every screen with that company's data.
          home: _Lifecycle(
            lock: lock,
            child: lock.isUnlocked(companies.activeId)
                ? HomePage(key: ValueKey(companies.activeId), repo: companies.active, companies: companies, sync: sync, theme: theme, lock: lock, backups: backups)
                : LockScreen(key: ValueKey('lock${companies.activeId}'), lock: lock, companies: companies),
          ),
        ),
      );
}

/// Tells the lock when the app goes to the background and comes back.
class _Lifecycle extends StatefulWidget {
  const _Lifecycle({required this.lock, required this.child});
  final AppLock lock;
  final Widget child;
  @override
  State<_Lifecycle> createState() => _LifecycleState();
}

class _LifecycleState extends State<_Lifecycle> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) widget.lock.appPaused();
    if (state == AppLifecycleState.resumed) widget.lock.appResumed();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
  _Dest('deliveries', 'رسید تحویل', Icons.local_shipping_outlined, Icons.local_shipping),
  _Dest('products', 'کالاها و انبار', Icons.inventory_2_outlined, Icons.inventory_2),
  _Dest('pricing', 'قیمت‌گذاری', Icons.calculate_outlined, Icons.calculate),
  _Dest('parties', 'اشخاص', Icons.people_outline, Icons.people),
  _Dest('cheques', 'چک‌ها', Icons.payments_outlined, Icons.payments),
  _Dest('accounts', 'حساب‌ها', Icons.account_balance_wallet_outlined, Icons.account_balance_wallet),
  _Dest('reports', 'گزارش‌ها', Icons.bar_chart_outlined, Icons.bar_chart),
  _Dest('sync', 'همگام‌سازی', Icons.sync, Icons.sync),
  _Dest('companies', 'شرکت‌ها', Icons.business_outlined, Icons.business),
  _Dest('settings', 'تنظیمات', Icons.settings_outlined, Icons.settings),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.repo, required this.companies, required this.sync, required this.theme, required this.lock, required this.backups});
  final AppLock lock;
  final BackupService backups;
  final Repo repo;
  final CompanyManager companies;
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
        'deliveries' => DeliveriesPage(repo: widget.repo),
        'products' => ProductsPage(repo: widget.repo),
        'pricing' => CostingPage(repo: widget.repo, embedded: true),
        'parties' => PartiesPage(repo: widget.repo),
        'cheques' => ChequesPage(repo: widget.repo),
        'accounts' => AccountsPage(repo: widget.repo),
        'reports' => ReportsPage(repo: widget.repo),
        'sync' => SyncPage(repo: widget.repo, sync: widget.sync, companies: widget.companies),
        'companies' => CompaniesPage(companies: widget.companies, onOpenSync: () => setState(() => page = 'sync')),
        _ => SettingsPage(repo: widget.repo, theme: widget.theme, lock: widget.lock, backups: widget.backups),
      };

  Widget _sidebar({bool inDrawer = false}) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: PopupMenuButton<String>(
            tooltip: 'تغییر شرکت',
            position: PopupMenuPosition.under,
            onSelected: (v) async {
              if (v == '#new') {
                await addCompanyDialog(context, widget.companies);
              } else if (v == '#manage') {
                if (inDrawer) Navigator.pop(context);
                _go('companies');
              } else {
                await widget.companies.switchTo(v);
              }
            },
            itemBuilder: (_) => [
              for (final c in widget.companies.companies)
                PopupMenuItem(
                  value: c.id,
                  child: Row(children: [
                    Icon(c.id == widget.companies.activeId ? Icons.check_circle : Icons.circle_outlined, size: 18),
                    const SizedBox(width: 8),
                    Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: '#new', child: ListTile(dense: true, leading: Icon(Icons.add_business_outlined), title: Text('شرکت جدید'))),
              const PopupMenuItem(value: '#manage', child: ListTile(dense: true, leading: Icon(Icons.settings_suggest_outlined), title: Text('مدیریت شرکت‌ها'))),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(children: [
                Image.asset('assets/logo.png', width: 42, height: 42, filterQuality: FilterQuality.medium),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.companies.activeInfo.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    Text(widget.companies.companies.length > 1 ? 'تغییر شرکت' : 'حسابداری', style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                const Icon(Icons.unfold_more, size: 20),
              ]),
            ),
          ),
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
