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
