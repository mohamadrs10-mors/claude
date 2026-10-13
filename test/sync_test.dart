import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/sync/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

// sqflite shares one instance per path (including ":memory:"), so each repo
// gets its own throw-away file.
Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_test');
  final store = await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi);
  return Repo(store);
}

void main() {
  late Repo a, b;
  late SyncService sa, sb;

  setUp(() async {
    a = await newRepo();
    b = await newRepo();
    a.companyId = 'c1';
    b.companyId = 'c1';
    sa = SyncService(CompanyManager.forRepos({'c1': a}, DevicePrefs.memory()));
    sb = SyncService(CompanyManager.forRepos({'c1': b}, DevicePrefs.memory()));
    await sb.startServer(port: 0); // random free port
    await sa.setPairCode('1234');
    await sb.setPairCode('1234');
  });

  tearDown(() async {
    await sb.stopServer();
  });

  test('accounting balances', () async {
    await a.saveAccount(name: 'صندوق', kind: 'cash', opening: 1000);
    final acc = (await a.accounts()).single;
    await a.saveParty(name: 'علی');
    final party = (await a.parties()).single;
    await a.saveTx(date: '2025-01-01', kind: 'receipt', amount: 500, accountId: acc.id, partyId: party.id);
    await a.saveTx(date: '2025-01-02', kind: 'payment', amount: 200, accountId: acc.id);
    expect((await a.accounts()).single.balance, 1300);
    // We received 500 from him without any invoice -> we owe him 500.
    expect((await a.parties()).single.balance, -500);

    await a.saveInvoice(
        number: 1, kind: 'sale', date: '2025-01-03', partyId: party.id, discount: 100, note: '',
        items: [InvoiceItem('کالا', 2, 1000), InvoiceItem('خدمات', 1.5, 200)]);
    final inv = (await a.invoices()).single;
    expect(inv.subtotal, 2300);
    expect(inv.total, 2200);
    expect((await a.parties()).single.balance, -500 + 2200);

    expect(await a.deleteAccount(acc.id), isNotNull); // has transactions
  });

  test('two-way sync with conflict resolution and deletes', () async {
    final port = sb.port!;
    await a.saveAccount(name: 'بانک', kind: 'bank', opening: 0);
    await b.saveParty(name: 'رضا');

    final r1 = await sa.syncWith(a, '127.0.0.1', port: port);
    expect(r1.sent, 1);
    expect(r1.received, 1);
    expect((await b.accounts()).map((e) => e.name), ['بانک']);
    expect((await a.parties()).map((e) => e.name), ['رضا']);

    // Second sync with no changes moves nothing real.
    final r2 = await sa.syncWith(a, '127.0.0.1', port: port);
    expect(r2.sent + r2.received, 0);
    expect((await b.accounts()).length, 1);

    // Conflict: both edit the same account, B later -> B wins on both sides.
    final id = (await a.accounts()).single.id;
    await a.saveAccount(id: id, name: 'بانک ملی', kind: 'bank', opening: 0);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.saveAccount(id: id, name: 'بانک ملت', kind: 'bank', opening: 0);
    await sa.syncWith(a, '127.0.0.1', port: port);
    expect((await a.accounts()).single.name, 'بانک ملت');
    expect((await b.accounts()).single.name, 'بانک ملت');

    // Delete on A propagates to B.
    await a.deleteAccount(id);
    await sa.syncWith(a, '127.0.0.1', port: port);
    expect(await b.accounts(), isEmpty);
  });

  test('wrong pair code is rejected', () async {
    await sa.setPairCode('9999');
    expect(() => sa.syncWith(a, '127.0.0.1', port: sb.port!), throwsA(isA<SyncException>()));
  });

  test('invoice with items syncs and totals match', () async {
    await a.saveParty(name: 'مشتری');
    final p = (await a.parties()).single;
    await a.saveInvoice(
        number: 1, kind: 'sale', date: '2025-02-01', partyId: p.id, discount: 0, note: '',
        items: [InvoiceItem('x', 3, 700)]);
    await sa.syncWith(a, '127.0.0.1', port: sb.port!);
    expect((await b.invoices()).single.total, 2100);
    expect((await b.parties()).single.balance, 2100);
  });
}
