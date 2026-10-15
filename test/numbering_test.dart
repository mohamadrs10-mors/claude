import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/sync/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_num');
  final store = await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi);
  return Repo(store);
}

Future<String> party(Repo r, String name) async {
  await r.saveParty(name: name);
  return (await r.parties()).firstWhere((p) => p.name == name).id;
}

Future<String> sale(Repo r, String partyId, int number, {String kind = 'sale'}) => r.saveInvoice(
    number: number, kind: kind, date: '2025-01-01', partyId: partyId, discount: 0, note: '',
    items: [InvoiceItem('کالا', 1, 1000)]);

void main() {
  test('a new document never takes a number that is already used', () async {
    final r = await newRepo();
    final p = await party(r, 'علی');
    await sale(r, p, 1);
    await sale(r, p, 1); // stale number from a form opened earlier
    await sale(r, p, 5); // free: kept as typed
    final nums = (await r.invoices()).map((i) => i.number).toList()..sort();
    expect(nums, [1, 2, 5]);
    // pro-formas have their own series
    await sale(r, p, 1, kind: 'proforma');
    expect((await r.invoices()).where((i) => i.kind == 'proforma').single.number, 1);
    // editing keeps the number
    final id = (await r.invoices()).firstWhere((i) => i.number == 2).id;
    await sale2(r, p, id, 2);
    expect((await r.invoices()).where((i) => i.number == 2).length, 1);
  });

  test('invoices numbered on two devices get distinct numbers after sync', () async {
    final a = await newRepo(), b = await newRepo();
    a.companyId = b.companyId = 'c1';
    final sa = SyncService(CompanyManager.forRepos({'c1': a}, DevicePrefs.memory()));
    final sb = SyncService(CompanyManager.forRepos({'c1': b}, DevicePrefs.memory()));
    await sb.startServer(port: 0);
    await sa.setPairCode('1');
    await sb.setPairCode('1');
    try {
      final pa = await party(a, 'علی');
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      final pb = (await b.parties()).single.id;
      expect(pb, pa);

      // both go offline and issue "invoice 1" and a delivery/order no. 1
      final ia = await sale(a, pa, await a.nextInvoiceNumber());
      final ib = await sale(b, pb, await b.nextInvoiceNumber());
      await a.saveDelivery(number: 1, date: '2025-01-01', items: [DeliveryItem('x', 1)]);
      await b.saveDelivery(number: 1, date: '2025-01-01', items: [DeliveryItem('y', 1)]);

      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      for (final r in [a, b]) {
        final inv = await r.invoices();
        expect(inv.map((i) => i.number).toSet(), {1, 2}, reason: 'both sides agree');
        expect((await r.deliveries()).map((d) => d.number).toSet(), {1, 2});
      }
      // the invoice already on the coordinating device (b) kept its number
      expect((await b.invoices()).firstWhere((i) => i.id == ib).number, 1);
      expect((await a.invoices()).firstWhere((i) => i.id == ia).number, 2);
      // a second sync changes nothing
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      expect((await a.invoices()).map((i) => i.number).toSet(), {1, 2});
    } finally {
      await sb.stopServer();
    }
  });
}

Future<String> sale2(Repo r, String p, String id, int number) => r.saveInvoice(
    id: id, number: number, kind: 'sale', date: '2025-01-02', partyId: p, discount: 0, note: 'x',
    items: [InvoiceItem('کالا', 2, 1000)]);
