import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/costing.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_feat');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

void main() {
  financeTests();
  ledgerTests();
  costingTests();
  salesByPartyTests();

  test('products, stock, VAT and return invoices', () async {
    final r = await newRepo();
    await r.saveParty(name: 'مشتری');
    await r.saveParty(name: 'تأمین‌کننده');
    final cust = (await r.parties()).firstWhere((p) => p.name == 'مشتری');
    final supp = (await r.parties()).firstWhere((p) => p.name == 'تأمین‌کننده');
    await r.saveProduct(name: 'برنج', unit: 'کیلوگرم', salePrice: 1000, buyPrice: 700, openingStock: 10, minStock: 5);
    final prod = (await r.products()).single;
    expect(prod.stock, 10);

    // Purchase 20 -> stock 30.
    await r.saveInvoice(number: 1, kind: 'purchase', date: '2025-03-01', partyId: supp.id, discount: 0, note: '',
        items: [InvoiceItem('برنج', 20, 700, productId: prod.id)]);
    expect((await r.products()).single.stock, 30);
    // Sale 27 with 10% VAT and a 100 discount -> stock 3 (low), total (27000-100)*1.1.
    await r.saveInvoice(number: 2, kind: 'sale', date: '2025-03-02', partyId: cust.id, discount: 100, taxPercent: 10,
        note: '', items: [InvoiceItem('برنج', 27, 1000, productId: prod.id)]);
    final p = (await r.products()).single;
    expect(p.stock, 3);
    expect(p.low, isTrue);
    final sale = (await r.invoices()).firstWhere((i) => i.number == 2);
    expect(sale.subtotal, 27000);
    expect(sale.tax, 2690);
    expect(sale.total, 29590);
    expect((await r.parties()).firstWhere((x) => x.id == cust.id).balance, 29590);
    // Supplier: we owe 14000.
    expect((await r.parties()).firstWhere((x) => x.id == supp.id).balance, -14000);

    // Sale return of 2 units brings stock to 5 and reduces what the customer owes.
    await r.saveInvoice(number: 3, kind: 'sale_return', date: '2025-03-03', partyId: cust.id, discount: 0, note: '',
        items: [InvoiceItem('برنج', 2, 1000, productId: prod.id)]);
    expect((await r.products()).single.stock, 5);
    expect((await r.parties()).firstWhere((x) => x.id == cust.id).balance, 29590 - 2000);

    // Editing the invoice replaces its items without double counting stock.
    await r.saveInvoice(id: sale.id, number: 2, kind: 'sale', date: '2025-03-02', partyId: cust.id, discount: 0, taxPercent: 0,
        note: '', items: [InvoiceItem('برنج', 10, 1000, productId: prod.id)]);
    expect((await r.products()).single.stock, 22);

    final sold = await r.productSales('2025-03-01', '2025-04-01');
    expect(sold.single.qty, 8); // 10 sold - 2 returned
    expect(sold.single.revenue, 8000);
  });

  test('cheque clearing books a transaction and can be undone', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'بانک', kind: 'bank', opening: 0);
    final acc = (await r.accounts()).single;
    await r.saveCheque(kind: 'received', number: '123', bank: 'ملی', amount: 5000, dueDate: '2025-05-01');
    var c = (await r.cheques()).single;
    expect(c.status, 'pending');
    expect((await r.accounts()).single.balance, 0);

    await r.setChequeStatus(c, 'cleared', accountId: acc.id, date: '2025-05-01');
    expect((await r.accounts()).single.balance, 5000);
    c = (await r.cheques()).single;
    expect(c.status, 'cleared');
    expect(c.txId, isNotNull);

    // Editing keeps the status.
    await r.saveCheque(id: c.id, kind: 'received', number: '123', bank: 'ملی', amount: 5000, dueDate: '2025-05-02');
    expect((await r.cheques()).single.status, 'cleared');

    await r.setChequeStatus((await r.cheques()).single, 'bounced');
    expect((await r.accounts()).single.balance, 0);
    expect((await r.cheques()).single.txId, isNull);
  });

  test('settings and backup/restore round trip', () async {
    final a = await newRepo();
    await a.setSetting('business_name', 'فروشگاه نمونه');
    await a.setSetting('currency', 'ریال');
    await a.saveAccount(name: 'صندوق', kind: 'cash', opening: 100);
    await a.saveProduct(name: 'کالا', salePrice: 5);
    final json = await a.exportJson();

    final b = await newRepo();
    final n = await b.importJson(json);
    expect(n, greaterThanOrEqualTo(4));
    expect(b.setting('business_name'), 'فروشگاه نمونه');
    expect((await b.accounts()).single.name, 'صندوق');
    expect((await b.products()).single.name, 'کالا');
    // Importing twice changes nothing.
    expect(await b.importJson(json), 0);
    expect(() => b.importJson('{"x":1}'), throwsFormatException);
  });

  test('database upgrades from version 1', () async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('acc_mig');
    final path = '${dir.path}/old.db';
    // Build a v1 database by hand.
    final old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
          await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
          await db.insert('meta', {'key': 'device_id', 'value': 'dev'});
          await db.insert('meta', {'key': 'seq', 'value': '0'});
          await db.execute('''CREATE TABLE invoices (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
            device_id TEXT NOT NULL, seq INTEGER NOT NULL, number INTEGER NOT NULL, kind TEXT NOT NULL, date TEXT NOT NULL,
            party_id TEXT NOT NULL, discount INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '')''');
          await db.execute('''CREATE TABLE invoice_items (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
            device_id TEXT NOT NULL, seq INTEGER NOT NULL, invoice_id TEXT NOT NULL, title TEXT NOT NULL, qty REAL NOT NULL,
            unit_price INTEGER NOT NULL, position INTEGER NOT NULL DEFAULT 0)''');
          for (final t in ['accounts', 'parties', 'categories', 'transactions']) {
            await db.execute('CREATE TABLE $t (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, device_id TEXT NOT NULL, seq INTEGER NOT NULL)');
          }
          for (final t in ['accounts', 'parties', 'categories', 'invoices', 'invoice_items', 'transactions']) {
            await db.execute('CREATE INDEX idx_${t}_seq ON $t(seq)');
          }
        }));
    await old.insert('invoices', {'id': 'i1', 'updated_at': 1, 'device_id': 'dev', 'seq': 1, 'number': 1, 'kind': 'sale', 'date': '2025-01-01', 'party_id': 'p'});
    await old.close();

    final store = await AppDb.open(path: path, factory: databaseFactoryFfi);
    final rows = await store.db.query('invoices');
    expect(rows.single['tax_percent'], 0);
    await store.save('products', {'name': 'x'});
    await store.save('cheques', {'kind': 'received', 'amount': 1, 'due_date': '2025-01-01'});
    await store.save('costings', {'product_id': 'p', 'lines': '[]'});
    await store.save('formulas', {'name': 'f', 'expression': 'cost'});
    await store.close();
  });
}

void salesByPartyTests() {
  test('sales of a product per party, with returns, linked and typed lines, and periods', () async {
    final r = await newRepo();
    await r.saveParty(name: 'الف');
    await r.saveParty(name: 'ب');
    await r.saveParty(name: 'ج');
    final ps = {for (final p in await r.parties()) p.name: p.id};
    await r.saveProduct(name: 'برنج', salePrice: 100);
    await r.saveProduct(name: 'شکر', salePrice: 50);
    final rice = (await r.products()).firstWhere((p) => p.name == 'برنج');
    final sugar = (await r.products()).firstWhere((p) => p.name == 'شکر');

    Future<void> inv(int n, String kind, String date, String party, List<InvoiceItem> items) =>
        r.saveInvoice(number: n, kind: kind, date: date, partyId: ps[party]!, discount: 0, note: '', items: items);

    await inv(1, 'sale', '2025-03-01', 'الف', [InvoiceItem('برنج', 3, 100, productId: rice.id), InvoiceItem('شکر', 1, 50, productId: sugar.id)]);
    await inv(2, 'sale', '2025-04-01', 'الف', [InvoiceItem('برنج', 2, 110, productId: rice.id)]);
    await inv(3, 'sale_return', '2025-04-02', 'الف', [InvoiceItem('برنج', 1, 110, productId: rice.id)]);
    await inv(4, 'sale', '2025-03-05', 'ب', [InvoiceItem('برنج', 5, 100, productId: rice.id)]);
    await inv(5, 'sale', '2025-03-06', 'ب', [InvoiceItem('برنج', 1, 90)]); // typed by hand, same name
    await inv(6, 'purchase', '2025-03-07', 'ج', [InvoiceItem('برنج', 100, 70, productId: rice.id)]); // not a sale
    await inv(7, 'sale', '2025-03-08', 'ج', [InvoiceItem('شکر', 4, 50, productId: sugar.id)]);

    final all = await r.productSalesByParty(rice.id);
    expect(all.map((e) => e.name), ['ب', 'الف']); // ب: 590, الف: 300+220-110=410
    expect(all[0].qty, 6);
    expect(all[0].revenue, 590);
    expect(all[0].invoices, 2);
    expect(all[1].qty, 4);
    expect(all[1].revenue, 410);
    expect(all[1].invoices, 3);

    final march = await r.productSalesByParty(rice.id, from: '2025-03-01', toExclusive: '2025-04-01');
    expect({for (final e in march) e.name: e.revenue}, {'ب': 590, 'الف': 300});

    final sugarSales = await r.productSalesByParty(sugar.id);
    expect({for (final e in sugarSales) e.name: e.revenue}, {'ج': 200, 'الف': 50});

    final lines = await r.productSaleLines(rice.id, ps['الف']!);
    expect(lines.map((l) => l.number), [3, 2, 1]);
    expect(lines.first.kind, 'sale_return');
    expect(lines.last.total, 300);
    expect(await r.productSaleLines(rice.id, ps['ج']!), isEmpty);

    // Deleted invoices disappear.
    await r.deleteInvoice((await r.invoices()).firstWhere((i) => i.number == 4).id);
    expect((await r.productSalesByParty(rice.id)).firstWhere((e) => e.name == 'ب').revenue, 90);
  });
}

void costingTests() {
  test('cost sheets and formulas are stored, shown on the product and synced', () async {
    final a = await newRepo();
    await a.saveProduct(name: 'صابون', buyPrice: 500, salePrice: 900);
    final p = (await a.products()).single;
    expect(p.costPrice, 0);
    expect(await a.costSheet(p.id), isNull);

    final sheet = CostSheet(batchQty: 10, wastePercent: 0, lines: [
      CostLine(name: 'مواد', value: 4000),
      CostLine(name: 'سربار', type: 'percent', value: 25),
    ]);
    await a.saveCostSheet(p.id, sheet);
    final back = (await a.costSheet(p.id))!;
    expect(back.batchQty, 10);
    expect(back.lines.map((l) => l.name), ['مواد', 'سربار']);
    expect(back.lines[1].type, 'percent');
    expect((await a.products()).single.costPrice, 500); // 5000 / 10

    await a.setProductPrice(p.id, salePrice: 1100);
    final updated = (await a.products()).single;
    expect(updated.salePrice, 1100);
    expect(updated.buyPrice, 500);

    await a.saveFormula(name: 'سود ۳۰٪', expression: 'cost * 1.3');
    expect((await a.formulas()).single.expression, 'cost * 1.3');

    // Both tables travel with the backup / sync.
    final b = await newRepo();
    await b.importJson(await a.exportJson());
    expect((await b.costSheet(p.id))!.lines.length, 2);
    expect((await b.formulas()).single.name, 'سود ۳۰٪');

    await a.deleteFormula((await a.formulas()).single.id);
    await a.deleteCostSheet(p.id);
    expect(await a.formulas(), isEmpty);
    expect(await a.costSheet(p.id), isNull);
    expect((await a.products()).single.costPrice, 0);
  });
}

void ledgerTests() {
  test('transfers between accounts move money without touching income, expense or parties', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 1000);
    await r.saveAccount(name: 'بانک', kind: 'bank', opening: 0);
    final accs = {for (final a in await r.accounts()) a.name: a.id};
    await r.saveTx(date: '2025-01-05', kind: 'transfer', amount: 400, accountId: accs['صندوق']!, toAccountId: accs['بانک'], description: 'واریز');
    final bal = {for (final a in await r.accounts()) a.name: a.balance};
    expect(bal, {'صندوق': 600, 'بانک': 400});
    expect(bal.values.reduce((a, b) => a + b), 1000); // nothing created or lost

    final rep = await r.report('2025-01-01', '2025-02-01');
    expect(rep.income, 0);
    expect(rep.expense, 0);

    // The transfer shows up under both accounts.
    expect((await r.transactions(accountId: accs['صندوق'])).single.kind, 'transfer');
    expect((await r.transactions(accountId: accs['بانک'])).single.toAccountId, accs['بانک']);

    await r.saveTx(date: '2025-01-06', kind: 'receipt', amount: 100, accountId: accs['بانک']!);
    expect((await r.accounts()).firstWhere((a) => a.name == 'بانک').balance, 500);
    await r.deleteTx((await r.transactions(accountId: accs['صندوق'])).single.id);
    expect((await r.accounts()).firstWhere((a) => a.name == 'صندوق').balance, 1000);
  });

  test('a party can start with a balance, and it flows into balance, statement and conversion', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single;
    await r.saveParty(name: 'بدهکار قدیمی', opening: 5000);
    await r.saveParty(name: 'بستانکار قدیمی', opening: -3000);
    final ps = {for (final p in await r.parties()) p.name: p};
    expect(ps['بدهکار قدیمی']!.balance, 5000);
    expect(ps['بستانکار قدیمی']!.balance, -3000);
    expect(ps['بدهکار قدیمی']!.opening, 5000);

    await r.saveTx(date: '2025-02-01', kind: 'receipt', amount: 2000, accountId: acc.id, partyId: ps['بدهکار قدیمی']!.id);
    final st = await r.statement(ps['بدهکار قدیمی']!.id);
    expect(st.opening, 5000);
    expect(st.rows.single.balance, 3000);
    expect(st.closing, 3000);
    // In a later period the opening is the party's start plus everything before.
    final later = await r.statement(ps['بدهکار قدیمی']!.id, from: '2025-03-01');
    expect(later.opening, 3000);
    expect(later.rows, isEmpty);

    await r.convertAmounts(10);
    expect((await r.parties()).firstWhere((p) => p.name == 'بدهکار قدیمی').balance, 30000);
  });

  test('pro-forma changes no balance, stock or report; converting makes a real invoice', () async {
    final r = await newRepo();
    await r.saveParty(name: 'مشتری');
    final p = (await r.parties()).single;
    await r.saveProduct(name: 'کالا', salePrice: 100, openingStock: 10);
    final prod = (await r.products()).single;

    // Pro-forma numbers are their own series.
    await r.saveInvoice(number: await r.nextInvoiceNumber('proforma'), kind: 'proforma', date: '2025-04-01', partyId: p.id, discount: 20, taxPercent: 10, note: 'n',
        items: [InvoiceItem('کالا', 4, 100, productId: prod.id)]);
    expect(await r.nextInvoiceNumber('proforma'), 2);
    expect(await r.nextInvoiceNumber('sale'), 1);
    final pro = (await r.invoices()).single;
    expect(pro.total, 418); // (400 - 20) * 1.1

    expect((await r.parties()).single.balance, 0);
    expect((await r.products()).single.stock, 10);
    expect((await r.productSales('2025-01-01', '2026-01-01')), isEmpty);
    expect((await r.statement(p.id)).rows, isEmpty);

    final saleId = await r.convertProforma(pro.id);
    final all = {for (final i in await r.invoices()) i.id: i};
    expect(all[saleId]!.kind, 'sale');
    expect(all[saleId]!.number, 1);
    expect(all[saleId]!.total, 418);
    expect(all[pro.id]!.refId, saleId);
    expect((await r.parties()).single.balance, 418);
    expect((await r.products()).single.stock, 6);
    expect(() => r.convertProforma(pro.id), throwsStateError); // only once

    // Editing the pro-forma later keeps its link.
    await r.saveInvoice(id: pro.id, number: pro.number, kind: 'proforma', date: pro.date, partyId: p.id, discount: 0, note: 'x',
        items: [InvoiceItem('کالا', 1, 100)]);
    expect((await r.invoices()).firstWhere((i) => i.id == pro.id).refId, saleId);
    expect(() => r.convertProforma(saleId), throwsStateError); // not a pro-forma
  });
}

void financeTests() {
  Future<String> party(Repo r, String name, {int opening = 0}) async {
    await r.saveParty(name: name, opening: opening);
    return (await r.parties()).firstWhere((p) => p.name == name).id;
  }

  test('VAT report: output minus input, returns negative, pro-forma ignored', () async {
    final r = await newRepo();
    final c = await party(r, 'مشتری');
    final s = await party(r, 'تأمین‌کننده');
    Future<void> inv(int n, String kind, String date, String pid, int price, {int tax = 10}) => r.saveInvoice(
        number: n, kind: kind, date: date, partyId: pid, discount: 0, taxPercent: tax, note: '', items: [InvoiceItem('x', 1, price)]);
    await inv(1, 'sale', '2025-05-02', c, 1000);
    await inv(2, 'sale_return', '2025-05-03', c, 200);
    await inv(3, 'purchase', '2025-05-04', s, 500);
    await inv(4, 'proforma', '2025-05-05', c, 9999);
    await inv(5, 'sale', '2025-07-01', c, 777); // another period
    final v = await r.vatReport('2025-05-01', '2025-06-01');
    expect(v.lines.length, 3);
    expect(v.outputTax, 100 - 20);
    expect(v.inputTax, 50);
    expect(v.payable, 30);
    expect(v.salesBase, 800);
    expect(v.purchasesBase, 500);
    expect(v.lines.firstWhere((l) => l.kind == 'sale_return').tax, -20);
  });

  test('profit and loss: sales, cost of goods, other income and expenses', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single.id;
    await r.saveCategory(name: 'اجاره', kind: 'expense');
    await r.saveCategory(name: 'حقوق', kind: 'expense');
    await r.saveCategory(name: 'سود بانکی', kind: 'income');
    final cats = {for (final c in await r.categories()) c.name: c.id};
    final cust = await party(r, 'مشتری');
    final supp = await party(r, 'تأمین‌کننده');
    await r.saveProduct(name: 'کالا', salePrice: 300, buyPrice: 100, openingStock: 10);
    final prod = (await r.products()).single.id;

    await r.saveInvoice(number: 1, kind: 'purchase', date: '2025-01-10', partyId: supp, discount: 0, note: '', items: [InvoiceItem('کالا', 10, 200, productId: prod)]);
    await r.saveInvoice(number: 2, kind: 'sale', date: '2025-02-10', partyId: cust, discount: 100, note: '',
        items: [InvoiceItem('کالا', 5, 300, productId: prod), InvoiceItem('خدمات', 2, 50)]);
    await r.saveInvoice(number: 3, kind: 'sale_return', date: '2025-02-12', partyId: cust, discount: 0, note: '', items: [InvoiceItem('کالا', 1, 300, productId: prod)]);

    Future<void> tx(String kind, int amount, {String? cat, String? party}) =>
        r.saveTx(date: '2025-02-15', kind: kind, amount: amount, accountId: acc, categoryId: cat == null ? null : cats[cat], partyId: party);
    await tx('payment', 200, cat: 'اجاره');
    await tx('payment', 300, cat: 'حقوق');
    await tx('payment', 999, party: supp); // settles a supplier: not an expense
    await tx('payment', 55); // no category, no person: reported as uncategorised
    await tx('receipt', 40, cat: 'سود بانکی');
    await tx('receipt', 123, party: cust); // settles a customer: not income

    expect((await r.unitCosts('2026-01-01'))[prod], 150); // (10*100 + 10*200) / 20
    final pl = await r.profitLoss('2025-02-01', '2025-03-01');
    expect(pl.sales, 1200); // 1500 + 100 - 300 - 100 discount
    expect(pl.cogs, 600); // (5 - 1) sold at 150
    expect(pl.grossProfit, 600);
    expect(pl.otherIncome, 40);
    expect(pl.expenses, 500);
    expect(pl.expensesByCategory.map((e) => e.$1), ['حقوق', 'اجاره']);
    expect(pl.netProfit, 140);
    expect(pl.uncategorized, 55);
    expect(pl.unlinkedSales, 100);

    // A cost sheet overrides the purchase average.
    await r.saveCostSheet(prod, CostSheet(batchQty: 1, lines: [CostLine(name: 'x', value: 100)]));
    expect((await r.profitLoss('2025-02-01', '2025-03-01')).cogs, 400);
    // A period without sales is empty.
    final empty = await r.profitLoss('2025-03-01', '2025-04-01');
    expect([empty.sales, empty.cogs, empty.netProfit], [0, 0, 0]);
  });

  test('financial position: assets, liabilities and equity', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 1000);
    await r.saveAccount(name: 'بانک', kind: 'bank', opening: -200); // overdraft
    await r.saveProduct(name: 'کالا', buyPrice: 50, openingStock: 10);
    await party(r, 'بدهکار', opening: 300);
    await party(r, 'بستانکار', opening: -500);
    await r.saveCheque(kind: 'received', number: '1', bank: '', amount: 700, dueDate: '2025-09-01');
    await r.saveCheque(kind: 'issued', number: '2', bank: '', amount: 400, dueDate: '2025-09-01');
    await r.saveCheque(kind: 'received', number: '3', bank: '', amount: 9999, dueDate: '2025-09-01');
    await r.setChequeStatus((await r.cheques()).firstWhere((c) => c.number == '3'), 'bounced');

    final f = await r.financialPosition();
    expect(f.cash, 1000);
    expect(f.overdrafts, 200);
    expect(f.receivables, 300);
    expect(f.inventory, 500);
    expect(f.chequesReceived, 700); // the bounced one is not an asset
    expect(f.assets, 1000 + 300 + 500 + 700);
    expect(f.payables, 500);
    expect(f.chequesIssued, 400);
    expect(f.liabilities, 500 + 400 + 200);
    expect(f.equity, 2500 - 1100);
  });

  test('ageing puts the newest invoices in the unpaid pile, oldest paid first', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single.id;
    final p = await party(r, 'مشتری');
    Future<void> sale(int n, String date, int price) => r.saveInvoice(number: n, kind: 'sale', date: date, partyId: p, discount: 0, note: '', items: [InvoiceItem('x', 1, price)]);
    await sale(1, '2025-03-22', 1000); // 100 days before 30 June
    await sale(2, '2025-05-21', 500); // 40 days
    await sale(3, '2025-06-20', 200); // 10 days
    await r.saveTx(date: '2025-06-25', kind: 'receipt', amount: 1200, accountId: acc, partyId: p);
    final rows = await r.ageing(asOf: DateTime(2025, 6, 30));
    expect(rows.single.total, 500);
    expect(rows.single.buckets, [200, 300, 0, 0]);

    await party(r, 'با مانده اول دوره', opening: 400);
    final again = await r.ageing(asOf: DateTime(2025, 6, 30));
    expect(again.map((e) => e.name), ['مشتری', 'با مانده اول دوره']);
    expect(again.last.buckets, [0, 0, 0, 400]); // older than any invoice on record
  });

  test('account ledger and product card carry running balances across periods', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 1000);
    await r.saveAccount(name: 'بانک', kind: 'bank', opening: 0);
    final accs = {for (final a in await r.accounts()) a.name: a.id};
    await r.saveTx(date: '2025-01-10', kind: 'receipt', amount: 200, accountId: accs['صندوق']!);
    await r.saveTx(date: '2025-02-10', kind: 'payment', amount: 50, accountId: accs['صندوق']!);
    await r.saveTx(date: '2025-03-10', kind: 'transfer', amount: 100, accountId: accs['صندوق']!, toAccountId: accs['بانک']);
    final all = await r.accountLedger(accs['صندوق']!);
    expect(all.opening, 1000);
    expect(all.lines.map((l) => l.balance), [1200, 1150, 1050]);
    expect(all.closing, 1050);
    final feb = await r.accountLedger(accs['صندوق']!, from: '2025-02-01', toExclusive: '2025-03-01');
    expect(feb.opening, 1200);
    expect(feb.lines.length, 1);
    expect(feb.closing, 1150);
    expect(feb.totalOut, 50);
    final bank = await r.accountLedger(accs['بانک']!);
    expect(bank.lines.single.inAmount, 100);
    expect(bank.closing, 100);

    final cust = await party(r, 'مشتری');
    await r.saveProduct(name: 'کالا', salePrice: 10, openingStock: 10);
    final prod = (await r.products()).single.id;
    await r.saveInvoice(number: 1, kind: 'purchase', date: '2025-01-05', partyId: cust, discount: 0, note: '', items: [InvoiceItem('کالا', 5, 1, productId: prod)]);
    await r.saveInvoice(number: 2, kind: 'sale', date: '2025-02-05', partyId: cust, discount: 0, note: '', items: [InvoiceItem('کالا', 3, 10, productId: prod)]);
    await r.saveInvoice(number: 1, kind: 'proforma', date: '2025-02-06', partyId: cust, discount: 0, note: '', items: [InvoiceItem('کالا', 100, 10, productId: prod)]);
    final card = await r.productCard(prod, from: '2025-02-01');
    expect(card.opening, 15);
    expect(card.lines.single.outAmount, 3);
    expect(card.closing, 12);
    expect((await r.productCard(prod)).lines.map((l) => l.balance), [15, 12]);
  });
}
