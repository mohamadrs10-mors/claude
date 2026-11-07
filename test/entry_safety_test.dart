import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/ui/cheques_page.dart';
import 'package:simple_accounting/ui/invoices_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 150));
  }
}

Future<Repo> newRepo(WidgetTester tester) async {
  sqfliteFfiInit();
  late Repo repo;
  await tester.runAsync(() async {
    final dir = Directory.systemTemp.createTempSync('acc_safe');
    repo = Repo(await AppDb.open(path: '${dir.path}/x.db', factory: databaseFactoryFfi));
    await repo.init();
  });
  return repo;
}

void main() {
  testWidgets('a cheque being typed is not thrown away by tapping outside the dialog', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await newRepo(tester);
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => editCheque(c, repo), child: const Text('باز'))))))); 
    await tester.tap(find.text('باز'));
    await settle(tester);
    expect(find.text('چک جدید'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'مبلغ'), '5000');
    await tester.tapAt(const Offset(5, 5)); // outside the dialog
    await settle(tester);
    expect(find.text('چک جدید'), findsOneWidget, reason: 'the dialog must stay open');
    await tester.tap(find.text('ذخیره'));
    await settle(tester);
    expect((await tester.runAsync(repo.cheques))!.single.amount, 5000);
  });

  testWidgets('leaving a half-entered invoice with the back button asks first and can stay', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await newRepo(tester);
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => InvoiceEditPage(repo: repo))), child: const Text('فاکتور')))))));
    await tester.tap(find.text('فاکتور'));
    await settle(tester);
    expect(find.text('فاکتور جدید'), findsOneWidget);
    // untouched: back leaves without a question
    await tester.pageBack();
    await settle(tester);
    expect(find.text('فاکتور جدید'), findsNothing);
    // typed something: back asks, "انصراف" stays, "بله" leaves
    await tester.tap(find.text('فاکتور'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'توضیحات'), 'یادداشت تستی');
    await tester.pageBack();
    await settle(tester);
    expect(find.textContaining('بدون ذخیره'), findsOneWidget);
    await tester.tap(find.text('انصراف'));
    await settle(tester);
    expect(find.text('فاکتور جدید'), findsOneWidget);
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.text('بله'));
    await settle(tester);
    expect(find.text('فاکتور جدید'), findsNothing);
  });
}
