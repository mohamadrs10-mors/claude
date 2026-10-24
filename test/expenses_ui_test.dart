import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/expenses_repo.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/ui/expenses_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  testWidgets('expenses: register rent with a suggested category, see it grouped, and register a standing expense', (tester) async {
    tester.view.physicalSize = const Size(1100, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sqfliteFfiInit();
    late Repo repo;
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('acc_expui');
      repo = Repo(await AppDb.open(path: '${dir.path}/x.db', factory: databaseFactoryFfi));
      await repo.init();
      await repo.saveAccount(name: 'صندوق', kind: 'cash', opening: 20000000);
    });
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: ExpensesPage(repo: repo)))));
    await settle(tester);
    expect(find.textContaining('در این بازه هزینه‌ای ثبت نشده'), findsOneWidget);

    // Register rent: pick the suggested category "اجاره" (it does not exist yet).
    await tester.tap(find.text('ثبت هزینه'));
    await settle(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await settle(tester);
    await tester.tap(find.text('اجاره (پیشنهادی)').last);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'مبلغ'), '4000000');
    await tester.enterText(find.widgetWithText(TextField, 'شرح (پرداخت به چه کسی / برای چه)'), 'اجارهٔ مغازه');
    await tester.tap(find.text('ثبت').last);
    await settle(tester);

    final list = (await tester.runAsync(repo.expenses))!;
    expect(list.single.amount, 4000000);
    expect(list.single.description, 'اجارهٔ مغازه');
    expect((await tester.runAsync(repo.categories))!.any((c) => c.name == 'اجاره'), isTrue);
    expect((await tester.runAsync(repo.accounts))!.single.balance, 16000000);
    expect(find.text('اجارهٔ مغازه'), findsOneWidget);
    expect(find.textContaining('اجاره (۱)'), findsOneWidget); // the category summary

    // A standing expense is defined and registered for this month with one tap.
    await tester.tap(find.text('هزینه‌های ثابت ماهانه'));
    await settle(tester);
    expect(find.textContaining('هنوز هزینهٔ ثابتی تعریف نشده'), findsOneWidget);
    await tester.tap(find.text('هزینهٔ ثابت جدید'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'عنوان (مثلاً اجارهٔ مغازه)'), 'اینترنت');
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await settle(tester);
    await tester.tap(find.text('تلفن و اینترنت (پیشنهادی)').last);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'مبلغ هر ماه'), '600000');
    await tester.tap(find.text('ذخیره'));
    await settle(tester);
    expect(find.text('اینترنت'), findsOneWidget);
    expect(find.text('ثبت‌نشده'), findsOneWidget);
    await tester.tap(find.byTooltip('ثبت این ماه'));
    await settle(tester);
    expect(find.text('این ماه ثبت شد'), findsOneWidget);
    expect((await tester.runAsync(repo.expenses))!.length, 2);
    expect((await tester.runAsync(repo.accounts))!.single.balance, 15400000);
  });
}
