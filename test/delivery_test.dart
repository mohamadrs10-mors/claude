import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/print/delivery_doc.dart';
import 'package:simple_accounting/print/pdf_docs.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_dlv');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('delivery receipt without an invoice: saved, edited, numbered, deleted', () async {
    final r = await newRepo();
    expect(await r.nextDeliveryNumber(), 1);
    final id = await r.saveDelivery(
      number: 1,
      date: '2025-03-01',
      recipient: 'آقای رضایی',
      address: 'تهران',
      items: [DeliveryItem('برنج', 5, unit: 'کیسه'), DeliveryItem('روغن', 2, unit: 'گالن')],
    );
    expect(await r.nextDeliveryNumber(), 2);
    final d = (await r.deliveries()).single;
    expect(d.recipient, 'آقای رضایی');
    expect((await r.deliveryItems(id)).map((i) => i.title), ['برنج', 'روغن']);

    // Editing replaces the items, no balance or stock is touched.
    await r.saveDelivery(id: id, number: 1, date: '2025-03-01', recipient: 'آقای رضایی', items: [DeliveryItem('برنج', 7, unit: 'کیسه')]);
    final items = await r.deliveryItems(id);
    expect(items.single.qty, 7);
    expect(await r.parties(), isEmpty);

    await r.deleteDelivery(id);
    expect(await r.deliveries(), isEmpty);
    expect(await r.deliveryItems(id), isEmpty);
  });

  test('delivery receipts sync to the other device and survive a backup', () async {
    final a = await newRepo();
    final b = await newRepo();
    final id = await a.saveDelivery(number: 3, date: '2025-03-02', recipient: 'x', items: [DeliveryItem('کالا', 1)]);
    await b.store.applyRemote(await a.store.changesSince(0));
    expect((await b.deliveries()).single.number, 3);
    expect((await b.deliveryItems(id)).single.title, 'کالا');

    await a.deleteDelivery(id);
    await b.store.applyRemote(await a.store.changesSince(0));
    expect(await b.deliveries(), isEmpty);

    final c = await newRepo();
    await a.saveDelivery(number: 4, date: '2025-03-03', recipient: 'y', items: [DeliveryItem('کالا', 2)]);
    await c.importJson(await a.exportJson());
    expect((await c.deliveries()).single.number, 4);
  });

  test('invoice delivery receipt has the goods and units but no prices; PDF with and without signatures', () async {
    final r = await newRepo();
    await r.saveParty(name: 'مشتری');
    final party = (await r.parties()).single;
    await r.saveProduct(name: 'برنج', unit: 'کیلوگرم', salePrice: 1000, buyPrice: 700, openingStock: 50, minStock: 0);
    final prod = (await r.products()).single;
    await r.saveInvoice(number: 12, kind: 'sale', date: '2025-03-05', partyId: party.id, discount: 0, note: 'ارسال با وانت',
        items: [InvoiceItem('برنج', 10, 123456, productId: prod.id), InvoiceItem('خدمات بسته‌بندی', 1, 5000)]);
    final inv = (await r.invoices()).single;
    final doc = DeliveryDoc.fromInvoice(inv, await r.invoiceItems(inv.id), party, await r.products());
    expect(doc.lines, [('برنج', 10.0, 'کیلوگرم'), ('خدمات بسته‌بندی', 1.0, '')]);
    expect(doc.ref, contains('۱۲'));
    expect(doc.partyLabel, 'مشتری');

    final signed = await PdfDocs(r).delivery(doc, signatures: true);
    final plain = await PdfDocs(r).delivery(doc, signatures: false);
    expect(signed.length, greaterThan(500));
    expect(signed.length, greaterThan(plain.length));

    final standalone = DeliveryDoc.fromDelivery(
        Delivery('i', 1, '2025-03-05', null, 'آقای رضایی', 'تهران', ''), [DeliveryItem('کالا', 2.5, unit: 'متر')], null);
    expect(standalone.partyName, 'آقای رضایی');
    expect((await PdfDocs(r).delivery(standalone)).length, greaterThan(500));
    final out = Platform.environment['DLV_OUT'];
    if (out != null) {
      File('$out/signed.pdf').writeAsBytesSync(signed);
      File('$out/plain.pdf').writeAsBytesSync(plain);
    }
  });
}
