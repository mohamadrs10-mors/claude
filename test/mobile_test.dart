import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/access.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/guard.dart';
import 'package:simple_accounting/data/remote_db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/data/sessions.dart';
import 'package:simple_accounting/data/users.dart';
import 'package:simple_accounting/sync/mobile_sync.dart';
import 'package:simple_accounting/sync/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_mob');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  r.companyId = 'c1';
  await r.init();
  return r;
}

Future<String> sale(Repo r, String party, String date, {int price = 100, int number = 1, String? id}) =>
    r.saveInvoice(id: id, number: number, kind: 'sale', date: date, partyId: party, discount: 0, note: '', items: [InvoiceItem('کالا', 1, price)]);

void main() {
  late Repo server, phone;
  late UserStore users;
  late SyncService svc;
  late MobileController mobile;

  setUp(() async {
    server = await newRepo();
    phone = await newRepo();
    users = UserStore(server.store);
    final prefs = DevicePrefs.memory();
    await prefs.set('net_mode', 'server');
    svc = SyncService(CompanyManager.forRepos({'c1': server}, prefs), sessions: SessionManager());
    await svc.setPairCode('1234');
    await svc.startServer(port: 0);
    await users.enable(username: 'admin', password: 'admin1', fullName: 'مدیر');
    await users.saveUser(username: 'sara', password: 'sara12', roleId: 'seller', fullName: 'سارا');
    await users.saveUser(username: 'vik', password: 'vik123', roleId: 'viewer');
    final mp = DevicePrefs.memory();
    mobile = MobileController(mp);
    await mobile.save(host: '127.0.0.1', port: svc.port!, code: '1234', companyId: 'c1', username: 'sara');
  });

  tearDown(() async {
    await svc.stopServer();
  });

  test('the phone downloads everything, works offline, and its invoices reach the server with proper numbers', () async {
    await server.saveParty(name: 'علی');
    final ali = (await server.parties()).single.id;
    await sale(server, ali, '2025-03-01', number: 1);

    final r1 = await mobile.sync(phone, password: 'sara12');
    expect(r1.received, greaterThan(0));
    expect((await phone.invoices()).length, 1);
    expect((await phone.parties()).single.name, 'علی');
    expect(mobile.profile!.display, 'سارا');
    expect(mobile.lastSync, isNotNull);
    expect(await mobile.pending(phone), 0);

    // The phone only changes invoices and customers.
    phone.store.setAccess(mobile.profile!.access);
    await expectLater(phone.saveAccount(name: 'x', kind: 'cash', opening: 0), throwsA(isA<AccessDenied>()));
    await expectLater(phone.saveTx(date: '2025-03-02', kind: 'receipt', amount: 1, accountId: 'zz'), throwsA(isA<AccessDenied>()));

    // Offline: the phone makes a customer and an invoice numbered 2 ...
    await phone.saveParty(name: 'مشتری موبایل');
    final newParty = (await phone.parties()).firstWhere((p) => p.name == 'مشتری موبایل').id;
    final onPhone = await sale(phone, newParty, '2025-03-05', number: await phone.nextInvoiceNumber(), price: 700);
    expect((await phone.invoices()).firstWhere((i) => i.id == onPhone).number, 2);
    expect(await mobile.pending(phone), greaterThan(0));
    // ... while the office also issued an invoice 2.
    final onServer = await sale(server, ali, '2025-03-05', number: await server.nextInvoiceNumber(), price: 50);
    expect((await server.invoices()).firstWhere((i) => i.id == onServer).number, 2);

    final r2 = await mobile.sync(phone);
    expect(r2.sent, greaterThan(0));
    expect(r2.rejected, isEmpty);
    expect(r2.renumbered, 1);
    // The server keeps its own number; the phone's invoice got the next free one - on both sides.
    for (final repo in [server, phone]) {
      final inv = await repo.invoices();
      expect(inv.length, 3);
      expect(inv.firstWhere((i) => i.id == onServer).number, 2);
      expect(inv.firstWhere((i) => i.id == onPhone).number, 3);
    }
    expect((await server.parties()).map((p) => p.name), contains('مشتری موبایل'));
    expect(await mobile.pending(phone), 0);
    // The server sees the invoice as Sara's, from the phone.
    final log = await readAudit(server.store.raw, userId: (await users.users()).firstWhere((u) => u.username == 'sara').id);
    expect(log.any((e) => e.table == 'invoices' && e.action == 'create' && e.summary.contains('از موبایل')), isTrue);
    expect(log.any((e) => e.action == 'sync'), isTrue);
  });

  test('closed periods and missing rights are refused by the server and reported to the phone', () async {
    await server.saveParty(name: 'علی');
    final ali = (await server.parties()).single.id;
    final old = await sale(server, ali, '2025-02-01', number: 1);
    await mobile.sync(phone, password: 'sara12');
    await server.setSetting(lockSettingKey, '2025-03-01'); // the books are closed on the server

    await sale(phone, ali, '2025-02-01', id: old, price: 999, number: 1); // edit of an old invoice
    await sale(phone, ali, '2025-01-15', number: 5); // new invoice in the closed period
    await sale(phone, ali, '2025-03-10', number: 6); // fine
    final r = await mobile.sync(phone);
    expect(r.rejected.length, 2);
    expect(r.rejected.every((x) => x.reason.contains('بسته')), isTrue);
    final onServer = await server.invoices();
    expect(onServer.length, 2);
    expect(onServer.firstWhere((i) => i.id == old).total, 100); // unchanged
    expect(onServer.any((i) => i.date == '2025-03-10'), isTrue);

    // A user who may not enter invoices can download but not upload.
    final viewer = MobileController(DevicePrefs.memory());
    await viewer.save(host: '127.0.0.1', port: svc.port!, code: '1234', companyId: 'c1', username: 'vik');
    final other = await newRepo();
    await viewer.sync(other, password: 'vik123');
    expect((await other.invoices()).length, 2);
    await sale(other, ali, '2025-04-01', number: 9);
    final r2 = await viewer.sync(other);
    expect(r2.rejected.length, greaterThanOrEqualTo(1));
    expect((await server.invoices()).length, 2);
  });

  test('wrong password, wrong code and a server that is not a server are refused', () async {
    await expectLater(mobile.sync(phone, password: 'nope'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'bad_credentials')));
    final bad = MobileController(DevicePrefs.memory());
    await bad.save(host: '127.0.0.1', port: svc.port!, code: 'x', companyId: 'c1', username: 'sara');
    await expectLater(bad.sync(phone, password: 'sara12'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'bad_code')));
    await svc.stopServer();
    await expectLater(mobile.sync(phone, password: 'sara12'), throwsA(isA<NetException>().having((e) => e.offline, 'offline', isTrue)));
  });
}
