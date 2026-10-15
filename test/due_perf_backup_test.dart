import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_accounting/data/backup_service.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/util/format.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_dpb');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

void main() {
  test('due dates: unpaid invoices past their date are overdue; paying, pro-formas and no date are not', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single.id;
    await r.saveParty(name: 'علی');
    final p = (await r.parties()).single.id;
    String day(int d) => isoOf(DateTime.now().add(Duration(days: d)));
    Future<String> inv(int n, {String? due, String kind = 'sale'}) =>
        r.saveInvoice(number: n, kind: kind, date: day(-60), partyId: p, discount: 0, note: '', items: [InvoiceItem('x', 1, 1000)], dueDate: due);
    final late = await inv(1, due: day(-10));
    await inv(2, due: day(-5));
    await inv(3, due: day(10)); // not yet
    await inv(4); // no date
    await inv(5, due: day(-10), kind: 'proforma'); // pro-formas never
    final paid = await inv(6, due: day(-30));
    await r.saveTx(date: day(-20), kind: 'receipt', amount: 1000, accountId: acc, partyId: p, invoiceId: paid);

    final over = await r.overdueInvoices();
    expect(over.map((i) => i.number), [1, 2]); // oldest due date first
    expect(over.first.id, late);
    final dash = await r.dashboard();
    expect(dash.overdue.length, 2);
    // Editing keeps the date; clearing it removes the invoice from the list.
    await r.saveInvoice(id: late, number: 1, kind: 'sale', date: day(-60), partyId: p, discount: 0, note: '', items: [InvoiceItem('x', 1, 1000)], dueDate: null);
    expect((await r.overdueInvoices()).length, 1);
    // A pro-formа turned into an invoice starts without a date.
    expect((await r.invoices()).firstWhere((i) => i.number == 5).dueDate, isNull);
  });

  test('a second backup folder gets a copy and is pruned like the first; a bad folder never breaks the backup', () async {
    final dir = Directory.systemTemp.createTempSync('acc_bk');
    final cm = await CompanyManager.open(dir: dir, factory: databaseFactoryFfi);
    final bk = BackupService(cm);
    await cm.prefs.set('backup_keep', '2');
    final extra = Directory(p.join(dir.path, 'cloud'))..createSync();
    await bk.setExtraDir(extra.path);
    final id = cm.activeId;
    for (var i = 1; i <= 3; i++) {
      await bk.backupNow(id, now: DateTime(2025, 1, i, 10));
    }
    final copies = Directory(p.join(extra.path, 'MORS-ACC-backups', id)).listSync().whereType<File>().map((f) => p.basename(f.path)).toList()..sort();
    expect(copies.length, 2);
    expect(copies.last, contains('2025-01-03'));
    expect(bk.lastExtraError, isNull);
    // A folder that cannot be written: the local backup still happens.
    await bk.setExtraDir(p.join(dir.path, 'cloud', 'MORS-ACC-backups', id, 'x.json', 'nope')); // inside a file path
    File(p.join(extra.path, 'blocker')).writeAsStringSync('x');
    await bk.setExtraDir(p.join(extra.path, 'blocker', 'sub'));
    final f = await bk.backupNow(id, now: DateTime(2025, 1, 4, 10));
    expect(f.existsSync(), isTrue);
    expect(bk.lastExtraError, isNotNull);
  });

  test('many documents: lists, balances and the dashboard stay fast', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single.id;
    for (var i = 0; i < 40; i++) {
      await r.saveParty(name: 'شخص $i');
    }
    await r.saveProduct(name: 'کالا', openingStock: 1000000);
    final parties = await r.parties();
    final prod = (await r.products()).single.id;
    // Bulk insert straight into the tables (the ordinary calls would take minutes for this many rows).
    final raw = r.store.raw;
    final now = DateTime.now().millisecondsSinceEpoch;
    await raw.transaction((tx) async {
      final batch = tx.batch();
      for (var i = 0; i < 6000; i++) {
        final id = 'inv$i';
        final party = parties[i % parties.length].id;
        final day = isoOf(DateTime(2025, 1, 1).add(Duration(days: i % 365)));
        batch.insert('invoices', {'id': id, 'updated_at': now, 'deleted': 0, 'device_id': 'd', 'seq': 0, 'number': i + 1, 'kind': 'sale', 'date': day, 'party_id': party, 'discount': 0, 'note': '', 'tax_percent': 0, 'prepaid': 0});
        for (var k = 0; k < 3; k++) {
          batch.insert('invoice_items', {'id': '$id-$k', 'updated_at': now, 'deleted': 0, 'device_id': 'd', 'seq': 0, 'invoice_id': id, 'title': 'کالا', 'qty': 2, 'unit_price': 1000, 'position': k, 'product_id': prod});
        }
        if (i % 2 == 0) {
          batch.insert('transactions', {'id': 'tx$i', 'updated_at': now, 'deleted': 0, 'device_id': 'd', 'seq': 0, 'date': day, 'kind': 'receipt', 'amount': 3000, 'account_id': acc, 'party_id': party, 'invoice_id': id, 'description': ''});
        }
      }
      await batch.commit(noResult: true);
    });
    final sw = Stopwatch()..start();
    final inv = await r.invoices();
    final parts = await r.parties();
    final prods = await r.products();
    final dash = await r.dashboard();
    final ledger = await r.partyLedger(parties.first.id);
    sw.stop();
    // ignore: avoid_print
    print('6000 invoices: loaded everything in ${sw.elapsedMilliseconds} ms');
    expect(inv.length, 6000);
    expect(parts.length, 40);
    expect(prods.single.stock, 1000000 - 6000 * 2 * 3);
    expect(dash.recent.length, greaterThan(0));
    expect(ledger.rows, isNotEmpty);
    expect(sw.elapsedMilliseconds, lessThan(15000));
  });
}
