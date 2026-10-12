import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/print/pdf_docs.dart';
import 'package:simple_accounting/print/print_settings.dart';
import 'package:simple_accounting/print/report_builders.dart';
import 'package:simple_accounting/print/report_doc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_print');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

/// MediaBox of the first page, e.g. [595.27, 841.89].
List<double> mediaBox(List<int> pdf) {
  final text = latin1.decode(pdf);
  final m = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]').firstMatch(text)!;
  return [double.parse(m[1]!), double.parse(m[2]!)];
}

int pageCount(List<int> pdf) => RegExp(r'/Type\s*/Page(?![a-zA-Z])').allMatches(latin1.decode(pdf)).length;

void main() {
  test('print settings are stored per device and survive a restart', () async {
    final r = await newRepo();
    expect(r.printSettings.paper, 'a4');
    await r.setPrint(const PrintSettings(paper: 'a5', landscape: true, marginMm: 8, fontScale: 1.2, rollWidthMm: 58));
    final again = await PrintSettings.load(r.store);
    expect(again.paper, 'a5');
    expect(again.landscape, isTrue);
    expect(again.marginMm, 8);
    expect(again.fontScale, 1.2);
    expect(again.rollWidthMm, 58);
    // Not part of the synced/backup data.
    expect(await r.exportJson(), isNot(contains('print_paper')));
    expect(const PrintSettings(paper: 'a5').format.width, closeTo(PdfPageFormat.a5.width, 0.01));
    expect(const PrintSettings(paper: 'a5', landscape: true).format.width, closeTo(PdfPageFormat.a5.height, 0.01));
  });

  test('statement carries the balance in from before the period', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single;
    await r.saveParty(name: 'علی');
    final p = (await r.parties()).single;
    Future<void> sale(int n, String date, int price) => r.saveInvoice(
        number: n, kind: 'sale', date: date, partyId: p.id, discount: 0, note: '', items: [InvoiceItem('x', 1, price)]);
    await sale(1, '2025-01-10', 1000); // +1000
    await r.saveTx(date: '2025-01-20', kind: 'receipt', amount: 400, accountId: acc.id, partyId: p.id); // -400
    await sale(2, '2025-02-05', 500); // +500
    await r.saveTx(date: '2025-02-05', kind: 'receipt', amount: 100, accountId: acc.id, partyId: p.id); // -100
    await sale(3, '2025-03-01', 2000); // +2000 (outside the period)

    final all = await r.statement(p.id);
    expect(all.opening, 0);
    expect(all.rows.map((e) => e.balance), [1000, 600, 1100, 1000, 3000]);
    expect(all.closing, 3000);

    final feb = await r.statement(p.id, from: '2025-02-01', toExclusive: '2025-03-01');
    expect(feb.opening, 600);
    expect(feb.rows.length, 2);
    expect(feb.rows.first.debit, 500); // invoice listed before the payment of the same day
    expect(feb.rows.last.credit, 100);
    expect(feb.closing, 1000);
    expect(feb.totalDebit, 500);
    expect(feb.totalCredit, 100);
  });

  testWidgets('PDFs follow the paper size, orientation and margins', (tester) async {
    await tester.runAsync(() async {
      final r = await newRepo();
      await r.setSetting('business_name', 'فروشگاه آزمایشی');
      await r.saveParty(name: 'مشتری');
      final p = (await r.parties()).single;
      await r.saveInvoice(number: 1, kind: 'sale', date: '2025-05-01', partyId: p.id, discount: 0, taxPercent: 10, note: 'یادداشت', items: [
        for (var i = 0; i < 3; i++) InvoiceItem('کالا ${i + 1}', 2, 1000),
      ]);
      final inv = (await r.invoices()).single;
      final items = await r.invoiceItems(inv.id);

      for (final (paper, land, w, h) in [
        ('a4', false, PdfPageFormat.a4.width, PdfPageFormat.a4.height),
        ('a5', false, PdfPageFormat.a5.width, PdfPageFormat.a5.height),
        ('a4', true, PdfPageFormat.a4.height, PdfPageFormat.a4.width),
        ('a5', true, PdfPageFormat.a5.height, PdfPageFormat.a5.width),
      ]) {
        final docs = PdfDocs(r, settings: PrintSettings(paper: paper, landscape: land));
        final box = mediaBox(await docs.invoice(inv, items, p));
        expect(box[0], closeTo(w, 0.5), reason: '$paper landscape=$land width');
        expect(box[1], closeTo(h, 0.5), reason: '$paper landscape=$land height');
        final st = mediaBox(await docs.statement(p));
        expect(st[0], closeTo(w, 0.5));
      }

      // The page chosen in the print dialog wins over the saved paper.
      final fromDialog = await PdfDocs(r, settings: const PrintSettings(paper: 'a4')).report(ReportDoc(title: 'x'), format: PdfPageFormat.a5);
      expect(mediaBox(fromDialog)[0], closeTo(PdfPageFormat.a5.width, 0.5));

      // Thermal roll width.
      final roll58 = mediaBox(await PdfDocs(r, settings: const PrintSettings(rollWidthMm: 58)).invoice(inv, items, p, roll: true));
      expect(roll58[0], closeTo(58 * PdfPageFormat.mm, 0.5));
    });
  });

  testWidgets('long reports run over several pages and every report builder works', (tester) async {
    await tester.runAsync(() async {
      final r = await newRepo();
      final rows = [for (var i = 0; i < 120; i++) [for (var c = 0; c < 4; c++) 'ردیف $i ستون $c']];
      final long = ReportDoc(title: 'طولانی', tables: [ReportTable(headers: const ['الف', 'ب', 'ج', 'د'], rows: rows)]);
      expect(pageCount(await PdfDocs(r).report(long)), greaterThan(1));

      // The builders only map data; make sure they render without throwing.
      await r.saveAccount(name: 'بانک', kind: 'bank', opening: 100);
      await r.saveParty(name: 'شخص', phone: '0912');
      await r.saveProduct(name: 'کالا', salePrice: 10, buyPrice: 5, openingStock: 3, minStock: 5);
      await r.saveCheque(kind: 'received', number: '1', bank: 'ملی', amount: 50, dueDate: '2025-01-01');
      final acc = (await r.accounts()).single;
      final party = (await r.parties()).single;
      final prod = (await r.products()).single;
      await r.saveTx(date: '2025-01-01', kind: 'receipt', amount: 10, accountId: acc.id, partyId: party.id, description: 'x');
      await r.saveInvoice(number: 1, kind: 'sale', date: '2025-01-02', partyId: party.id, discount: 0, note: '',
          items: [InvoiceItem('کالا', 1, 10, productId: prod.id)]);
      final names = {party.id: party.name};
      final docs = [
        monthlyDoc(await r.report('2025-01-01', '2025-02-01'), 'دی'),
        productSalesDoc(await r.productSales('2025-01-01', '2025-02-01'), await r.products(), 'دی'),
        partyBalancesDoc(await r.parties()),
        buyersDoc(prod, await r.productSalesByParty(prod.id), 'کل دوران'),
        transactionsDoc(await r.transactions(), accounts: {acc.id: acc.name}, parties: names, categories: {}),
        invoicesDoc(await r.invoices(), names),
        stockDoc(await r.products()),
        chequesDoc(await r.cheques(), names, title: 'چک‌ها'),
        accountsDoc(await r.accounts()),
      ];
      for (final d in docs) {
        expect((await PdfDocs(r).report(d)).length, greaterThan(500), reason: d.title);
      }
      expect((await PdfDocs(r).statement(party, from: '2025-01-02', toExclusive: '2025-02-01', periodLabel: 'دی')).length, greaterThan(500));
    });
  });
}
