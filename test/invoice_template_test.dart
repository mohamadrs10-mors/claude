import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/print/pdf_docs.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_tpl');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

int pages(List<int> pdf) => RegExp(r'/Type\s*/Page(?![a-zA-Z])').allMatches(String.fromCharCodes(pdf)).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every invoice design prints on A4 and A5, with the options on and off, and long invoices flow over pages', () async {
    final r = await newRepo();
    await r.saveParty(name: 'مشتری');
    final party = (await r.parties()).single;
    final w2 = await r.saveWarehouse(name: 'شعبه');
    final long = [for (var i = 1; i <= 60; i++) InvoiceItem('کالای شمارهٔ $i', i.toDouble(), 1000 * i)];
    await r.saveInvoice(number: 1, kind: 'sale', date: '2025-03-01', partyId: party.id, discount: 500, taxPercent: 9, note: 'توضیحات', items: long, warehouseId: w2);
    final inv = (await r.invoices()).single;
    final short = await r.saveInvoice(number: 2, kind: 'sale', date: '2025-03-02', partyId: party.id, discount: 0, note: '', items: [InvoiceItem('تک', 1, 100)]);
    final shortInv = (await r.invoices()).firstWhere((i) => i.id == short);

    for (final (tpl, _) in PdfDocs.invoiceTemplates) {
      for (final accent in ['green', 'burgundy']) {
        await r.setSetting('invoice_accent', accent);
        for (final off in [false, true]) {
          await r.setSetting('invoice_logo', off ? '0' : '1');
          await r.setSetting('invoice_rownum', off ? '0' : '1');
          await r.setSetting('invoice_signatures', off ? '0' : '1');
          for (final fmt in [PdfPageFormat.a4, PdfPageFormat.a5]) {
            final bytes = await PdfDocs(r).invoice(inv, long, party, format: fmt, template: tpl);
            expect(String.fromCharCodes(bytes.take(4)), '%PDF', reason: '$tpl $accent off=$off');
            expect(pages(bytes), greaterThan(1), reason: '60 lines need more than one page ($tpl)');
            final one = await PdfDocs(r).invoice(shortInv, [InvoiceItem('تک', 1, 100)], party, format: fmt, template: tpl);
            expect(pages(one), 1, reason: '$tpl short');
          }
        }
      }
    }
    // The setting decides when no design is passed in.
    await r.setSetting('invoice_template', 'modern');
    final a = await PdfDocs(r).invoice(shortInv, [InvoiceItem('تک', 1, 100)], party);
    final b = await PdfDocs(r).invoice(shortInv, [InvoiceItem('تک', 1, 100)], party, template: 'classic');
    expect(a.length, isNot(b.length));
    // Roll receipts are unaffected by the design.
    final roll = await PdfDocs(r).invoice(shortInv, [InvoiceItem('تک', 1, 100)], party, roll: true);
    expect(String.fromCharCodes(roll.take(4)), '%PDF');
  });
}
