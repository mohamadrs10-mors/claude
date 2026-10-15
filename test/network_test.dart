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
import 'package:simple_accounting/data/user_admin.dart';
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

  test('a client reads the server data through the ordinary Repo (invoices, reports) but cannot change anything', () async {
    await seedUsers();
    final r0 = serverRepo;
    await r0.saveAccount(name: 'صندوق', kind: 'cash', opening: 1000);
    await r0.saveParty(name: 'مشتری');
    await r0.saveProduct(name: 'برنج', openingStock: 100, salePrice: 50);
    final party = (await r0.parties()).single;
    final prod = (await r0.products()).single;
    final acc = (await r0.accounts()).single;
    await r0.saveInvoice(number: 1, kind: 'sale', date: '2025-01-01', partyId: party.id, discount: 0, note: '', items: [InvoiceItem('برنج', 10, 50, productId: prod.id)]);
    await r0.saveTx(date: '2025-01-02', kind: 'receipt', amount: 200, accountId: acc.id, partyId: party.id);

    final s = await login('admin', 'admin1');
    final r = s.repo;
    expect((await r.parties()).single.balance, 300);
    expect((await r.accounts()).single.balance, 1200);
    expect((await r.products()).single.stock, 90);
    expect((await r.financialPosition()).cash, 1200);
    expect((await r.partyLedger(party.id)).rows.length, 2);
    // Even the administrator's client may only look: data is entered on the server.
    expect(s.access.canEdit('invoices'), isFalse);
    await expectLater(r.saveParty(name: 'رضا'), throwsA(isA<AccessDenied>()));
    await expectLater(r.saveTx(date: '2025-01-02', kind: 'receipt', amount: 5, accountId: acc.id), throwsA(isA<AccessDenied>()));
    await expectLater(r.saveOrder(number: 1, date: '2025-01-03', partyId: party.id, percent: 50, advance: 100, accountId: acc.id, items: [OrderItem('برنج', 4, 50, productId: prod.id)]), throwsA(isA<AccessDenied>()));
    expect(await serverRepo.orders(), isEmpty);
    expect((await serverRepo.parties()).length, 1);
    await s.logout();
  });

  test('a rejected statement inside a client transaction leaves the server untouched and unblocked', () async {
    await seedUsers();
    final s = await login('admin', 'admin1');
    final db = s.repo.store.db;
    await expectLater(
        db.transaction((tx) async {
          await tx.insert('categories', {'id': 'k1', 'updated_at': 1, 'deleted': 0, 'device_id': 'd', 'seq': 1, 'name': 'الف', 'kind': 'income'});
        }),
        throwsA(isA<AccessDenied>()));
    expect(await serverRepo.categories(), isEmpty);
    await serverRepo.saveCategory(name: 'ب', kind: 'income'); // the server is not left blocked
    expect((await s.repo.categories()).length, 1);
    await s.logout();
  });

  test('the account tables are never readable and a role without a section cannot see it', () async {
    await seedUsers();
    final viewer = await login('vik', 'vik123', uid: 'dev-V', name: 'سیستم V');
    await serverRepo.saveParty(name: 'علی');
    expect((await viewer.repo.parties()).single.name, 'علی');
    await expectLater(viewer.repo.store.db.query('users'), throwsA(isA<AccessDenied>()));
    await expectLater(viewer.repo.store.db.rawQuery('SELECT * FROM roles'), throwsA(isA<AccessDenied>()));
    final seller = await login('sara', 'sara12', uid: 'dev-S', name: 'سیستم S');
    await expectLater(seller.admin.users(), throwsA(isA<AccessDenied>()));
    expect(seller.access.canView('invoices'), isTrue);
    expect(seller.access.canEdit('invoices'), isFalse); // clients only look
    for (final s in [viewer, seller]) {
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
    await serverRepo.saveParty(name: 'تازه'); // someone writes on the server
    await a.beat();
    expect(refreshes, greaterThan(before));
    expect((await a.repo.parties()).single.name, 'تازه');
    final settled = refreshes;
    await a.beat(); // nothing new: no needless refresh
    expect(refreshes, settled);

    // The administrator (on the server) gives sara a narrower role: her permissions follow at the next heartbeat.
    final admin = LocalUserAdmin(users, sessions, 'c1');
    final sara = (await a.admin.users()).firstWhere((u) => u.username == 'sara');
    expect(sara.online, isTrue);
    expect(sara.device, isNotEmpty);
    final rid = await admin.saveRole(name: 'فقط چک', perms: {'cheques.view'});
    await admin.saveUser(id: sara.id, username: 'sara', roleId: rid);
    await b.beat();
    expect(b.access.canView('invoices'), isFalse);
    expect(b.access.canView('cheques'), isTrue);
    await a.logout();
    await b.logout();
  });

  test('a client administrator can look at users, roles and sessions, but changes them on the server only', () async {
    await seedUsers();
    final admin = await login('admin', 'admin1', uid: 'dev-A');
    final sara = await login('sara', 'sara12', uid: 'dev-B');
    final me = admin.admin;
    expect((await me.users()).map((u) => u.username), containsAll(['admin', 'sara', 'vik']));
    expect((await me.roles()).length, greaterThan(3));
    expect((await me.sessions()).map((s) => s.username).toSet(), {'admin', 'sara'});
    await expectLater(me.saveUser(username: 'ali', password: 'ali123', roleId: 'viewer'), throwsA(isA<AccessDenied>()));
    await expectLater(me.kick((await me.users()).firstWhere((u) => u.username == 'sara').id), throwsA(isA<AccessDenied>()));

    final local = LocalUserAdmin(users, sessions, 'c1');
    final saraId = (await local.users()).firstWhere((u) => u.username == 'sara').id;
    // The last manager cannot be removed or demoted.
    final adminId = (await local.users()).firstWhere((u) => u.username == 'admin').id;
    await expectLater(local.deleteUser(adminId), throwsA(isA<StateError>()));
    await local.kick(saraId);
    await sara.beat();
    expect(sara.endedReason, 'kicked');
    await expectLater(sara.repo.parties(), throwsA(isA<SessionEnded>()));
    final sara2 = await login('sara', 'sara12', uid: 'dev-B');
    await local.saveUser(id: saraId, username: 'sara', roleId: 'seller', active: false);
    await sara2.beat();
    expect(sara2.endedReason, 'removed');
    await expectLater(login('sara', 'sara12', uid: 'dev-C'), throwsA(isA<NetException>().having((e) => e.code, 'code', 'bad_credentials')));
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
