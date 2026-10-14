import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/print/report_builders.dart';
import 'package:simple_accounting/ui/party_ledger_tab.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_pl');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

/// A customer with sales, a return, receipts, an advance used on an invoice and a pending cheque.
Future<(Repo, Party)> scenario() async {
  final r = await newRepo();
  await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
  final acc = (await r.accounts()).single;
  await r.saveParty(name: 'مشتری', phone: '0912', opening: 5000);
  await r.saveParty(name: 'دیگری');
  final p = (await r.parties()).firstWhere((x) => x.name == 'مشتری');
  final other = (await r.parties()).firstWhere((x) => x.name == 'دیگری');
  await r.saveProduct(name: 'برنج', openingStock: 1000);
  final prod = (await r.products()).single;
  await r.saveInvoice(number: 1, kind: 'sale', date: '2025-01-10', partyId: p.id, discount: 0, note: 'اولین فروش',
      items: [InvoiceItem('برنج', 10, 1000, productId: prod.id), InvoiceItem('روغن', 2, 500), InvoiceItem('نخ', 1, 100), InvoiceItem('سوزن', 1, 50)]);
  await r.saveTx(date: '2025-01-15', kind: 'receipt', amount: 4000, accountId: acc.id, partyId: p.id, description: 'علی‌الحساب');
  await r.saveInvoice(number: 2, kind: 'sale_return', date: '2025-02-01', partyId: p.id, discount: 0, note: '', items: [InvoiceItem('برنج', 1, 1000, productId: prod.id)]);
  final oid = await r.saveOrder(
      number: 1, date: '2025-02-02', partyId: p.id, percent: 50, advance: 3000, accountId: acc.id, items: [OrderItem('برنج', 10, 1000, productId: prod.id)]);
  await r.saveInvoice(number: 3, kind: 'sale', date: '2025-02-10', partyId: p.id, discount: 0, note: '', orderId: oid,
      items: [InvoiceItem('برنج', 6, 1000, productId: prod.id)]); // 6000, 3000 from the advance
  await r.saveTx(date: '2025-02-20', kind: 'payment', amount: 700, accountId: acc.id, partyId: p.id, description: 'برگشت وجه');
  await r.saveInvoice(number: 9, kind: 'sale', date: '2025-02-25', partyId: other.id, discount: 0, note: '', items: [InvoiceItem('x', 1, 99)]);
  await r.saveCheque(kind: 'received', number: '77', bank: 'ملی', amount: 1234, dueDate: '2025-04-01', partyId: p.id);
  return (r, p);
}

void main() {
  test('party ledger lists invoices and money of that party only, balance equals the party balance and the statement', () async {
    final (r, p) = await scenario();
    final l = await r.partyLedger(p.id);
    // opening 5000 + 10000+1000+100+50... first invoice: 10000+1000+100+50 = 11150
    expect(l.opening, 5000);
    expect(l.rows.map((x) => x.type).toList(), [
      'فاکتور فروش', 'دریافت', 'برگشت از فروش', 'فاکتور فروش', 'کسر از پیش‌دریافت', 'پرداخت',
    ]);
    expect(l.rows.map((x) => x.number).toList(), ['۱', '', '۲', '۳', '۳', '']);
    expect(l.rows.first.description, contains('برنج × ۱۰'));
    expect(l.rows.first.description, contains('قلم دیگر')); // 4 lines: 3 shown + 1 more
    expect(l.rows.first.description, contains('اولین فروش'));
    expect(l.rows[1].description, contains('صندوق'));
    expect(l.rows[1].description, contains('علی‌الحساب'));
    // 5000 +11150 -4000 -1000 +6000 -3000 +700
    expect(l.closing, 5000 + 11150 - 4000 - 1000 + 6000 - 3000 + 700);
    expect(l.rows.last.balance, l.closing);
    expect((await r.parties()).firstWhere((x) => x.id == p.id).balance, l.closing);
    final st = await r.statement(p.id);
    expect(st.closing, l.closing);
    expect(st.rows.length, l.rows.length);
    expect((l.totalDebit, l.totalCredit), (st.totalDebit, st.totalCredit));
    // The other party's invoice (99) is not here; the cheque waits.
    expect(l.rows.any((x) => x.description.contains('x ×')), isFalse);
    expect(l.pendingCheques.single.amount, 1234);
    expect(l.invoiceCount, 3);
  });

  test('a period carries the earlier movements into the opening balance', () async {
    final (r, p) = await scenario();
    final all = await r.partyLedger(p.id);
    final feb = await r.partyLedger(p.id, from: '2025-02-01', toExclusive: '2025-03-01');
    expect(feb.rows.length, 4);
    expect(feb.opening, 5000 + 11150 - 4000);
    expect(feb.closing, all.closing);
    final jan = await r.partyLedger(p.id, from: '2025-01-01', toExclusive: '2025-02-01');
    expect(jan.rows.length, 2);
    expect(jan.closing, 5000 + 11150 - 4000);
    expect((await r.partyLedger(p.id, from: '2026-01-01', toExclusive: '2026-02-01')).rows, isEmpty);
  });

  test('a closed order with nothing left shows no credit line; pro-formas never appear; the printed doc is well formed', () async {
    final (r, p) = await scenario();
    final oid = (await r.orders()).single.id;
    await r.setOrderOpen(oid, false); // 3000 advance - 3000 used = 0 released; make a bigger leftover
    await r.saveProduct(name: 'کالا');
    await r.saveInvoice(number: 20, kind: 'proforma', date: '2025-03-01', partyId: p.id, discount: 0, note: '', items: [InvoiceItem('x', 1, 1)]);
    final l = await r.partyLedger(p.id);
    expect(l.rows.any((x) => x.type == 'اعتبار پیش‌دریافت'), isFalse); // nothing was left over
    expect(l.rows.any((x) => x.number == '۲۰'), isFalse); // a pro-forma is not in the books

    final doc = partyLedgerDoc(p, l, 'کل دوران');
    final t = doc.tables.first;
    expect(t.rows.every((row) => row.length == t.headers.length), isTrue);
    expect(t.totals!.length, t.headers.length);
    expect(doc.tables.length, 2); // movements + pending cheques
    expect(doc.tables[1].rows.every((row) => row.length == doc.tables[1].headers.length), isTrue);
    expect(doc.title, contains('مشتری'));
  });

  testWidgets('reports tab: shows the party documents, switching party and period redraws', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sqfliteFfiInit();
    late Repo repo;
    await tester.runAsync(() async => repo = (await scenario()).$1);
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
        await tester.pump();
      }
    }

    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: PartyLedgerTab(repo: repo)))));
    await settle();
    // First party by name is «دیگری» (one invoice of 99).
    expect(find.text('فاکتور فروش ۹'), findsOneWidget);

    // Choose «مشتری» in the searchable menu.
    await tester.tap(find.byType(DropdownMenu<String>));
    await settle();
    await tester.tap(find.text('مشتری').last);
    await settle();
    expect(find.text('فاکتور فروش ۱'), findsOneWidget);
    expect(find.text('برگشت از فروش ۲'), findsOneWidget);
    expect(find.text('کسر از پیش‌دریافت ۳'), findsOneWidget);
    expect(find.text('فاکتور فروش ۹'), findsNothing);
    expect(find.textContaining('چک‌های در انتظار'), findsOneWidget);

    // Period: a month with nothing.
    await tester.tap(find.text('ماه'));
    await settle();
    expect(find.textContaining('تراکنشی بین ما'), findsOneWidget);
  });
}
