import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/access.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/expenses_repo.dart';
import 'package:simple_accounting/data/guard.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_exp');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

void main() {
  test('an expense without an invoice or a person: leaves the account, counts as a cost, creates its category', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 10000000);
    final acc = (await r.accounts()).single.id;

    await r.saveExpense(date: '2025-03-25', amount: 3000000, accountId: acc, newCategory: 'اجاره', description: 'اجارهٔ فروردین');
    await r.saveExpense(date: '2025-03-26', amount: 450000, accountId: acc, newCategory: 'قبض برق');
    final rent = (await r.categories()).firstWhere((c) => c.name == 'اجاره');
    expect(rent.kind, 'expense');
    await r.saveExpense(date: '2025-03-28', amount: 3000000, accountId: acc, categoryId: rent.id); // the same category is reused
    expect((await r.categories()).where((c) => c.name == 'اجاره').length, 1);

    expect((await r.accounts()).single.balance, 10000000 - 3000000 - 450000 - 3000000);
    final all = await r.expenses();
    expect(all.length, 3);
    expect(all.first.date, '2025-03-28'); // newest first
    expect((await r.expenses(categoryId: rent.id)).length, 2);
    expect((await r.expenses(from: '2025-03-26', toExclusive: '2025-03-28')).single.amount, 450000);

    final groups = await r.expenseGroups();
    expect(groups.map((g) => (g.name, g.total, g.count)), [('اجاره', 6000000, 2), ('قبض برق', 450000, 1)]);

    // The profit and loss report picks them up by category, with no purchase invoice anywhere.
    final pl = await r.profitLoss('2025-03-01', '2025-04-01');
    expect(pl.expenses, 6450000);
    expect(pl.expensesByCategory.first, ('اجاره', 6000000));

    // Editing and deleting.
    await r.saveExpense(id: all.first.id, date: '2025-03-28', amount: 3200000, accountId: acc, categoryId: rent.id, description: 'با افزایش');
    expect((await r.expenseGroups()).first.total, 6200000);
    await r.deleteTx(all.first.id);
    expect((await r.expenses()).length, 2);

    // Not an expense: a payment to a person or on an invoice, and receipts.
    await r.saveParty(name: 'علی');
    final ali = (await r.parties()).single.id;
    await r.saveTx(date: '2025-03-29', kind: 'payment', amount: 999, accountId: acc, partyId: ali);
    await r.saveTx(date: '2025-03-29', kind: 'receipt', amount: 888, accountId: acc);
    expect((await r.expenses()).length, 2);

    await expectLater(r.saveExpense(date: '2025-03-30', amount: 0, accountId: acc, newCategory: 'x'), throwsA(isA<StateError>()));
    await expectLater(r.saveExpense(date: '2025-03-30', amount: 5, accountId: acc), throwsA(isA<StateError>()));
  });

  test('standing monthly expenses: registered once per month, on their day, due list and shorter months', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'بانک', kind: 'bank', opening: 50000000);
    final acc = (await r.accounts()).single.id;
    final rent = await r.saveRecurring(title: 'اجارهٔ مغازه', newCategory: 'اجاره', amount: 8000000, accountId: acc, day: 5);
    final net = await r.saveRecurring(title: 'اینترنت', newCategory: 'تلفن و اینترنت', amount: 600000, accountId: acc, day: 31);
    await r.saveRecurring(title: 'قدیمی', newCategory: 'سایر', amount: 1, accountId: acc, active: false);
    await expectLater(r.saveRecurring(title: '', newCategory: 'x', amount: 1, accountId: acc), throwsA(isA<StateError>()));
    await expectLater(r.saveRecurring(title: 'x', newCategory: 'x', amount: 1, accountId: acc, day: 32), throwsA(isA<StateError>()));

    expect((await r.recurringDue(1404, 1)).map((x) => x.title), ['اجارهٔ مغازه', 'اینترنت']); // inactive ones never due

    // Farvardin 1404: day 5 = 2025-03-25; day 31 exists in Farvardin (31 days).
    await r.postRecurring(rent, 1404, 1);
    expect((await r.expenses()).single.date, '2025-03-25');
    expect((await r.expenses()).single.description, contains('اجارهٔ مغازه'));
    expect((await r.recurringDue(1404, 1)).map((x) => x.title), ['اینترنت']);
    await expectLater(r.postRecurring(rent, 1404, 1), throwsA(isA<StateError>())); // once a month
    await r.postRecurring(rent, 1404, 1, force: true); // unless asked
    expect((await r.expenses()).length, 2);
    // Next month it is due again.
    expect((await r.recurringDue(1404, 2)).length, 2);
    // Mehr (month 7) has 30 days: day 31 falls on the 30th; Esfand of a normal year has 29.
    await r.postRecurring(net, 1404, 7);
    expect((await r.expenses()).first.date, '2025-10-22'); // 1404/07/30
    expect((await r.accounts()).single.balance, 50000000 - 8000000 - 8000000 - 600000);
    // Editing keeps the month it was last registered for.
    await r.saveRecurring(id: rent, title: 'اجارهٔ مغازه', categoryId: (await r.categories()).firstWhere((c) => c.name == 'اجاره').id, amount: 9000000, accountId: acc, day: 5);
    expect((await r.recurringExpenses()).firstWhere((x) => x.id == rent).postedFor(1404, 1), isTrue);
    await r.deleteRecurring(rent);
    expect((await r.recurringExpenses()).length, 2);
  });

  test('a closed period refuses expenses; standing expenses need transaction rights', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single.id;
    await r.setSetting(lockSettingKey, '2025-03-31');
    await expectLater(r.saveExpense(date: '2025-03-10', amount: 5, accountId: acc, newCategory: 'اجاره'), throwsA(isA<AccessDenied>()));
    await r.saveExpense(date: '2025-04-10', amount: 5, accountId: acc, newCategory: 'اجاره');
    expect(Access({'transactions.edit'}).canWriteTable('recurring_expenses'), isTrue);
    expect(Access({'invoices.edit'}).canWriteTable('recurring_expenses'), isFalse);
    expect(auditTables.containsKey('recurring_expenses'), isTrue);
    expect(suggestedExpenseCategories, contains('اجاره'));
  });
}
