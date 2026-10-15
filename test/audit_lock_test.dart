import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/access.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/guard.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/data/users.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_audit');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

Future<String> sale(Repo r, String party, String date, {String? id, int price = 100, int number = 1}) => r.saveInvoice(
    id: id, number: number, kind: 'sale', date: date, partyId: party, discount: 0, note: '', items: [InvoiceItem('کالا', 1, price)]);

void main() {
  test('the books can be closed: nothing dated in the closed period can be created, changed or deleted', () async {
    final r = await newRepo();
    await r.saveParty(name: 'علی');
    final p = (await r.parties()).single.id;
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single.id;
    final old = await sale(r, p, '2025-02-10');
    final oldTx = await r.saveTx(date: '2025-02-11', kind: 'receipt', amount: 10, accountId: acc, partyId: p);
    await r.setSetting(lockSettingKey, '2025-03-20');

    await expectLater(sale(r, p, '2025-03-20', number: 2), throwsA(isA<AccessDenied>().having((e) => e.message, 'message', contains('بسته'))));
    await expectLater(sale(r, p, '2025-03-01', number: 2), throwsA(isA<AccessDenied>()));
    await expectLater(sale(r, p, '2025-02-10', id: old, price: 999), throwsA(isA<AccessDenied>())); // editing an old one
    await expectLater(r.deleteInvoice(old), throwsA(isA<AccessDenied>()));
    // Moving a document out of the closed period is not a way around it either.
    await expectLater(sale(r, p, '2025-04-01', id: old), throwsA(isA<AccessDenied>()));
    await expectLater(r.saveTx(date: '2025-03-05', kind: 'payment', amount: 1, accountId: acc), throwsA(isA<AccessDenied>()));
    await expectLater(r.deleteTx(oldTx), throwsA(isA<AccessDenied>()));
    await expectLater(r.saveDelivery(number: 1, date: '2025-01-01', items: [DeliveryItem('x', 1)]), throwsA(isA<AccessDenied>()));
    // Nothing changed.
    expect((await r.invoices()).single.total, 100);
    expect((await r.accounts()).single.balance, 10);

    // After the closing date everything works.
    final fresh = await sale(r, p, '2025-03-21', number: 2);
    await sale(r, p, '2025-03-21', id: fresh, price: 50, number: 2);
    await r.deleteInvoice(fresh);
    // Lifting the lock (or moving it back) frees the old documents.
    await r.setSetting(lockSettingKey, '');
    await sale(r, p, '2025-02-10', id: old, price: 120);
    expect((await r.invoices()).single.total, 120);
  });

  test('the activity log says who created, changed and deleted what, with filters', () async {
    final r = await newRepo();
    final users = UserStore(r.store);
    await users.enable(username: 'admin', password: 'admin1', fullName: 'مدیر');
    await users.saveUser(username: 'sara', password: 'sara12', roleId: 'seller', fullName: 'سارا');
    final sara = (await users.users()).firstWhere((u) => u.username == 'sara');
    final admin = (await users.users()).firstWhere((u) => u.username == 'admin');

    // Admin sets things up.
    r.store.setAccess(await users.accessOf(admin, device: 'سرور'));
    await r.saveParty(name: 'علی');
    final p = (await r.parties()).single.id;
    await logEvent(r.store.raw, await users.accessOf(admin, device: 'سرور'), 'login', summary: 'ورود به برنامه');

    // Sara issues an invoice, edits it, deletes it.
    r.store.setAccess(await users.accessOf(sara, device: 'صندوق ۱'));
    final id = await sale(r, p, '2025-05-01', number: 7);
    await sale(r, p, '2025-05-01', id: id, price: 300, number: 7);
    await r.deleteInvoice(id);

    final all = await readAudit(r.store.raw);
    final saraRows = all.where((e) => e.userName == 'سارا' && e.table == 'invoices').toList().reversed.toList();
    expect(saraRows.map((e) => e.action), ['create', 'edit', 'delete']);
    expect(saraRows.first.summary, contains('فروش'));
    expect(saraRows.first.summary, contains('علی'));
    expect(saraRows.first.device, 'صندوق ۱');
    // Invoice lines are not logged one by one.
    expect(all.any((e) => e.table == 'invoice_items'), isFalse);

    expect((await readAudit(r.store.raw, userId: admin.id)).map((e) => e.action).toSet(), {'create', 'login'});
    expect((await readAudit(r.store.raw, action: 'delete')).single.userName, 'سارا');
    expect((await readAudit(r.store.raw, table: 'parties')).single.summary, contains('علی'));
    expect((await readAudit(r.store.raw, text: 'علی')).length, greaterThanOrEqualTo(2));
    expect(await readAudit(r.store.raw, fromIso: '2999-01-01'), isEmpty);
    // The log cannot be written by hand through the guarded database.
    await expectLater(r.store.db.insert('audit_log', {'at': 1, 'action': 'x'}), throwsA(isA<AccessDenied>()));

    // A change that is rolled back leaves no trace.
    final before = (await readAudit(r.store.raw)).length;
    await expectLater(
        r.store.db.transaction((tx) async {
          await tx.insert('parties', {'id': 'zz', 'updated_at': 1, 'deleted': 0, 'device_id': 'd', 'seq': 1, 'name': 'نباید'});
          throw StateError('stop');
        }),
        throwsA(isA<StateError>()));
    expect((await readAudit(r.store.raw)).length, before);

    // Nobody signed in (users off): the books can still be locked but nothing is logged.
    final plain = await newRepo();
    await plain.saveParty(name: 'x');
    expect(await readAudit(plain.store.raw), isEmpty);
  });
}
