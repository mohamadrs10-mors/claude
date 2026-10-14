import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_ord');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

Future<(Repo, Party, Account, Product)> setup() async {
  final r = await newRepo();
  await r.saveParty(name: 'مشتری');
  await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
  await r.saveProduct(name: 'برنج', unit: 'کیسه', salePrice: 1000, buyPrice: 700, openingStock: 1000, minStock: 0);
  return (r, (await r.parties()).single, (await r.accounts()).single, (await r.products()).single);
}

Future<String> sale(Repo r, Party p, Product prod, int number, double qty, {String? orderId, int discount = 0, int tax = 0, String? id}) => r.saveInvoice(
    id: id, number: number, kind: 'sale', date: '2025-03-0$number', partyId: p.id, discount: discount, taxPercent: tax, note: '',
    items: [InvoiceItem('برنج', qty, 1000, productId: prod.id)], orderId: orderId);

void main() {
  test('advance does not make the customer a creditor; each invoice takes the agreed percent as paid', () async {
    final (r, p, acc, prod) = await setup();
    // Order: 100 bags x 1000 = 100000, 50% advance = 50000 received in cash.
    final oid = await r.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, productId: prod.id, title: 'برنج', qty: 100, unitPrice: 1000,
        percent: 50, advance: 50000, accountId: acc.id);
    expect((await r.accounts()).single.balance, 50000); // the money is in the cash box
    expect((await r.parties()).single.balance, 0); // ...but the customer is not credited
    var o = (await r.orders()).single;
    expect(o.total, 100000);
    expect(o.available, 50000);

    // First invoice: 40 bags = 40000 -> 20000 counts as paid, 20000 is owed.
    final i1 = await sale(r, p, prod, 1, 40, orderId: oid);
    var inv = (await r.invoices()).firstWhere((i) => i.id == i1);
    expect(inv.total, 40000);
    expect(inv.prepaid, 20000);
    expect(inv.remaining, 20000);
    expect((await r.parties()).single.balance, 20000);

    // Second invoice: 60 bags = 60000 -> 30000 from the advance, 30000 owed.
    await sale(r, p, prod, 2, 60, orderId: oid);
    expect((await r.parties()).single.balance, 50000);
    o = (await r.orders()).single;
    expect(o.applied, 50000);
    expect(o.available, 0);
    expect(o.invoicedQty, 100);

    // Beyond the order nothing is left to take from the advance.
    final i3 = await sale(r, p, prod, 3, 10, orderId: oid);
    expect((await r.invoices()).firstWhere((i) => i.id == i3).prepaid, 0);
    expect((await r.parties()).single.balance, 60000);

    // Paying the rest settles the customer.
    await r.saveTx(date: '2025-03-09', kind: 'receipt', amount: 60000, accountId: acc.id, partyId: p.id);
    expect((await r.parties()).single.balance, 0);
    expect((await r.accounts()).single.balance, 110000);
  });

  test('percent applies to the invoice total including discount and VAT; editing and deleting recompute', () async {
    final (r, p, acc, prod) = await setup();
    final oid = await r.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, productId: prod.id, title: 'برنج', qty: 100, unitPrice: 1000,
        percent: 50, advance: 50000, accountId: acc.id);
    // 10000 - 1000 discount = 9000, +10% VAT = 9900 -> 50% = 4950.
    final id = await sale(r, p, prod, 1, 10, orderId: oid, discount: 1000, tax: 10);
    expect((await r.invoices()).single.prepaid, 4950);
    expect(await r.prepaidPreview(oid, 9900, exceptInvoiceId: id), 4950);
    // Edit to 20 bags: 20000 - 1000 + 10% = 20900 -> 10450 (own previous share is not double counted).
    await sale(r, p, prod, 1, 20, orderId: oid, discount: 1000, tax: 10, id: id);
    expect((await r.invoices()).single.prepaid, 10450);
    expect((await r.orders()).single.applied, 10450);
    expect((await r.parties()).single.balance, 20900 - 10450);
    await r.deleteInvoice(id);
    expect((await r.orders()).single.applied, 0);
    expect((await r.parties()).single.balance, 0);
  });

  test('closing an order turns the unused advance into customer credit; cannot lower advance below applied', () async {
    final (r, p, acc, prod) = await setup();
    final oid = await r.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, productId: prod.id, title: 'برنج', qty: 100, unitPrice: 1000,
        percent: 50, advance: 50000, accountId: acc.id);
    await sale(r, p, prod, 1, 40, orderId: oid); // uses 20000
    await expectLater(
        r.saveOrder(id: oid, number: 1, date: '2025-03-01', partyId: p.id, productId: prod.id, title: 'برنج', qty: 100,
            unitPrice: 1000, percent: 50, advance: 10000, accountId: acc.id),
        throwsA(isA<StateError>()));
    expect((await r.parties()).single.balance, 20000);
    await r.setOrderOpen(oid, false);
    // 30000 of the advance was never used: the customer is now owed that much against the 20000 debt.
    expect((await r.parties()).single.balance, -10000);
    final st = await r.statement(p.id);
    expect(st.closing, -10000);
    expect((await r.orders()).single.open, isFalse);
    await r.setOrderOpen(oid, true);
    expect((await r.parties()).single.balance, 20000);
  });

  test('advance is a liability in the financial position until used; order cannot be deleted while invoiced', () async {
    final (r, p, acc, prod) = await setup();
    final oid = await r.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, productId: prod.id, title: 'برنج', qty: 100, unitPrice: 1000,
        percent: 50, advance: 50000, accountId: acc.id);
    var f = await r.financialPosition();
    expect(f.cash, 50000);
    expect(f.advances, 50000);
    expect(f.equity - f.inventory, 0); // the cash received is offset by what we owe the customer
    await sale(r, p, prod, 1, 40, orderId: oid);
    f = await r.financialPosition();
    expect(f.advances, 30000); // 20000 now offsets the customer's debt
    expect(f.receivables, 20000);
    expect(f.equity - f.inventory, 50000 + 20000 - 30000); // cash + receivable - advances - stock sold
    expect(await r.deleteOrder(oid), isNotNull);

    final empty = await r.saveOrder(
        number: 2, date: '2025-03-02', partyId: p.id, title: 'x', qty: 1, unitPrice: 5, percent: 10, advance: 100, accountId: acc.id);
    expect((await r.accounts()).single.balance, 50100);
    expect(await r.deleteOrder(empty), isNull);
    expect((await r.accounts()).single.balance, 50000);
  });

  test('orders sync, are in backups and follow a currency conversion', () async {
    final (a, p, acc, prod) = await setup();
    final b = await newRepo();
    final oid = await a.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, productId: prod.id, title: 'برنج', qty: 10, unitPrice: 1000,
        percent: 30, advance: 3000, accountId: acc.id);
    await sale(a, p, prod, 1, 10, orderId: oid);
    await b.store.applyRemote(await a.store.changesSince(0));
    expect((await b.orders()).single.applied, 3000);
    expect((await b.invoices()).single.prepaid, 3000);
    await a.convertAmounts(10);
    final o = (await a.orders()).single;
    expect(o.advance, 30000);
    expect(o.unitPrice, 10000);
    expect((await a.invoices()).single.prepaid, 30000);
  });
}
