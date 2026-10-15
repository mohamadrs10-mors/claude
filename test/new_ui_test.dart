import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/data/sessions.dart';
import 'package:simple_accounting/data/user_admin.dart';
import 'package:simple_accounting/data/users.dart';
import 'package:simple_accounting/ui/activity_tab.dart';
import 'package:simple_accounting/ui/settings_extras.dart';
import 'package:simple_accounting/ui/warehouses_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 150));
  }
}

Future<Repo> seed(WidgetTester t) async {
  sqfliteFfiInit();
  late Repo r;
  await t.runAsync(() async {
    final dir = Directory.systemTemp.createTempSync('acc_newui');
    r = Repo(await AppDb.open(path: '${dir.path}/x.db', factory: databaseFactoryFfi));
    await r.init();
    r.companyId = 'c1';
  });
  return r;
}

Widget host(Widget child) => MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: child)));

void main() {
  testWidgets('warehouses page: stock table, moves and the warehouse list', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await seed(tester);
    await tester.runAsync(() async {
      await repo.saveWarehouse(name: 'شعبه شمال');
      await repo.saveProduct(name: 'برنج', openingStock: 10);
    });
    await tester.pumpWidget(host(WarehousesPage(repo: repo)));
    await settle(tester);
    expect(find.text('برنج'), findsOneWidget);
    expect(find.text('شعبه شمال'), findsWidgets); // column header
    await tester.tap(find.text('انتقال و شمارش'));
    await settle(tester);
    expect(find.textContaining('هنوز انتقال یا شمارشی'), findsOneWidget);
    await tester.tap(find.text('انبارها'));
    await settle(tester);
    expect(find.text('انبار اصلی'), findsWidgets);
    expect(find.text('شعبه شمال'), findsOneWidget);
  });

  testWidgets('settings sections: period lock and invoice template change the synced settings', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await seed(tester);
    await tester.pumpWidget(host(ListView(children: [PeriodLockSection(repo: repo), InvoiceTemplateSection(repo: repo)])));
    await settle(tester);
    expect(find.text('هیچ دوره‌ای بسته نیست.'), findsOneWidget);
    await tester.tap(find.text('بستن تا پایان سال قبل'));
    await settle(tester);
    expect(repo.setting('lock_until'), isNotEmpty);
    expect(repo.store.lockUntil, repo.setting('lock_until'));
    expect(find.text('برداشتن قفل'), findsOneWidget);
    await tester.tap(find.text('برداشتن قفل'));
    await settle(tester);
    expect(repo.store.lockUntil, isNull);

    await tester.tap(find.text('مدرن (ردیف‌های راه‌راه)'));
    await settle(tester);
    expect(repo.setting('invoice_template'), 'modern');
    await tester.tap(find.text('ستون ردیف'));
    await settle(tester);
    expect(repo.setting('invoice_rownum'), '0');
  });

  testWidgets('activity report lists what users did and filters it', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await seed(tester);
    late UserAdmin admin;
    late List<UserInfo> users;
    await tester.runAsync(() async {
      final store = UserStore(repo.store);
      await store.enable(username: 'admin', password: 'admin1', fullName: 'مدیر');
      final a = (await store.users()).single;
      repo.store.setAccess(await store.accessOf(a, device: 'سرور'));
      await repo.saveParty(name: 'علی');
      await repo.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
      admin = LocalUserAdmin(store, SessionManager(), 'c1');
      users = await admin.users();
    });
    await tester.pumpWidget(host(ActivityTab(admin: admin, users: users, repo: repo)));
    await settle(tester);
    expect(find.textContaining('شخص: علی'), findsOneWidget);
    expect(find.textContaining('حساب: صندوق'), findsOneWidget);
    // Filter by area.
    await tester.tap(find.byType(DropdownButtonFormField<String?>).at(2));
    await settle(tester);
    await tester.tap(find.text('حساب').last);
    await settle(tester);
    expect(find.textContaining('شخص: علی'), findsNothing);
    expect(find.textContaining('حساب: صندوق'), findsOneWidget);
  });
}
