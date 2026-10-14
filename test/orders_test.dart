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
        number: 1, date: '2025-03-01', partyId: p.id, items: [OrderItem('برنج', 100, 1000, productId: prod.id)],
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
    expect(o.items.single.invoicedQty, 100);
    expect(o.progress, 1);

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
        number: 1, date: '2025-03-01', partyId: p.id, items: [OrderItem('برنج', 100, 1000, productId: prod.id)],
        percent: 50, advance: 50000, accountId: acc.id);
    // 10000 - 1000 discount = 9000, +10% VAT = 9900 -> 50% = 4950.
    final id = await sale(r, p, prod, 1, 10, orderId: oid, discount: 1000, tax: 10);
    expect((await r.invoices()).single.prepaid, 4950);
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
        number: 1, date: '2025-03-01', partyId: p.id, items: [OrderItem('برنج', 100, 1000, productId: prod.id)],
        percent: 50, advance: 50000, accountId: acc.id);
    await sale(r, p, prod, 1, 40, orderId: oid); // uses 20000
    await expectLater(
        r.saveOrder(id: oid, number: 1, date: '2025-03-01', partyId: p.id, items: [OrderItem('برنج', 100, 1000, productId: prod.id)], percent: 50, advance: 10000, accountId: acc.id),
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
        number: 1, date: '2025-03-01', partyId: p.id, items: [OrderItem('برنج', 100, 1000, productId: prod.id)],
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
        number: 2, date: '2025-03-02', partyId: p.id, items: [OrderItem('x', 1, 5)], percent: 10, advance: 100, accountId: acc.id);
    expect((await r.accounts()).single.balance, 50100);
    expect(await r.deleteOrder(empty), isNull);
    expect((await r.accounts()).single.balance, 50000);
  });

  test('orders sync, are in backups and follow a currency conversion', () async {
    final (a, p, acc, prod) = await setup();
    final b = await newRepo();
    final oid = await a.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, items: [OrderItem('برنج', 10, 1000, productId: prod.id)],
        percent: 30, advance: 3000, accountId: acc.id);
    await sale(a, p, prod, 1, 10, orderId: oid);
    await b.store.applyRemote(await a.store.changesSince(0));
    expect((await b.orders()).single.applied, 3000);
    expect((await b.invoices()).single.prepaid, 3000);
    await a.convertAmounts(10);
    final o = (await a.orders()).single;
    expect(o.advance, 30000);
    expect(o.items.single.unitPrice, 10000);
    expect((await a.invoices()).single.prepaid, 30000);
  });

  test('order with several products: only the invoice lines that are in the order carry the advance', () async {
    final (r, p, acc, rice) = await setup();
    await r.saveProduct(name: 'روغن', unit: 'گالن', salePrice: 2000, buyPrice: 1500, openingStock: 100, minStock: 0);
    final oil = (await r.products()).firstWhere((x) => x.name == 'روغن');
    // Rice 100 x 1000 + oil 50 x 2000 = 200000; 50% advance = 100000.
    final oid = await r.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, percent: 50, advance: 100000, accountId: acc.id,
        items: [OrderItem('برنج', 100, 1000, productId: rice.id), OrderItem('روغن', 50, 2000, productId: oil.id)]);
    var o = (await r.orders()).single;
    expect(o.total, 200000);
    expect(o.items.length, 2);
    expect(o.title, contains('برنج'));
    expect((await r.parties()).single.balance, 0);

    // One invoice with both products and a product that is not in the order:
    // lines 40000 + 20000 + 10000 = 70000, of which 60000 is the order's -> 50% of that = 30000.
    final id = await r.saveInvoice(
        number: 1, kind: 'sale', date: '2025-03-02', partyId: p.id, discount: 0, note: '', orderId: oid, items: [
      InvoiceItem('برنج', 40, 1000, productId: rice.id),
      InvoiceItem('روغن', 10, 2000, productId: oil.id),
      InvoiceItem('خدمات', 1, 10000),
    ]);
    var inv = (await r.invoices()).firstWhere((i) => i.id == id);
    expect((inv.total, inv.prepaid, inv.remaining), (70000, 30000, 40000));
    expect((await r.parties()).single.balance, 40000);
    o = (await r.orders()).single;
    expect(o.items[0].invoicedQty, 40);
    expect(o.items[1].invoicedQty, 10);
    expect(o.items[0].remainingQty, 60);
    expect(o.progress, closeTo(60000 / 200000, 1e-9));
    expect(o.available, 70000);

    // VAT and discount follow the same share: 20000 oil - 2000 discount... all of it is the order's.
    final id2 = await r.saveInvoice(
        number: 2, kind: 'sale', date: '2025-03-03', partyId: p.id, discount: 2000, taxPercent: 10, note: '', orderId: oid,
        items: [InvoiceItem('روغن', 10, 2000, productId: oil.id)]);
    inv = (await r.invoices()).firstWhere((i) => i.id == id2);
    expect(inv.total, 19800);
    expect(inv.prepaid, 9900);

    // An invoice with nothing from the order takes nothing from the advance.
    final id3 = await r.saveInvoice(
        number: 3, kind: 'sale', date: '2025-03-04', partyId: p.id, discount: 0, note: '', orderId: oid,
        items: [InvoiceItem('خدمات', 1, 5000)]);
    expect((await r.invoices()).firstWhere((i) => i.id == id3).prepaid, 0);
    expect(Repo.orderShare(o.items, [InvoiceItem('خدمات', 1, 5000)]), 0);
    expect(Repo.orderShare(o.items, [InvoiceItem('برنج', 1, 1000, productId: rice.id), InvoiceItem('خدمات', 1, 3000)]), closeTo(0.25, 1e-9));
  });

  test('orders made before multi-product support are upgraded to an order with one item', () async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('acc_ordmig');
    final path = '${dir.path}/old.db';
    // Create a current database, then turn it back into the previous version's shape.
    final first = await AppDb.open(path: path, factory: databaseFactoryFfi);
    await first.close();
    final raw = await databaseFactoryFfi.openDatabase(path);
    await raw.execute('DROP TABLE order_items');
    await raw.execute('ALTER TABLE cheques DROP COLUMN order_id'); // added in version 8
    await raw.execute('DROP TABLE product_groups'); // version 9
    await raw.execute('ALTER TABLE products DROP COLUMN group_id');
    await raw.execute(
        "INSERT INTO cheques (id, updated_at, deleted, device_id, seq, kind, number, bank, amount, due_date, status)"
        " VALUES ('c1', 1000, 0, 'dev', 4, 'received', '9', 'ملت', 7000, '2025-05-01', 'pending')");
    await raw.execute(
        "INSERT INTO orders (id, updated_at, deleted, device_id, seq, number, date, party_id, product_id, title, qty, unit_price, advance_percent, advance_amount, status)"
        " VALUES ('o1', 1000, 0, 'dev', 5, 1, '2025-03-01', 'p1', 'prod1', 'برنج', 100, 1000, 50, 50000, 'open')");
    await raw.execute("UPDATE meta SET value='5' WHERE key='seq'");
    await raw.execute('PRAGMA user_version = 6');
    await raw.close();

    final r = Repo(await AppDb.open(path: path, factory: databaseFactoryFfi));
    await r.init();
    final o = (await r.orders()).single;
    expect(o.items.length, 1);
    expect((o.items.single.title, o.items.single.qty, o.items.single.unitPrice, o.items.single.productId), ('برنج', 100.0, 1000, 'prod1'));
    expect(o.total, 100000);
    final old = (await r.cheques()).single; // existing cheques survive and are not tied to an order
    expect((old.amount, old.orderId), (7000, null));
    expect(await r.productGroups(), isEmpty); // the newest tables exist after upgrading
    // The new row is picked up by sync (its seq is after the old counter) and has a stable id.
    final rows = (await r.store.changesSince(5))['order_items']!;
    expect(rows.single['id'], 'o1:0');
  });

  test('advance partly by cheque: counts on invoices at once, cash only when it clears, customer never credited', () async {
    final (r, p, acc, prod) = await setup();
    // Order 100000, 50% advance = 50000: 20000 cash + a 30000 cheque.
    final oid = await r.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, percent: 50, advance: 20000, accountId: acc.id,
        items: [OrderItem('برنج', 100, 1000, productId: prod.id)],
        cheques: [ChequeDraft(amount: 30000, dueDate: '2025-05-01', number: '123', bank: 'ملی')]);
    var o = (await r.orders()).single;
    expect((o.cash, o.chequeAmount, o.advance, o.available), (20000, 30000, 50000, 50000));
    final chq = (await r.cheques()).single;
    expect((chq.kind, chq.status, chq.orderId, chq.partyId), ('received', 'pending', oid, p.id));
    expect((await r.accounts()).single.balance, 20000); // only the cash is in the box
    expect((await r.parties()).single.balance, 0);
    var f = await r.financialPosition();
    expect((f.cash, f.chequesReceived, f.advances), (20000, 30000, 50000));

    // The cheque already counts on the invoice (customer paid with it).
    await sale(r, p, prod, 1, 40, orderId: oid);
    expect((await r.invoices()).single.prepaid, 20000);
    expect((await r.parties()).single.balance, 20000);

    // Clearing books cash without a party: the customer is not credited a second time.
    await r.setChequeStatus(chq, 'cleared', accountId: acc.id);
    expect((await r.accounts()).single.balance, 50000);
    expect((await r.parties()).single.balance, 20000);
    expect((await r.transactions()).where((t) => t.partyId == p.id), isEmpty);
    f = await r.financialPosition();
    expect((f.cash, f.chequesReceived, f.advances), (50000, 0, 30000));
  });

  test('advance fully by cheque needs no account; a bounced cheque takes the advance back from the invoices', () async {
    final (r, p, _, prod) = await setup();
    final oid = await r.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, percent: 50, advance: 0,
        items: [OrderItem('برنج', 100, 1000, productId: prod.id)],
        cheques: [ChequeDraft(amount: 50000, dueDate: '2025-05-01')]);
    expect((await r.transactions()), isEmpty);
    expect((await r.orders()).single.advance, 50000);
    // 100000 invoice -> 50000 from the cheque advance; customer owes 50000.
    await sale(r, p, prod, 1, 100, orderId: oid);
    expect((await r.invoices()).single.prepaid, 50000);
    expect((await r.parties()).single.balance, 50000);

    // The cheque bounces: the advance never arrived, the whole invoice is owed.
    await r.setChequeStatus((await r.cheques()).single, 'bounced');
    expect((await r.orders()).single.advance, 0);
    expect((await r.invoices()).single.prepaid, 0);
    expect((await r.parties()).single.balance, 100000);
    expect((await r.financialPosition()).advances, 0);

    // Back to pending: the advance is there again for new invoices (old ones are not changed behind your back).
    await r.setChequeStatus((await r.cheques()).single, 'pending');
    expect((await r.orders()).single.advance, 50000);
    expect((await r.invoices()).single.prepaid, 0);
  });

  test('bounce after closing the order takes back the credit first; deleting a cheque rebalances too', () async {
    final (r, p, acc, prod) = await setup();
    final oid = await r.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, percent: 50, advance: 10000, accountId: acc.id,
        items: [OrderItem('برنج', 100, 1000, productId: prod.id)],
        cheques: [ChequeDraft(amount: 40000, dueDate: '2025-05-01')]);
    await sale(r, p, prod, 1, 40, orderId: oid); // prepaid 20000 of 50000
    await r.setOrderOpen(oid, false); // 30000 left becomes customer credit
    expect((await r.parties()).single.balance, 20000 - 30000);
    await r.setChequeStatus((await r.cheques()).single, 'bounced'); // advance is now only the 10000 cash
    final o = (await r.orders()).single;
    expect((o.advance, o.released, o.applied), (10000, 0, 10000)); // credit gone, invoice keeps only what is really there
    expect((await r.parties()).single.balance, 40000 - 10000);

    // Deleting a cheque of another order behaves the same.
    final oid2 = await r.saveOrder(
        number: 2, date: '2025-03-02', partyId: p.id, percent: 50, advance: 0,
        items: [OrderItem('برنج', 10, 1000, productId: prod.id)], cheques: [ChequeDraft(amount: 5000, dueDate: '2025-05-01')]);
    await sale(r, p, prod, 2, 10, orderId: oid2);
    expect((await r.invoices()).firstWhere((i) => i.orderId == oid2).prepaid, 5000);
    await r.deleteCheque((await r.cheques()).firstWhere((c) => c.orderId == oid2));
    expect((await r.invoices()).firstWhere((i) => i.orderId == oid2).prepaid, 0);
  });

  test('order cheques sync and survive a restore', () async {
    final (a, p, acc, prod) = await setup();
    final b = await newRepo();
    await a.saveOrder(
        number: 1, date: '2025-03-01', partyId: p.id, percent: 50, advance: 0,
        items: [OrderItem('برنج', 10, 1000, productId: prod.id)], cheques: [ChequeDraft(amount: 5000, dueDate: '2025-05-01')]);
    await b.store.applyRemote(await a.store.changesSince(0));
    expect((await b.cheques()).single.orderId, (await a.orders()).single.id);
    expect((await b.orders()).single.advance, 5000);
    expect(acc.id, isNotEmpty);
  });
}
