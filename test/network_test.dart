import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/access.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/remote_db.dart';
import 'package:simple_accounting/data/remote_session.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/data/sessions.dart';
import 'package:simple_accounting/data/users.dart';
import 'package:simple_accounting/sync/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

late Repo serverRepo;
late UserStore users;
late SyncService server;
late SessionManager sessions;
late DateTime now;
late DevicePrefs serverPrefs;

Future<DevicePrefs> device(String uid) async {
  final p = DevicePrefs.memory();
  await p.set('device_uid', uid);
  return p;
}

Future<RemoteSession> login(String user, String pass, {String uid = 'dev-A', String name = 'سیستم A', String company = 'c1', int? port, String? code}) async {
  final prefs = await device(uid);
  final s = await RemoteSession.login(
      host: '127.0.0.1', port: port ?? server.port!, code: code ?? '1234', companyId: company, username: user, password: pass, prefs: prefs, deviceName: name);
  return s;
}

void main() {
  setUp(() async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('acc_net');
    serverRepo = Repo(await AppDb.open(path: '${dir.path}/s${_n++}.db', factory: databaseFactoryFfi));
    serverRepo.companyId = 'c1';
    await serverRepo.init();
    users = UserStore(serverRepo.store);
    serverPrefs = DevicePrefs.memory();
    await serverPrefs.set('net_mode', 'server');
    now = DateTime(2025, 1, 1, 10);
    sessions = SessionManager(ttl: const Duration(seconds: 30), clock: () => now);
    server = SyncService(CompanyManager.forRepos({'c1': serverRepo}, serverPrefs), sessions: sessions);
    await server.setPairCode('1234');
    await server.startServer(port: 0);
  });

  tearDown(() async {
    await server.stopServer();
  });

  Future<void> seedUsers() async {
    await users.enable(username: 'admin', password: 'admin1', fullName: 'مدیر');
    await users.saveUser(username: 'sara', password: 'sara12', roleId: 'seller', fullName: 'سارا');
    await users.saveUser(username: 'vik', password: 'vik123', roleId: 'viewer');
  }

  test('connecting: the code is checked, companies are listed, signing in needs a user that exists', () async {
    await expectLater(RemoteSession.companies('127.0.0.1', server.port!, 'wrong'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'bad_code')));
    var list = await RemoteSession.companies('127.0.0.1', server.port!, '1234');
    expect((list.single.id, list.single.usersEnabled), ('c1', false));
    // No users yet: the network cannot be used for this company.
    await expectLater(login('admin', 'admin1'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'no_users')));
    await seedUsers();
    list = await RemoteSession.companies('127.0.0.1', server.port!, '1234');
    expect(list.single.usersEnabled, isTrue);
    await expectLater(login('admin', 'nope'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'bad_credentials')));
    await expectLater(login('admin', 'admin1', code: 'x'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'bad_code')));
    await expectLater(login('admin', 'admin1', company: 'zzz'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'no_company')));
    final s = await login('admin', 'admin1');
    expect((s.username, s.roleName, s.companyName), ('admin', 'مدیر کل', 'c1'));
    expect(s.access.can(permUsers), isTrue);
    await s.logout();
  });

  test('repeated wrong passwords lock the account for a moment', () async {
    await seedUsers();
    for (var i = 0; i < 5; i++) {
      await expectLater(login('sara', 'bad$i'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'bad_credentials')));
    }
    await expectLater(login('sara', 'sara12'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'locked')));
  });

  test('a client works on the server data through the ordinary Repo, including invoices (transactions) and reports', () async {
    await seedUsers();
    final s = await login('admin', 'admin1');
    final r = s.repo;
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 1000);
    await r.saveParty(name: 'مشتری');
    await r.saveProduct(name: 'برنج', openingStock: 100, salePrice: 50);
    final party = (await r.parties()).single;
    final prod = (await r.products()).single;
    final acc = (await r.accounts()).single;
    await r.saveInvoice(number: 1, kind: 'sale', date: '2025-01-01', partyId: party.id, discount: 0, note: '', items: [InvoiceItem('برنج', 10, 50, productId: prod.id)]);
    await r.saveTx(date: '2025-01-02', kind: 'receipt', amount: 200, accountId: acc.id, partyId: party.id);
    // The server's own repo sees exactly the same data.
    expect((await serverRepo.parties()).single.balance, 300);
    expect((await serverRepo.accounts()).single.balance, 1200);
    expect((await serverRepo.products()).single.stock, 90);
    // And the client reads the computed figures too.
    expect((await r.parties()).single.balance, 300);
    final fp = await r.financialPosition();
    expect(fp.cash, 1200);
    final ledger = await r.partyLedger(party.id);
    expect(ledger.rows.length, 2);
    // An order with an advance (its own multi-statement transaction).
    await r.saveOrder(number: 1, date: '2025-01-03', partyId: party.id, percent: 50, advance: 100, accountId: acc.id, items: [OrderItem('برنج', 4, 50, productId: prod.id)]);
    expect((await serverRepo.orders()).single.cash, 100);
    expect((await serverRepo.accounts()).single.balance, 1300);
    await s.logout();
  });

  test('a transaction is all or nothing, also across the network', () async {
    await seedUsers();
    final s = await login('admin', 'admin1');
    final db = s.repo.store.db;
    await expectLater(
        db.transaction((tx) async {
          await tx.insert('categories', {'id': 'k1', 'updated_at': 1, 'deleted': 0, 'device_id': 'd', 'seq': 1, 'name': 'الف', 'kind': 'income'});
          await tx.insert('categories', {'id': 'k1', 'updated_at': 1, 'deleted': 0, 'device_id': 'd', 'seq': 2, 'name': 'تکراری', 'kind': 'income'}); // same key
        }),
        throwsA(isA<NetException>()));
    expect(await serverRepo.categories(), isEmpty);
    // The server is not left blocked by the failed transaction.
    await s.repo.saveCategory(name: 'ب', kind: 'income');
    expect((await serverRepo.categories()).length, 1);
    await s.logout();
  });

  test('roles are enforced on the server: a viewer cannot write, a seller cannot touch accounts, nobody reads the user table', () async {
    await seedUsers();
    final admin = await login('admin', 'admin1');
    await admin.repo.saveParty(name: 'علی');
    final partyId = (await admin.repo.parties()).single.id;

    final viewer = await login('vik', 'vik123', uid: 'dev-V', name: 'سیستم V');
    expect((await viewer.repo.parties()).single.name, 'علی'); // may look
    await expectLater(viewer.repo.saveParty(name: 'رضا'), throwsA(isA<AccessDenied>()));
    await expectLater(viewer.repo.saveInvoice(number: 1, kind: 'sale', date: '2025-01-01', partyId: partyId, discount: 0, note: '', items: [InvoiceItem('x', 1, 1)]), throwsA(isA<AccessDenied>()));
    await expectLater(viewer.repo.store.db.query('users'), throwsA(isA<AccessDenied>()));
    expect((await serverRepo.parties()).length, 1);

    final seller = await login('sara', 'sara12', uid: 'dev-S', name: 'سیستم S');
    await seller.repo.saveInvoice(number: 1, kind: 'sale', date: '2025-01-01', partyId: partyId, discount: 0, note: '', items: [InvoiceItem('x', 1, 10)]);
    await expectLater(seller.repo.saveAccount(name: 'x', kind: 'cash', opening: 0), throwsA(isA<AccessDenied>()));
    await expectLater(seller.repo.saveProduct(name: 'x'), throwsA(isA<AccessDenied>()));
    expect((await serverRepo.invoices()).length, 1);
    expect(await serverRepo.accounts(), isEmpty);
    // A forbidden statement inside a transaction rolls the whole transaction back.
    await expectLater(
        seller.repo.store.db.transaction((tx) async {
          await tx.insert('categories', {'id': 'q', 'updated_at': 1, 'deleted': 0, 'device_id': 'd', 'seq': 1, 'name': 'x', 'kind': 'income'});
        }),
        throwsA(isA<AccessDenied>()));
    expect(await serverRepo.categories(), isEmpty);
    // Only managers may administer users.
    await expectLater(seller.admin.users(), throwsA(isA<AccessDenied>()));
    for (final s in [admin, viewer, seller]) {
      await s.logout();
    }
  });

  test('a user can be signed in on one system at a time', () async {
    await seedUsers();
    final a = await login('sara', 'sara12', uid: 'dev-A', name: 'صندوق ۱');
    // From another system: refused, and told where.
    await expectLater(
        login('sara', 'sara12', uid: 'dev-B', name: 'صندوق ۲'),
        throwsA(isA<NetException>().having((e) => e.code, 'code', 'already_active').having((e) => e.extra['device'], 'device', 'صندوق ۱')));
    // Another user is not affected.
    final other = await login('vik', 'vik123', uid: 'dev-B', name: 'صندوق ۲');
    // The same system signing in again (app restarted) replaces its own old session.
    final again = await login('sara', 'sara12', uid: 'dev-A', name: 'صندوق ۱');
    await a.beat();
    expect(a.endedReason, 'replaced');
    // Signing out frees the user for another system.
    await again.logout();
    final b = await login('sara', 'sara12', uid: 'dev-B', name: 'صندوق ۲');
    expect(b.username, 'sara');
    await b.logout();
    await other.logout();
  });

  test('a system that stops answering frees its user after a while; a living one keeps them', () async {
    await seedUsers();
    final a = await login('sara', 'sara12', uid: 'dev-A', name: 'A');
    now = now.add(const Duration(seconds: 20));
    await a.beat(); // heartbeat keeps the session alive
    now = now.add(const Duration(seconds: 20));
    await expectLater(login('sara', 'sara12', uid: 'dev-B', name: 'B'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'already_active')));
    now = now.add(const Duration(seconds: 40)); // silence for longer than the allowed time
    final b = await login('sara', 'sara12', uid: 'dev-B', name: 'B');
    await a.beat();
    expect(a.ended, isTrue);
    expect(a.endedReason, 'expired');
    await b.logout();
  });

  test('clients notice changes made by others and new permissions', () async {
    await seedUsers();
    final a = await login('admin', 'admin1', uid: 'dev-A');
    final b = await login('sara', 'sara12', uid: 'dev-B');
    var refreshes = 0;
    a.repo.addListener(() => refreshes++);
    await a.beat();
    final before = refreshes;
    await b.repo.saveParty(name: 'تازه'); // someone else writes
    await a.beat();
    expect(refreshes, greaterThan(before));
    expect((await a.repo.parties()).single.name, 'تازه');
    final settled = refreshes;
    await a.beat(); // nothing new: no needless refresh
    expect(refreshes, settled);

    // The administrator gives sara another role: her permissions follow at the next heartbeat.
    final sara = (await a.admin.users()).firstWhere((u) => u.username == 'sara');
    expect(sara.online, isTrue);
    expect(sara.device, isNotEmpty);
    await a.admin.saveUser(id: sara.id, username: 'sara', roleId: 'viewer');
    await b.beat();
    expect(b.access.canEdit('invoices'), isFalse);
    await expectLater(b.repo.saveParty(name: 'نه'), throwsA(isA<AccessDenied>()));
    await a.logout();
    await b.logout();
  });

  test('an administrator manages users remotely, can sign someone out, and deactivating ends their session', () async {
    await seedUsers();
    final admin = await login('admin', 'admin1', uid: 'dev-A');
    final sara = await login('sara', 'sara12', uid: 'dev-B');
    final me = admin.admin;
    final newId = await me.saveUser(username: 'ali', password: 'ali123', roleId: 'storekeeper', fullName: 'علی');
    expect((await me.users()).map((u) => u.username), containsAll(['admin', 'sara', 'vik', 'ali']));
    final rid = await me.saveRole(name: 'فقط چک', perms: {'cheques.view'});
    expect((await me.roles()).any((r) => r.id == rid && r.perms.length == 1), isTrue);
    expect((await me.sessions()).map((s) => s.username).toSet(), {'admin', 'sara'});
    // The last manager cannot be removed or demoted.
    final adminId = (await me.users()).firstWhere((u) => u.username == 'admin').id;
    await expectLater(me.deleteUser(adminId), throwsA(isA<NetException>()));
    await expectLater(me.saveUser(id: adminId, username: 'admin', roleId: 'viewer'), throwsA(isA<NetException>()));

    await me.kick((await me.users()).firstWhere((u) => u.username == 'sara').id);
    await sara.beat();
    expect(sara.endedReason, 'kicked');
    await expectLater(sara.repo.parties(), throwsA(isA<SessionEnded>()));
    // She can sign in again afterwards.
    final sara2 = await login('sara', 'sara12', uid: 'dev-B');
    await me.saveUser(id: (await me.users()).firstWhere((u) => u.username == 'sara').id, username: 'sara', roleId: 'seller', active: false);
    await sara2.beat();
    expect(sara2.endedReason, 'removed');
    await expectLater(login('sara', 'sara12', uid: 'dev-C'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'bad_credentials')));
    await me.deleteUser(newId);
    await admin.logout();
  });

  test('the network is closed unless this device is set up as a server', () async {
    await seedUsers();
    await serverPrefs.set('net_mode', 'standalone');
    await expectLater(RemoteSession.companies('127.0.0.1', server.port!, '1234'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'server_off')));
    await expectLater(login('admin', 'admin1'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'server_off')));
    // The ordinary peer synchronisation is not affected.
    expect(server.serverRunning, isTrue);
  });
}
