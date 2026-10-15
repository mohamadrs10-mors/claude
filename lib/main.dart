import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/access.dart';
import 'data/app_lock.dart';
import 'data/backup_service.dart';
import 'data/company_manager.dart';
import 'data/db.dart';
import 'data/net_mode.dart';
import 'data/remote_db.dart';
import 'data/remote_session.dart';
import 'data/repo.dart';
import 'data/users.dart';
import 'sync/mobile_sync.dart';
import 'sync/sync_service.dart';
import 'ui/accounts_page.dart';
import 'ui/app_theme.dart';
import 'ui/auth.dart';
import 'ui/client_root.dart';
import 'ui/mobile_root.dart';
import 'ui/network_page.dart';
import 'ui/users_page.dart';
import 'ui/cheques_page.dart';
import 'ui/companies_page.dart';
import 'ui/costing_page.dart';
import 'ui/dashboard_page.dart';
import 'ui/deliveries_page.dart';
import 'ui/invoices_page.dart';
import 'ui/orders_page.dart';
import 'ui/lock_screen.dart';
import 'ui/parties_page.dart';
import 'ui/products_page.dart';
import 'ui/reports_page.dart';
import 'ui/settings_page.dart';
import 'ui/sync_page.dart';
import 'ui/transactions_page.dart';
import 'ui/warehouses_page.dart';

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
  final net = NetMode(companies.prefs);
  final auth = LocalAuth(companies, sync);
  final mobile = MobileController(companies.prefs);
  FlutterError.onError = (d) {
    if (!_report(d.exception)) FlutterError.presentError(d);
  };
  PlatformDispatcher.instance.onError = (e, st) => _report(e);
  // Daily automatic backups: once shortly after start, then every few hours.
  Timer(const Duration(seconds: 8), backups.runIfDue);
  Timer.periodic(const Duration(hours: 3), (_) => backups.runIfDue());
  runApp(AccountingApp(companies: companies, sync: sync, theme: theme, lock: lock, backups: backups, net: net, auth: auth, mobile: mobile));
}

final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Shows a friendly message for the errors of permissions and the network
/// instead of letting them crash an action; returns whether it handled [e].
bool _report(Object e) {
  String? text;
  if (e is AccessDenied) {
    text = e.message;
  } else if (e is NetException && e.offline) {
    text = 'ارتباط با سرور برقرار نیست.';
  } else if (e is SessionEnded) {
    return true; // the session screen explains it
  }
  if (text == null) return false;
  rootMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));
  return true;
}

class AccountingApp extends StatelessWidget {
  const AccountingApp({super.key, required this.companies, required this.sync, required this.theme, required this.lock, required this.backups, required this.net, required this.auth, required this.mobile});
  final NetMode net;
  final LocalAuth auth;
  final MobileController mobile;
  final AppLock lock;
  final BackupService backups;
  final CompanyManager companies;
  final SyncService sync;
  final AppTheme theme;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([theme, companies, lock, net]),
        builder: (context, _) => MaterialApp(
          title: 'MORS ACC',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: rootMessengerKey,
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
          home: net.isMobile
              ? MobileRoot(
                  mobile: mobile,
                  companies: companies,
                  net: net,
                  homeBuilder: (context, repo, identity) => HomePage(
                    key: ValueKey('mobile${repo.companyId}'),
                    repo: repo,
                    companies: companies,
                    sync: sync,
                    theme: theme,
                    lock: lock,
                    backups: backups,
                    net: net,
                    mobile: mobile,
                  ),
                )
              : net.isClient
              ? ClientRoot(
                  net: net,
                  prefs: companies.prefs,
                  homeBuilder: (context, session, leave) => _ClientShell(session: session, leave: leave, local: companies, sync: sync, theme: theme, lock: lock, net: net),
                )
              : _Lifecycle(
                  lock: lock,
                  child: lock.isUnlocked(companies.activeId)
                      ? AuthGate(
                          key: ValueKey('auth${companies.activeId}'),
                          auth: auth,
                          companyId: companies.activeId,
                          companyName: companies.activeInfo.name,
                          builder: (identity) => HomePage(
                            key: ValueKey(companies.activeId),
                            repo: companies.active,
                            companies: companies,
                            sync: sync,
                            theme: theme,
                            lock: lock,
                            backups: backups,
                            net: net,
                            auth: auth,
                          ),
                        )
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
  _Dest('orders', 'سفارش و پیش‌دریافت', Icons.assignment_outlined, Icons.assignment),
  _Dest('deliveries', 'رسید تحویل', Icons.local_shipping_outlined, Icons.local_shipping),
  _Dest('products', 'کالاها و انبار', Icons.inventory_2_outlined, Icons.inventory_2),
  _Dest('warehouses', 'انبارها', Icons.warehouse_outlined, Icons.warehouse),
  _Dest('pricing', 'قیمت‌گذاری', Icons.calculate_outlined, Icons.calculate),
  _Dest('parties', 'اشخاص', Icons.people_outline, Icons.people),
  _Dest('cheques', 'چک‌ها', Icons.payments_outlined, Icons.payments),
  _Dest('accounts', 'حساب‌ها', Icons.account_balance_wallet_outlined, Icons.account_balance_wallet),
  _Dest('reports', 'گزارش‌ها', Icons.bar_chart_outlined, Icons.bar_chart),
  _Dest('mobilesync', 'همگام‌سازی با سرور', Icons.cloud_sync_outlined, Icons.cloud_sync),
  _Dest('sync', 'همگام‌سازی', Icons.sync, Icons.sync),
  _Dest('companies', 'شرکت‌ها', Icons.business_outlined, Icons.business),
  _Dest('network', 'شبکه و سرور', Icons.lan_outlined, Icons.lan),
  _Dest('users', 'کاربران و دسترسی', Icons.admin_panel_settings_outlined, Icons.admin_panel_settings),
  _Dest('settings', 'تنظیمات', Icons.settings_outlined, Icons.settings),
];

/// The pages the signed-in user may see (a section needs its `.view` permission;
/// the network pages belong to the system itself, not to a network client).
List<_Dest> _visibleDests(Identity who) => [
      for (final d in _dests)
        if (switch (d.id) {
          'warehouses' => who.canView('products'),
          'mobilesync' => who.mobile,
          'sync' || 'companies' || 'network' => !who.client && who.can(permSettings),
          'users' => who.can(permUsers),
          'settings' => true,
          _ => who.canView(d.id),
        })
          d
    ];

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.repo, required this.companies, required this.sync, required this.theme, required this.lock, required this.backups, required this.net, this.auth, this.session, this.mobile});
  final NetMode net;
  final LocalAuth? auth;

  /// Set in mobile mode.
  final MobileController? mobile;

  /// Set on a network client.
  final RemoteSession? session;
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
      if (AccessScope.of(context).canEdit('invoices')) openInvoiceEditor(context, widget.repo);
      return;
    }
    setState(() => page = id);
  }

  Widget _body() => switch (page) {
        'dashboard' => DashboardPage(repo: widget.repo, onNavigate: _go),
        'transactions' => TransactionsPage(repo: widget.repo),
        'invoices' => InvoicesPage(repo: widget.repo),
        'orders' => OrdersPage(repo: widget.repo),
        'deliveries' => DeliveriesPage(repo: widget.repo),
        'products' => ProductsPage(repo: widget.repo),
        'warehouses' => WarehousesPage(repo: widget.repo),
        'pricing' => CostingPage(repo: widget.repo, embedded: true),
        'parties' => PartiesPage(repo: widget.repo),
        'cheques' => ChequesPage(repo: widget.repo),
        'accounts' => AccountsPage(repo: widget.repo),
        'reports' => ReportsPage(repo: widget.repo),
        'mobilesync' => MobileSyncPage(repo: widget.repo, mobile: widget.mobile!, net: widget.net),
        'sync' => SyncPage(repo: widget.repo, sync: widget.sync, companies: widget.companies),
        'companies' => CompaniesPage(companies: widget.companies, onOpenSync: () => setState(() => page = 'sync')),
        'network' => NetworkPage(net: widget.net, sync: widget.sync, companies: widget.companies, auth: widget.auth!),
        'users' => _usersPage(),
        _ => SettingsPage(repo: widget.repo, theme: widget.theme, lock: widget.lock, backups: widget.backups),
      };

  Widget _usersPage() {
    final who = AccessScope.of(context);
    final auth = widget.auth;
    final repo = widget.repo;
    final local = !who.client && auth != null;
    return UsersPage(
      key: ValueKey('users${who.userId}'),
      admin: who.admin!,
      repo: repo,
      currentUserId: who.userId.isEmpty ? null : who.userId,
      onEnable: !local
          ? null
          : (u, p, f) async {
              await UserStore(repo.store).enable(username: u, password: p, fullName: f);
              await auth.login(repo.companyId, u, p); // the person who switched it on is signed in at once
              auth.usersChanged();
            },
      onDisable: !local
          ? null
          : () async {
              await UserStore(repo.store).disable();
              await auth.logout(repo.companyId);
            },
    );
  }

  Widget _sidebar({bool inDrawer = false}) {
    final scheme = Theme.of(context).colorScheme;
    final who = AccessScope.of(context);
    final dests = _visibleDests(who);
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: PopupMenuButton<String>(
            enabled: !who.client,
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
                    Text(who.mobile ? 'حالت موبایل (آفلاین)' : who.client ? 'متصل به سرور' : (widget.companies.companies.length > 1 ? 'تغییر شرکت' : 'حسابداری'), style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                if (!who.client) const Icon(Icons.unfold_more, size: 20),
              ]),
            ),
          ),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final d in dests)
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
        if (who.signedIn)
          ListTile(
            dense: true,
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(who.display, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(who.roleName, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              tooltip: 'خروج از حساب کاربری',
              icon: const Icon(Icons.logout),
              onPressed: () async {
                if (inDrawer) Navigator.pop(context);
                await who.logout!();
              },
            ),
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
    final who = AccessScope.of(context);
    final visible = _visibleDests(who);
    // A page the user lost access to (their role changed) falls back to the first one allowed.
    final dest = visible.firstWhere((d) => d.id == page, orElse: () => visible.isEmpty ? _dests.last : visible.first);
    if (dest.id != page) page = dest.id;
    final body = KeyedSubtree(key: ValueKey(page), child: _body());
    final s = widget.session;
    final content = s == null
        ? body
        : ListenableBuilder(
            listenable: s,
            builder: (context, _) => Column(children: [
              if (!s.connected)
                Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(children: [
                      const Icon(Icons.wifi_off, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text('ارتباط با سرور قطع است؛ دوباره وصل می‌شود...', style: Theme.of(context).textTheme.bodySmall)),
                    ]),
                  ),
                ),
              Expanded(child: body),
            ]),
          );
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


/// The app of a network client for one signed-in session.
class _ClientShell extends StatefulWidget {
  const _ClientShell({required this.session, required this.leave, required this.local, required this.sync, required this.theme, required this.lock, required this.net});
  final RemoteSession session;
  final Future<void> Function() leave;
  final CompanyManager local;
  final SyncService sync;
  final AppTheme theme;
  final AppLock lock;
  final NetMode net;

  @override
  State<_ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends State<_ClientShell> {
  late final remote = CompanyManager.remote(
    repo: widget.session.repo,
    id: widget.session.companyId,
    name: widget.session.companyName,
    prefs: widget.local.prefs,
    dir: widget.local.dir,
  );
  late final backups = BackupService(remote);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final s = widget.session;
          final identity = Identity(
            access: s.access,
            display: s.display,
            roleName: s.roleName,
            userId: s.userId,
            admin: s.admin,
            logout: widget.leave,
            client: true,
          );
          return AccessScope(
            identity: identity,
            child: HomePage(
              key: ValueKey('client${s.companyId}'),
              repo: s.repo,
              companies: remote,
              sync: widget.sync,
              theme: widget.theme,
              lock: widget.lock,
              backups: backups,
              net: widget.net,
              session: s,
            ),
          );
        },
      );
}
