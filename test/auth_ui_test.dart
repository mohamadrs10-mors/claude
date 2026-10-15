import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/access.dart';
import 'package:simple_accounting/data/app_lock.dart';
import 'package:simple_accounting/data/backup_service.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/net_mode.dart';
import 'package:simple_accounting/data/remote_session.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/data/sessions.dart';
import 'package:simple_accounting/data/user_admin.dart';
import 'package:simple_accounting/data/users.dart';
import 'package:simple_accounting/main.dart';
import 'package:simple_accounting/sync/sync_service.dart';
import 'package:simple_accounting/ui/app_theme.dart';
import 'package:simple_accounting/ui/auth.dart';
import 'package:simple_accounting/ui/client_root.dart';
import 'package:simple_accounting/ui/users_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

class Env {
  Env(this.repo, this.companies, this.sync, this.auth, this.prefs);
  final Repo repo;
  final CompanyManager companies;
  final SyncService sync;
  final LocalAuth auth;
  final DevicePrefs prefs;
}

Future<Env> env(WidgetTester t, {bool withUsers = true}) async {
  sqfliteFfiInit();
  late Env e;
  await t.runAsync(() async {
    final dir = Directory.systemTemp.createTempSync('acc_authui');
    final repo = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
    repo.companyId = 'c1';
    await repo.init();
    final prefs = DevicePrefs.memory();
    final companies = CompanyManager.forRepos({'c1': repo}, prefs);
    final sync = SyncService(companies);
    if (withUsers) {
      final us = UserStore(repo.store);
      await us.enable(username: 'admin', password: 'admin1', fullName: 'مدیر سیستم');
      await us.saveUser(username: 'sara', password: 'sara12', roleId: 'seller', fullName: 'سارا فروشنده');
      await us.saveUser(username: 'vik', password: 'vik123', roleId: 'viewer', fullName: 'ویکتور');
    }
    e = Env(repo, companies, sync, LocalAuth(companies, sync), prefs);
  });
  return e;
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await t.pump();
  }
}

Widget app(Widget home) => MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: home));

Future<Widget> homeFor(Env e) async {
  final theme = AppTheme(e.prefs);
  return HomePage(
    repo: e.repo,
    companies: e.companies,
    sync: e.sync,
    theme: theme,
    lock: AppLock(e.prefs),
    backups: BackupService(e.companies),
    net: NetMode(e.prefs),
    auth: e.auth,
  );
}

void main() {
  testWidgets('with users on, the company asks for a sign-in; wrong password is refused; the right one opens the app; sign-out asks again', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = await env(tester);
    await tester.pumpWidget(app(AuthGate(auth: e.auth, companyId: 'c1', companyName: 'شرکت تست', builder: (id) => Scaffold(body: Text('داخل برنامه: ${id.display} / ${id.roleName}')))));
    await settle(tester);
    expect(find.text('نام کاربری'), findsOneWidget);
    expect(find.textContaining('داخل برنامه'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'نام کاربری'), 'sara');
    await tester.enterText(find.widgetWithText(TextField, 'رمز عبور'), 'wrong');
    await tester.tap(find.widgetWithText(FilledButton, 'ورود'));
    await settle(tester);
    expect(find.text('نام کاربری یا رمز عبور اشتباه است.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'رمز عبور'), 'sara12');
    await tester.tap(find.widgetWithText(FilledButton, 'ورود'));
    await settle(tester);
    expect(find.text('داخل برنامه: سارا فروشنده / فروشنده / صندوقدار'), findsOneWidget);
    // The database is now limited to what a seller may do.
    await tester.runAsync(() async {
      await e.repo.saveParty(name: 'مجاز');
      await expectLater(e.repo.saveAccount(name: 'x', kind: 'cash', opening: 0), throwsA(isA<AccessDenied>()));
    });
    expect(e.sync.sessions.active('c1').single.username, 'sara');

    await tester.runAsync(() => e.auth.logout('c1'));
    await settle(tester);
    expect(find.text('نام کاربری'), findsOneWidget);
    expect(e.sync.sessions.active('c1'), isEmpty);
    await tester.runAsync(() => expectLater(e.repo.saveParty(name: 'بدون ورود'), throwsA(isA<AccessDenied>())));
  });

  testWidgets('without users the company opens directly and nothing is restricted', (tester) async {
    final e = await env(tester, withUsers: false);
    await tester.pumpWidget(app(AuthGate(auth: e.auth, companyId: 'c1', companyName: 'شرکت', builder: (id) => Scaffold(body: Text(id.signedIn ? 'login' : 'open')))));
    await settle(tester);
    expect(find.text('open'), findsOneWidget);
    await tester.runAsync(() => e.repo.saveAccount(name: 'ok', kind: 'cash', opening: 0));
  });

  testWidgets('a user already signed in on a network client cannot sign in here too', (tester) async {
    final e = await env(tester);
    late NetSession other;
    await tester.runAsync(() async {
      final u = (await UserStore(e.repo.store).users()).firstWhere((x) => x.username == 'sara');
      other = e.sync.sessions.login(companyId: 'c1', userId: u.id, username: 'sara', display: 'سارا', roleName: 'x', access: Access({}), deviceId: 'other-pc', deviceName: 'صندوق ۲');
    });
    expect(other.deviceName, 'صندوق ۲');
    await tester.pumpWidget(app(AuthGate(auth: e.auth, companyId: 'c1', companyName: 'شرکت', builder: (id) => const Scaffold(body: Text('داخل')))));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'نام کاربری'), 'sara');
    await tester.enterText(find.widgetWithText(TextField, 'رمز عبور'), 'sara12');
    await tester.tap(find.widgetWithText(FilledButton, 'ورود'));
    await settle(tester);
    expect(find.textContaining('صندوق ۲'), findsOneWidget);
    expect(find.text('داخل'), findsNothing);
  });

  testWidgets('menu follows the role: a seller does not see pricing, reports or user management; a viewer gets no add buttons', (tester) async {
    tester.view.physicalSize = const Size(1300, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = await env(tester);
    await tester.runAsync(() => e.auth.login('c1', 'sara', 'sara12'));
    final home = await homeFor(e);
    final seller = await tester.runAsync(() => e.auth.identityFor('c1'));
    await tester.pumpWidget(app(AccessScope(identity: seller!, child: home)));
    await settle(tester);
    expect(find.text('فاکتورها'), findsWidgets);
    expect(find.text('قیمت‌گذاری'), findsNothing);
    expect(find.text('گزارش‌ها'), findsNothing);
    expect(find.text('کاربران و دسترسی'), findsNothing);
    expect(find.text('شبکه و سرور'), findsNothing);
    expect(find.text('سارا فروشنده'), findsOneWidget); // who is signed in
    await tester.tap(find.text('فاکتورها').first);
    await settle(tester);
    expect(find.text('فاکتور جدید'), findsOneWidget);

    await tester.runAsync(() => e.auth.logout('c1'));
    await tester.runAsync(() => e.auth.login('c1', 'vik', 'vik123'));
    final viewer = await tester.runAsync(() => e.auth.identityFor('c1'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(AccessScope(identity: viewer!, child: await homeFor(e))));
    await settle(tester);
    await tester.tap(find.text('فاکتورها').first);
    await settle(tester);
    expect(find.text('فاکتور جدید'), findsNothing);
    expect(find.text('گزارش‌ها'), findsWidgets);

    await tester.runAsync(() => e.auth.logout('c1'));
    await tester.runAsync(() => e.auth.login('c1', 'admin', 'admin1'));
    final admin = await tester.runAsync(() => e.auth.identityFor('c1'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(AccessScope(identity: admin!, child: await homeFor(e))));
    await settle(tester);
    expect(find.text('کاربران و دسترسی'), findsOneWidget);
    expect(find.text('شبکه و سرور'), findsOneWidget);
    expect(find.text('قیمت‌گذاری'), findsOneWidget);
    await tester.runAsync(() => e.auth.logout('c1'));
  });

  testWidgets('users page: switch users on, add a user with a role, edit a role, see sessions', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = await env(tester, withUsers: false);
    final admin = LocalUserAdmin(UserStore(e.repo.store), e.sync.sessions, 'c1');
    await tester.pumpWidget(app(Scaffold(
      body: UsersPage(
        admin: admin,
        onEnable: (u, p, f) async {
          await UserStore(e.repo.store).enable(username: u, password: p, fullName: f);
        },
      ),
    )));
    await settle(tester);
    expect(find.text('فعال‌سازی کاربران'), findsWidgets);
    await tester.enterText(find.widgetWithText(TextField, 'نام کاربری مدیر (انگلیسی)'), 'boss');
    await tester.enterText(find.widgetWithText(TextField, 'رمز عبور (حداقل ۴ نویسه)'), 'bosspw');
    await tester.tap(find.text('فعال‌سازی').last);
    await settle(tester);
    expect(find.text('boss • مدیر کل'), findsOneWidget);

    await tester.tap(find.text('کاربر جدید'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'نام کاربری (انگلیسی)'), 'newbie');
    await tester.enterText(find.widgetWithText(TextField, 'نام کامل'), 'تازه‌وارد');
    await tester.enterText(find.widgetWithText(TextField, 'رمز عبور'), 'abcd12');
    await tester.tap(find.text('ذخیره'));
    await settle(tester);
    expect(find.text('newbie • فروشنده / صندوقدار'), findsOneWidget);
    final created = (await tester.runAsync(() => UserStore(e.repo.store).verify('newbie', 'abcd12')))!;
    expect(created.fullName, 'تازه‌وارد');

    // A role with just cheques.
    await tester.tap(find.text('نقش‌ها و دسترسی'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نقش جدید'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'نام نقش'), 'چک‌دار');
    await tester.tap(find.byType(Checkbox).at(18)); // some permission box
    await tester.tap(find.text('ذخیره'));
    await settle(tester);
    expect(find.text('چک‌دار'), findsOneWidget);
    expect((await tester.runAsync(() => UserStore(e.repo.store).roles()))!.any((r) => r.name == 'چک‌دار'), isTrue);

    await tester.tap(find.text('نشست‌های فعال'));
    await tester.pumpAndSettle();
    expect(find.text('الان کسی وارد نیست.'), findsOneWidget);
  });

  testWidgets('client connect screen: finds the server companies, signs in, reports the session', (tester) async {
    HttpOverrides.global = null; // the test binding blocks real HTTP by default
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = await env(tester);
    late int port;
    await tester.runAsync(() async {
      await e.prefs.set('net_mode', 'server');
      await e.sync.setPairCode('4321');
      await e.sync.startServer(port: 0);
      port = e.sync.port!;
    });
    addTearDown(() async => tester.runAsync(e.sync.stopServer));
    final clientPrefs = DevicePrefs.memory();
    final net = NetMode(clientPrefs);
    await tester.runAsync(() => net.remember(host: '127.0.0.1', port: port, code: '4321'));
    RemoteSession? got;
    await tester.pumpWidget(app(ConnectScreen(net: net, prefs: clientPrefs, onConnected: (s) => got = s)));
    await settle(tester); // the remembered address is tried at once
    expect(find.text('c1'), findsOneWidget); // company list
    await tester.enterText(find.widgetWithText(TextField, 'نام کاربری'), 'vik');
    await tester.enterText(find.widgetWithText(TextField, 'رمز عبور'), 'bad');
    await tester.tap(find.widgetWithText(FilledButton, 'ورود'));
    await settle(tester);
    expect(find.text('نام کاربری یا رمز عبور اشتباه است.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'رمز عبور'), 'vik123');
    await tester.tap(find.widgetWithText(FilledButton, 'ورود'));
    await settle(tester);
    await settle(tester);
    await settle(tester);
    expect(got, isNotNull);
    expect(got!.username, 'vik');
    expect(net.lastUser, 'vik'); // remembered for next time
    await tester.runAsync(got!.logout);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30)); // let the request time-outs run out
  });
}
