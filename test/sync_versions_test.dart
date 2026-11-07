import 'dart:io';
import 'dart:math';

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
  final dir = Directory.systemTemp.createTempSync('acc_fz');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  r.companyId = 'c1';
  return r;
}

void main() {
  test('two devices edit the same invoice: it ends with the lines of ONE version, the same on both', () async {
    final a = await newRepo(), b = await newRepo();
    final sa = SyncService(CompanyManager.forRepos({'c1': a}, DevicePrefs.memory()));
    final sb = SyncService(CompanyManager.forRepos({'c1': b}, DevicePrefs.memory()));
    await sb.startServer(port: 0);
    await sa.setPairCode('1');
    await sb.setPairCode('1');
    await a.saveParty(name: 'p');
    final party = (await a.parties()).single;
    final id = await a.saveInvoice(number: 1, kind: 'sale', date: '2025-01-01', partyId: party.id, discount: 0, note: '', items: [InvoiceItem('x', 1, 100)]);
    await sa.syncWith(a, '127.0.0.1', port: sb.port!);
    // both edit while apart: A to three lines, B (later) to two other lines
    await a.saveInvoice(id: id, number: 1, kind: 'sale', date: '2025-01-01', partyId: party.id, discount: 0, note: '', items: [InvoiceItem('a1', 1, 100), InvoiceItem('a2', 1, 100), InvoiceItem('a3', 1, 100)]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.saveInvoice(id: id, number: 1, kind: 'sale', date: '2025-01-01', partyId: party.id, discount: 0, note: '', items: [InvoiceItem('b1', 1, 100), InvoiceItem('b2', 1, 100)]);
    await sa.syncWith(a, '127.0.0.1', port: sb.port!);
    await sa.syncWith(a, '127.0.0.1', port: sb.port!);
    await sb.stopServer();
    for (final r in [a, b]) {
      expect([for (final i in await r.invoiceItems(id)) i.title], ['b1', 'b2']);
      expect((await r.invoices()).single.subtotal, 200);
    }
  });

  for (final seed in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]) {
    test('fuzz sync seed $seed: nothing entered is lost or mixed', () async {
      final a = await newRepo(), b = await newRepo();
      final sa = SyncService(CompanyManager.forRepos({'c1': a}, DevicePrefs.memory()));
      final sb = SyncService(CompanyManager.forRepos({'c1': b}, DevicePrefs.memory()));
      await sb.startServer(port: 0);
      await sa.setPairCode('1');
      await sb.setPairCode('1');
      final rnd = Random(seed);
      await a.saveParty(name: 'p');
      final party = (await a.parties()).single;
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      final repos = [a, b];
      var no = 100, ver = 0;
      final versions = <String, List<int>>{}; // invoice id -> versions ever saved
      final created = <String>{};
      final deleted = <String>{};
      final txAmounts = <int>[];
      for (var step = 0; step < 60; step++) {
        final r = repos[rnd.nextInt(2)];
        final op = rnd.nextInt(10);
        if (op < 4) {
          final n = 1 + rnd.nextInt(6);
          final v = ++ver;
          final id = await r.saveInvoice(number: no++, kind: 'sale', date: '2025-01-01', partyId: party.id, discount: 0, note: '', items: [for (var i = 0; i < n; i++) InvoiceItem('v$v-$i', 1, 100)]);
          created.add(id);
          (versions[id] ??= []).add(v);
          itemsOf[v] = n;
        } else if (op < 7 && created.isNotEmpty) {
          // edit an invoice this device already has
          final have = {for (final i in await r.invoices()) i.id};
          final cand = created.where(have.contains).where((x) => !deleted.contains(x)).toList();
          if (cand.isEmpty) continue;
          final id = cand[rnd.nextInt(cand.length)];
          final inv = (await r.invoices()).firstWhere((i) => i.id == id);
          final n = 1 + rnd.nextInt(6);
          final v = ++ver;
          await r.saveInvoice(id: id, number: inv.number, kind: 'sale', date: '2025-01-01', partyId: party.id, discount: 0, note: '', items: [for (var i = 0; i < n; i++) InvoiceItem('v$v-$i', 1, 100)]);
          versions[id]!.add(v);
          itemsOf[v] = n;
        } else if (op < 8) {
          final amt = 1 + rnd.nextInt(1000);
          await r.saveTx(date: '2025-01-02', kind: 'receipt', amount: amt, accountId: (await r.accounts()).isEmpty ? await _acc(r) : (await r.accounts()).first.id, partyId: party.id);
          txAmounts.add(amt);
        } else {
          await sa.syncWith(a, '127.0.0.1', port: sb.port!);
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      for (var k = 0; k < 3; k++) {
        await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      }
      await sb.stopServer();
      // 1. both devices hold the same invoices
      final ia = {for (final i in await a.invoices()) i.id};
      final ib = {for (final i in await b.invoices()) i.id};
      expect(ia, ib, reason: 'devices differ in invoices');
      expect(ia.length, created.length, reason: 'an entered invoice is missing');
      // 2. every invoice has exactly the items of ONE saved version, complete
      for (final id in created) {
        for (final r in repos) {
          final items = await r.invoiceItems(id);
          final vs = {for (final it in items) it.title.split('-').first};
          expect(vs.length, 1, reason: 'invoice $id mixes versions $vs');
          final v = int.parse(vs.single.substring(1));
          expect(items.length, itemsOf[v], reason: 'invoice $id lost items of version $v');
        }
      }
      // 3. all receipts are there
      final sum = (await a.transactions()).where((t) => t.kind == 'receipt').fold<int>(0, (s, t) => s + t.amount);
      expect(sum, txAmounts.fold<int>(0, (s, x) => s + x), reason: 'a receipt is missing');
    });
  }
}

final itemsOf = <int, int>{};
Future<String> _acc(Repo r) async {
  await r.saveAccount(name: 'ص', kind: 'cash', opening: 0);
  return (await r.accounts()).first.id;
}
