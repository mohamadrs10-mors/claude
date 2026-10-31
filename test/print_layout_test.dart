import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/print/delivery_doc.dart';
import 'package:simple_accounting/print/order_docs.dart';
import 'package:simple_accounting/print/pdf_docs.dart';
import 'package:simple_accounting/print/print_layout.dart';
import 'package:simple_accounting/print/report_doc.dart';
import 'package:simple_accounting/ui/print_layout_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_pl');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

int pages(List<int> pdf) => RegExp(r'/Type\s*/Page(?![a-zA-Z])').allMatches(String.fromCharCodes(pdf)).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('layout: defaults, switching parts, margins, reset, and it survives a restart', () async {
    var l = const PrintLayout();
    expect(l.shows('invoice', 'logo'), isTrue);
    expect(l.shows('invoice', 'qr'), isFalse); // the QR code is off unless asked for
    expect(l.explicit('invoice', 'logo'), isNull);
    expect(l.margins('invoice'), isNull);
    l = l.withShow('invoice', 'logo', false).withShow('invoice', 'qr', true).withMargins('invoice', [5, null, 20, 70]);
    expect((l.shows('invoice', 'logo'), l.shows('invoice', 'qr'), l.shows('order', 'logo')), (false, true, true)); // other kinds untouched
    expect(l.margins('invoice'), [5.0, null, 20.0, 60.0]); // a margin is capped at 60 mm
    expect(l.isCustom('invoice'), isTrue);

    final prefs = DevicePrefs.memory();
    await l.save(prefs);
    final back = PrintLayout.fromPrefs(prefs);
    expect(back.shows('invoice', 'logo'), isFalse);
    expect(back.margins('invoice'), [5.0, null, 20.0, 60.0]);
    await prefs.set('print_layout', '{not json');
    expect(PrintLayout.fromPrefs(prefs).isCustom('invoice'), isFalse); // a damaged value resets

    expect(l.reset('invoice').isCustom('invoice'), isFalse);
    expect(l.withMargins('invoice', [null, null, null, null]).margins('invoice'), isNull);
    expect(printKinds.map((k) => k.id), containsAll(['invoice', 'roll', 'order', 'draft', 'delivery', 'statement', 'report']));
  });

  test('order printout follows the layout: row numbers, words, cheques, delivery date, phone', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single.id;
    await r.saveParty(name: 'علی', phone: '09121234567');
    final ali = (await r.parties()).single;
    final oid = await r.saveOrder(number: 1, date: '2025-03-01', partyId: ali.id, items: [OrderItem('برنج', 10, 1000)], percent: 50, advance: 3000, accountId: acc, deliveryDate: '2025-03-20', cheques: [ChequeDraft(amount: 2000, dueDate: '2025-04-01')]);
    final o = (await r.orders()).single;
    expect(oid, o.id);
    final cheques = await r.cheques();
    final full = orderDoc(o, ali, cheques, const {});
    expect(full.kind, 'order');
    expect(full.tables.first.headers.length, 5);
    expect(full.tables.first.caption, isNotEmpty);
    expect(full.tables.length, 2);
    expect({for (final (k, _) in full.summary) k}, contains('تاریخ تحویل'));
    expect(full.subtitle, contains('09121234567'.replaceAll('0', '۰').replaceAll('9', '۹').replaceAll('1', '۱').replaceAll('2', '۲').replaceAll('3', '۳').replaceAll('4', '۴').replaceAll('5', '۵').replaceAll('6', '۶').replaceAll('7', '۷')));

    var l = const PrintLayout();
    for (final k in ['rownum', 'words', 'cheques', 'delivery', 'party_phone']) {
      l = l.withShow('order', k, false);
    }
    final slim = orderDoc(o, ali, cheques, const {}, layout: l);
    expect(slim.tables.first.headers.length, 4);
    expect(slim.tables.first.rows.every((row) => row.length == 4), isTrue);
    expect(slim.tables.first.totals!.length, 4);
    expect(slim.tables.first.caption, '');
    expect(slim.tables.length, 1);
    expect({for (final (k, _) in slim.summary) k}, isNot(contains('تاریخ تحویل')));
    expect(slim.subtitle, isNot(contains('۰۹۱۲')));
  });

  test('every printout still prints with its parts switched off, and its own margins change the pages', () async {
    final r = await newRepo();
    await r.saveParty(name: 'مشتری', phone: '0912');
    final party = (await r.parties()).single;
    final long = [for (var i = 1; i <= 40; i++) InvoiceItem('کالای $i', 1, 1000)];
    await r.saveInvoice(number: 1, kind: 'sale', date: '2025-03-01', partyId: party.id, discount: 0, note: 'یادداشت', items: long);
    final inv = (await r.invoices()).single;
    final off = [for (final k in printKinds) for (final e in k.elements) (k.id, e.key)];
    var l = const PrintLayout();
    for (final (k, e) in off) {
      l = l.withShow(k, e, false);
    }
    final delivery = DeliveryDoc(number: '1', date: '2025-03-01', partyName: 'x', phone: '1', address: 'a', note: 'n', lines: [('کالا', 1, 'عدد')]);
    final report = ReportDoc(title: 't', subtitle: 's', summary: [('a', 'b')], tables: [ReportTable(headers: const ['h'], rows: const [['x']])], footnote: 'f');
    for (final layout in [const PrintLayout(), l]) {
      final d = PdfDocs(r, layout: layout);
      for (final bytes in [
        await d.invoice(inv, long, party),
        await d.invoice(inv, long, party, roll: true),
        await d.invoice(inv, long, party, template: 'modern'),
        await d.delivery(delivery),
        await d.report(report),
        await d.report(ReportDoc(kind: 'statement', title: 't', tables: const [])),
      ]) {
        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      }
    }
    // Wider margins of the invoice alone leave less room: more pages; the other kinds keep the old margin.
    final narrow = PdfDocs(r, layout: const PrintLayout().withMargins('invoice', [5, 5, 5, 5]));
    final wide = PdfDocs(r, layout: const PrintLayout().withMargins('invoice', [50, 40, 50, 40]));
    expect(pages(await wide.invoice(inv, long, party)), greaterThan(pages(await narrow.invoice(inv, long, party))));
    expect(pages(await wide.report(report)), pages(await narrow.report(report))); // reports unaffected
  });

  testWidgets('the layout page: switching a part and typing margins are saved for that kind only; reset clears them', (tester) async {
    tester.view.physicalSize = const Size(1000, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sqfliteFfiInit();
    late Repo repo;
    await tester.runAsync(() async => repo = await newRepo());
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: PrintLayoutPage(repo: repo))));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('پیش‌نویس سفارش'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    // The closing line is on by default; switch it off.
    final closing = find.widgetWithText(SwitchListTile, 'جملهٔ پایانی (اعتبار قیمت‌ها)');
    expect(tester.widget<SwitchListTile>(closing).value, isTrue);
    await tester.tap(closing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.printLayout.shows('draft', 'closing'), isFalse);
    expect(repo.printLayout.shows('order', 'closing'), isTrue);
    expect(repo.printLayout.isCustom('order'), isFalse);
    // Margins: only the typed sides are kept.
    await tester.enterText(find.widgetWithText(TextField, 'بالا').first, '30');
    await tester.enterText(find.widgetWithText(TextField, 'چپ').first, '8.5');
    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.printLayout.margins('draft'), [30.0, null, null, 8.5]);
    // Reset.
    await tester.tap(find.text('بازنشانی به حالت اولیه'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.printLayout.isCustom('draft'), isFalse);
    expect(repo.printLayout.margins('draft'), isNull);
  });
}
