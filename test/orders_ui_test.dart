import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/ui/invoices_page.dart';
import 'package:simple_accounting/ui/orders_page.dart';
import 'package:simple_accounting/util/format.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await t.pump();
  }
}

Future<Repo> seed(WidgetTester t) async {
  sqfliteFfiInit();
  late Repo r;
  await t.runAsync(() async {
    final dir = Directory.systemTemp.createTempSync('acc_ordui');
    r = Repo(await AppDb.open(path: '${dir.path}/x.db', factory: databaseFactoryFfi));
    await r.init();
    await r.saveParty(name: 'مشتری');
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    await r.saveProduct(name: 'برنج', unit: 'کیسه', salePrice: 1000, buyPrice: 700, openingStock: 500, minStock: 0);
  });
  return r;
}

TextEditingController field(WidgetTester t, String label) => t.widget<TextFormField>(find.widgetWithText(TextFormField, label)).controller!;

void main() {
  flowTests();
  testWidgets('order form: advance follows qty x price x percent, saves into the cash box without crediting the customer', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await seed(tester);
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: OrderEditPage(repo: repo))));
    await settle(tester);

    await tester.tap(find.widgetWithText(DropdownButtonFormField<String?>, 'مشتری'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مشتری').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'کالا'), 'برنج');
    await tester.enterText(field2(tester, 'کل تعداد سفارش'), '100');
    await tester.enterText(field2(tester, 'قیمت واحد'), '1000');
    await tester.pump();
    expect(parseAmount(field(tester, 'مبلغ دریافت‌شده').text), 50000);
    await tester.enterText(field2(tester, 'درصد پیش‌دریافت'), '30');
    await tester.pump();
    expect(parseAmount(field(tester, 'مبلغ دریافت‌شده').text), 30000);

    await tester.tap(find.text('ذخیره سفارش'));
    await settle(tester);
    final o = (await tester.runAsync(repo.orders))!.single;
    expect((o.percent, o.advance, o.total), (30.0, 30000, 100000));
    expect((await tester.runAsync(repo.accounts))!.single.balance, 30000);
    expect((await tester.runAsync(repo.parties))!.single.balance, 0);
  });

  testWidgets('invoice for an order: line is pre-filled and the advance is deducted', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await seed(tester);
    late Party party;
    await tester.runAsync(() async {
      party = (await repo.parties()).single;
      final acc = (await repo.accounts()).single;
      final prod = (await repo.products()).single;
      await repo.saveOrder(number: 1, date: todayIso(), partyId: party.id, productId: prod.id, title: 'برنج', qty: 100, unitPrice: 1000, percent: 50, advance: 50000, accountId: acc.id);
    });
    final order = (await tester.runAsync(repo.orders))!.single;
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: InvoiceEditPage(repo: repo, initialPartyId: party.id, initialOrderId: order.id))));
    await settle(tester);

    expect(find.text('مانده بدهی مشتری'), findsOneWidget);
    expect(find.textContaining('کسر از پیش‌دریافت'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'تعداد (کیسه)'), '40');
    await tester.pump();
    await tester.tap(find.text('ذخیره فاکتور'));
    await settle(tester);
    final inv = (await tester.runAsync(repo.invoices))!.single;
    expect((inv.total, inv.prepaid, inv.remaining, inv.orderId), (40000, 20000, 20000, order.id));
    expect((await tester.runAsync(repo.parties))!.single.balance, 20000);
  });
}

Finder field2(WidgetTester t, String label) => find.widgetWithText(TextFormField, label);

void flowTests() {
  testWidgets('new invoice from the invoices page: choosing the customer offers the order and the advance is deducted', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await seed(tester);
    await tester.runAsync(() async {
      final party = (await repo.parties()).single;
      final acc = (await repo.accounts()).single;
      final prod = (await repo.products()).single;
      await repo.saveOrder(number: 1, date: todayIso(), partyId: party.id, productId: prod.id, title: 'برنج', qty: 100, unitPrice: 1000, percent: 50, advance: 50000, accountId: acc.id);
    });
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: InvoiceEditPage(repo: repo))));
    await settle(tester);
    expect(find.textContaining('سفارش دارای پیش‌دریافت'), findsNothing); // no customer chosen yet

    await tester.tap(find.widgetWithText(DropdownButtonFormField<String?>, 'مشتری'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مشتری').last);
    await settle(tester);
    expect(find.textContaining('سفارش دارای پیش‌دریافت'), findsOneWidget);

    // The only open order is chosen automatically, no manual pick needed.
    expect(find.text('مانده بدهی مشتری'), findsOneWidget);
    // Pick the product the way a user does: type and choose from the suggestions.
    await tester.enterText(find.widgetWithText(TextFormField, 'کالا / شرح'), 'برن');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('موجودی').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'تعداد (کیسه)'), '40');
    await tester.pump();
    await tester.tap(find.text('ذخیره فاکتور'));
    await settle(tester);
    final inv = (await tester.runAsync(repo.invoices))!.single;
    expect((inv.total, inv.prepaid, inv.remaining), (40000, 20000, 20000));
    expect((await tester.runAsync(repo.parties))!.single.balance, 20000);
  });
}
