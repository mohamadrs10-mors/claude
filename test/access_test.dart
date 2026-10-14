import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/access.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/db_ops.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/data/users.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<(Repo, UserStore)> setup() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_users');
  final store = await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi);
  final r = Repo(store);
  await r.init();
  return (r, UserStore(store));
}

Access roleAccess(String id) => Access(presetRoles().firstWhere((r) => r.id == id).perms);

void main() {
  test('roles: presets, what each may write', () {
    final admin = roleAccess('admin');
    expect(admin.can(permUsers) && admin.can(permSettings), isTrue);
    final viewer = roleAccess('viewer');
    expect(viewer.canView('invoices'), isTrue);
    expect(viewer.canEditAnything, isFalse);
    expect(viewer.canWriteTable('invoices'), isFalse);
    final seller = roleAccess('seller');
    expect(seller.canWriteTable('invoices') && seller.canWriteTable('invoice_items'), isTrue);
    expect(seller.canWriteTable('transactions'), isTrue);
    expect(seller.canWriteTable('accounts'), isFalse);
    expect(seller.canWriteTable('products'), isFalse);
    expect(seller.canWriteTable('meta') && seller.canWriteTable('settings'), isTrue); // bookkeeping of every save
    final keeper = roleAccess('storekeeper');
    expect(keeper.canWriteTable('products') && keeper.canWriteTable('deliveries'), isTrue);
    expect(keeper.canWriteTable('invoices'), isFalse);
    // The account tables and unknown tables are never writable through a guarded database.
    for (final t in ['users', 'roles', 'sqlite_master', 'whatever']) {
      expect(admin.canWriteTable(t), isFalse, reason: t);
    }
    expect(const Access.unrestricted().canWriteTable('anything'), isTrue);
    expect(roleAccess('accountant').can(permUsers), isFalse);
  });

  test('users: switch on, sign in, passwords are hashed, names are unique, the last admin stays', () async {
    final (_, us) = await setup();
    expect(await us.enabled(), isFalse);
    final adminId = await us.enable(username: 'Admin', password: 'secret1', fullName: 'مدیر');
    expect(await us.enabled(), isTrue);
    expect((await us.roles()).map((r) => r.id), containsAll(['admin', 'accountant', 'seller', 'storekeeper', 'viewer']));
    await expectLater(us.enable(username: 'x1', password: 'abcd'), throwsA(isA<StateError>()));

    expect((await us.verify('admin', 'secret1'))?.id, adminId); // case-insensitive name
    expect(await us.verify('admin', 'wrong'), isNull);
    expect(await us.verify('nobody', 'secret1'), isNull);
    final raw = await us.store.raw.query('users');
    expect(raw.single['hash'], isNot(contains('secret1')));
    expect(raw.single['hash'], isNot('secret1'));
    expect((await us.accessOf((await us.user(adminId))!)).can(permUsers), isTrue);

    final sid = await us.saveUser(username: 'sara', password: 'pw1234', roleId: 'seller', fullName: 'سارا');
    await expectLater(us.saveUser(username: 'SARA', password: 'pw9999', roleId: 'viewer'), throwsA(isA<StateError>())); // taken
    await expectLater(us.saveUser(username: 'ab', password: '12', roleId: 'viewer'), throwsA(isA<StateError>())); // short password
    await expectLater(us.saveUser(username: 'bad name', password: 'pw9999', roleId: 'viewer'), throwsA(isA<StateError>()));
    // Editing without a password keeps the old one; with one it changes.
    await us.saveUser(id: sid, username: 'sara', roleId: 'seller', fullName: 'سارا ۲');
    expect(await us.verify('sara', 'pw1234'), isNotNull);
    await us.saveUser(id: sid, username: 'sara', roleId: 'seller', password: 'newpass');
    expect(await us.verify('sara', 'pw1234'), isNull);
    expect(await us.verify('sara', 'newpass'), isNotNull);
    // An inactive user cannot sign in.
    await us.saveUser(id: sid, username: 'sara', roleId: 'seller', active: false);
    expect(await us.verify('sara', 'newpass'), isNull);

    // The last active manager cannot be removed, deactivated or demoted.
    await expectLater(us.deleteUser(adminId), throwsA(isA<StateError>()));
    await expectLater(us.saveUser(id: adminId, username: 'admin', roleId: 'viewer'), throwsA(isA<StateError>()));
    await expectLater(us.saveUser(id: adminId, username: 'admin', roleId: 'admin', active: false), throwsA(isA<StateError>()));
    expect((await us.user(adminId))!.roleId, 'admin');
    // Another manager makes it possible.
    final second = await us.saveUser(username: 'boss', password: 'boss12', roleId: 'admin');
    await us.deleteUser(adminId);
    expect((await us.users()).map((u) => u.username), isNot(contains('admin')));
    await expectLater(us.deleteUser(second), throwsA(isA<StateError>()));
  });

  test('roles can be made and changed; a role in use or the admin role cannot be removed', () async {
    final (_, us) = await setup();
    await us.enable(username: 'admin', password: 'secret1');
    final rid = await us.saveRole(name: 'ثبت‌کنندهٔ چک', perms: {'cheques.view', 'cheques.edit', 'bogus.perm'});
    final r = (await us.role(rid))!;
    expect(r.perms, {'cheques.view', 'cheques.edit'}); // unknown keys are dropped
    final uid = await us.saveUser(username: 'cheq', password: 'abcd12', roleId: rid);
    await expectLater(us.deleteRole(rid), throwsA(isA<StateError>()));
    await expectLater(us.deleteRole('admin'), throwsA(isA<StateError>()));
    await us.saveRole(id: rid, name: 'چک', perms: {'cheques.view'});
    expect((await us.accessOf((await us.user(uid))!)).canEdit('cheques'), isFalse);
    // The admin role always keeps every permission, even if someone tries to change it.
    await us.saveRole(id: 'admin', name: 'x', perms: {});
    expect((await us.role('admin'))!.perms, allPermissions.toSet());
    // Removing the permission to manage users from the only manager role is refused.
    final mgr = await us.saveRole(name: 'مدیر دوم', perms: {permUsers, 'invoices.view'});
    await us.saveUser(username: 'm2', password: 'abcd12', roleId: mgr);
    await us.deleteUser((await us.users()).firstWhere((u) => u.username == 'admin').id); // m2 is the only manager now
    await expectLater(us.saveRole(id: mgr, name: 'مدیر دوم', perms: {'invoices.view'}), throwsA(isA<StateError>()));
    await us.deleteUser(uid);
    await us.deleteRole(rid);
  });

  test('guarded database: reads are open, writes follow the role, accounts and schema are closed', () async {
    final (repo, us) = await setup();
    await repo.saveParty(name: 'علی');
    await us.enable(username: 'admin', password: 'secret1');

    final store = repo.store;
    store.setAccess(roleAccess('viewer'));
    expect((await repo.parties()).single.name, 'علی'); // reading works
    await expectLater(repo.saveParty(name: 'رضا'), throwsA(isA<AccessDenied>()));
    await expectLater(repo.saveAccount(name: 'x', kind: 'cash', opening: 0), throwsA(isA<AccessDenied>()));
    expect((await repo.parties()).length, 1);
    // Nothing reaches the users table, not even a read, and no schema changes.
    await expectLater(store.db.query('users'), throwsA(isA<AccessDenied>()));
    await expectLater(store.db.rawQuery('SELECT hash FROM users'), throwsA(isA<AccessDenied>()));
    await expectLater(store.db.rawQuery("SELECT * FROM sqlite_master"), throwsA(isA<AccessDenied>()));
    await expectLater(store.db.execute('DROP TABLE parties'), throwsA(isA<AccessDenied>()));
    // The unrestricted side (sync, backups) is not affected by the guard.
    expect((await store.changesSince(0))['parties']!.length, 1);

    store.setAccess(roleAccess('seller'));
    await repo.saveParty(name: 'رضا'); // sellers may add people
    await expectLater(repo.saveProduct(name: 'برنج'), throwsA(isA<AccessDenied>())); // sellers may not define products
    final p = (await repo.parties()).firstWhere((x) => x.name == 'رضا');
    await repo.saveInvoice(number: 1, kind: 'sale', date: '2025-01-01', partyId: p.id, discount: 0, note: '', items: [InvoiceItem('x', 1, 10)]);
    expect((await repo.invoices()).length, 1);
    // A transaction that includes a forbidden write is rolled back as a whole.
    await expectLater(
        store.db.transaction((tx) async {
          await tx.insert('invoices', {'id': 'zz', 'updated_at': 1, 'deleted': 0, 'device_id': 'd', 'seq': 99, 'number': 2, 'kind': 'sale', 'date': '2025-01-02', 'party_id': p.id, 'discount': 0, 'note': '', 'tax_percent': 0});
          await tx.insert('accounts', {'id': 'aa', 'updated_at': 1, 'deleted': 0, 'device_id': 'd', 'seq': 100, 'name': 'x', 'kind': 'cash', 'opening': 0});
        }),
        throwsA(isA<AccessDenied>()));
    expect((await repo.invoices()).length, 1);

    store.setAccess(null);
    await repo.saveProduct(name: 'برنج'); // free again
    expect((await repo.products()).length, 1);
  });

  test('checkOp understands raw statements', () {
    final seller = roleAccess('seller');
    void ok(Op o) => checkOp(seller, o);
    void no(Op o) => expect(() => checkOp(seller, o), throwsA(isA<AccessDenied>()), reason: o.sql ?? o.table);
    ok(Op('rawQuery', sql: 'SELECT * FROM invoices WHERE number=?', args: [1]));
    ok(Op('rawUpdate', sql: 'UPDATE invoices SET note=? WHERE id=?', args: ['x', 'i']));
    ok(Op('rawInsert', sql: 'INSERT OR REPLACE INTO invoice_items (id) VALUES (?)', args: ['i']));
    ok(Op('rawDelete', sql: '  delete from delivery_items'.replaceFirst('delivery_items', 'invoice_items')));
    no(Op('rawUpdate', sql: 'UPDATE accounts SET name=?', args: ['x']));
    no(Op('rawInsert', sql: 'INSERT INTO users (id) VALUES (1)'));
    no(Op('rawQuery', sql: 'select * from Users'));
    no(Op('execute', sql: 'CREATE TABLE t (a)'));
    no(Op('execute', sql: 'PRAGMA user_version = 1'));
    no(Op('execute', sql: "ATTACH DATABASE 'x' AS y"));
    no(Op('update', table: 'accounts', values: {'name': 'x'}));
    ok(Op('update', table: 'invoices', values: {'note': 'x'}));
  });
}
