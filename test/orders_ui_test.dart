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
  multiTests();
  chequeTests();
  percentTests();
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
    await tester.enterText(field2(tester, 'تعداد سفارش'), '100');
    await tester.enterText(field2(tester, 'قیمت واحد'), '1000');
    await tester.pump();
    expect(parseAmount(field(tester, 'مبلغ نقدی دریافت‌شده').text), 50000);
    await tester.enterText(field2(tester, 'درصد پیش‌دریافت'), '30');
    await tester.pump();
    expect(parseAmount(field(tester, 'مبلغ نقدی دریافت‌شده').text), 30000);

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
      await repo.saveOrder(number: 1, date: todayIso(), partyId: party.id, items: [OrderItem('برنج', 100, 1000, productId: prod.id)], percent: 50, advance: 50000, accountId: acc.id);
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

void chequeTests() {
  testWidgets('order form: part of the advance as a cheque; the cash part shrinks and the order page lists the cheque', (tester) async {
    tester.view.physicalSize = const Size(1000, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await seed(tester);
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: OrderEditPage(repo: repo))));
    await settle(tester);
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String?>, 'مشتری'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مشتری').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'کالا'), 'برن');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('موجودی').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'تعداد سفارش'), '100'); // 100 x 1000, 50% -> 50000
    await tester.pump();
    expect(parseAmount(field(tester, 'مبلغ نقدی دریافت‌شده').text), 50000);

    await tester.tap(find.text('افزودن چک'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'مبلغ چک'), '30000');
    await tester.enterText(find.widgetWithText(TextFormField, 'شمارهٔ چک'), '555');
    await tester.pump();
    expect(parseAmount(field(tester, 'مبلغ نقدی دریافت‌شده').text), 20000);

    await tester.tap(find.text('ذخیره سفارش'));
    await settle(tester);
    final o = (await tester.runAsync(repo.orders))!.single;
    expect((o.cash, o.chequeAmount, o.advance), (20000, 30000, 50000));
    final chq = (await tester.runAsync(repo.cheques))!.single;
    expect((chq.number, chq.orderId, chq.amount), ('555', o.id, 30000));
    expect((await tester.runAsync(repo.accounts))!.single.balance, 20000);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: OrderViewPage(repo: repo, orderId: o.id))));
    await settle(tester);
    expect(find.text('چک‌های پیش‌دریافت'), findsOneWidget);
    expect(find.text('ثبت چک پیش‌دریافت'), findsOneWidget);
    expect(find.text('در انتظار'), findsOneWidget);
  });
}

void multiTests() {
  testWidgets('order with two products via the form; its invoice is pre-filled with both and takes the advance', (tester) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await seed(tester);
    await tester.runAsync(() => repo.saveProduct(name: 'روغن', unit: 'گالن', salePrice: 2000, buyPrice: 1500, openingStock: 100, minStock: 0));
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: OrderEditPage(repo: repo))));
    await settle(tester);

    await tester.tap(find.widgetWithText(DropdownButtonFormField<String?>, 'مشتری'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مشتری').last);
    await tester.pumpAndSettle();

    Future<void> pickProduct(int index, String typed) async {
      await tester.enterText(find.widgetWithText(TextFormField, 'کالا').at(index), typed);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('موجودی').first);
      await tester.pumpAndSettle();
    }

    await pickProduct(0, 'برن');
    await tester.enterText(find.widgetWithText(TextFormField, 'تعداد سفارش').at(0), '100');
    await tester.tap(find.text('افزودن کالا'));
    await tester.pumpAndSettle();
    await pickProduct(1, 'روغ');
    await tester.enterText(find.widgetWithText(TextFormField, 'تعداد سفارش').at(1), '50');
    await tester.pump();
    expect(parseAmount(field(tester, 'مبلغ نقدی دریافت‌شده').text), 100000); // 50% of 100x1000 + 50x2000

    await tester.tap(find.text('ذخیره سفارش'));
    await settle(tester);
    final o = (await tester.runAsync(repo.orders))!.single;
    expect(o.items.map((i) => (i.title, i.qty, i.unitPrice)).toList(), [('برنج', 100.0, 1000), ('روغن', 50.0, 2000)]);
    expect((o.total, o.advance), (200000, 100000));

    final party = (await tester.runAsync(repo.parties))!.single;
    await tester.pumpWidget(const SizedBox()); // fully leave the order form
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: InvoiceEditPage(repo: repo, initialPartyId: party.id, initialOrderId: o.id))));
    await settle(tester);
    expect(find.widgetWithText(TextFormField, 'کالا / شرح'), findsNWidgets(2));
    await tester.tap(find.text('ذخیره فاکتور'));
    await settle(tester);
    await settle(tester);
    final inv = (await tester.runAsync(repo.invoices))!.single;
    expect((inv.total, inv.prepaid, inv.remaining), (200000, 100000, 100000));
  });
}

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
      await repo.saveOrder(number: 1, date: todayIso(), partyId: party.id, items: [OrderItem('برنج', 100, 1000, productId: prod.id)], percent: 50, advance: 50000, accountId: acc.id);
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

void percentTests() {
  testWidgets('order form: typing the amount sets the percent from cash + cheques; typing the percent sets the amount again', (tester) async {
    tester.view.physicalSize = const Size(1000, 3600);
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
    await tester.enterText(field2(tester, 'تعداد سفارش'), '100');
    await tester.enterText(field2(tester, 'قیمت واحد'), '1000'); // total 100000
    await tester.pump();
    expect(parseAmount(field(tester, 'مبلغ نقدی دریافت‌شده').text), 50000); // default 50 %

    // The customer pays 70,000 in cash: the percent follows.
    await tester.enterText(field2(tester, 'مبلغ نقدی دریافت‌شده'), '70000');
    await tester.pump();
    expect(parseNum(field(tester, 'درصد پیش‌دریافت').text), 70);
    // A cheque of 10,000 on top: 80 % of the order is received.
    await tester.tap(find.text('افزودن چک'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'مبلغ چک'), '10000');
    await tester.pump();
    expect(parseNum(field(tester, 'درصد پیش‌دریافت').text), 80);
    expect(parseAmount(field(tester, 'مبلغ نقدی دریافت‌شده').text), 70000); // the cash stays as typed
    expect(find.textContaining('۸۰٪ از جمع سفارش'), findsOneWidget);
    // A fraction is kept to two decimals.
    await tester.enterText(find.widgetWithText(TextFormField, 'مبلغ چک'), '3333');
    await tester.pump();
    expect(parseNum(field(tester, 'درصد پیش‌دریافت').text), 73.33);
    // Typing the percent again makes the cash follow it (minus the cheque).
    await tester.enterText(field2(tester, 'درصد پیش‌دریافت'), '60');
    await tester.pump();
    expect(parseAmount(field(tester, 'مبلغ نقدی دریافت‌شده').text), 60000 - 3333);
  });

  testWidgets('editing a saved order: raising the cash amount raises the percent, and the order keeps it', (tester) async {
    tester.view.physicalSize = const Size(1000, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await seed(tester);
    late String oid;
    await tester.runAsync(() async {
      final party = (await repo.parties()).single;
      final acc = (await repo.accounts()).single;
      oid = await repo.saveOrder(number: 1, date: todayIso(), partyId: party.id, percent: 50, advance: 50000, accountId: acc.id, items: [OrderItem('برنج', 100, 1000)]);
    });
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: OrderEditPage(repo: repo, orderId: oid))));
    await settle(tester);
    expect(parseNum(field(tester, 'درصد پیش‌دریافت').text), 50);
    await tester.enterText(field2(tester, 'مبلغ نقدی دریافت‌شده'), '80000');
    await tester.pump();
    expect(parseNum(field(tester, 'درصد پیش‌دریافت').text), 80);
    await tester.tap(find.text('ذخیره سفارش'));
    await settle(tester);
    final o = (await tester.runAsync(repo.orders))!.single;
    expect((o.percent, o.cash, o.advance), (80.0, 80000, 80000));
  });
}
