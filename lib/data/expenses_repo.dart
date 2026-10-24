import 'package:shamsi_date/shamsi_date.dart';

import '../util/format.dart';
import 'db.dart';
import 'repo.dart';

/// Names offered when registering an expense: the usual running costs of a business.
const suggestedExpenseCategories = <String>[
  'اجاره',
  'قبض برق',
  'قبض آب',
  'قبض گاز',
  'تلفن و اینترنت',
  'حقوق و دستمزد',
  'حمل و نقل',
  'تبلیغات',
  'تعمیرات و نگهداری',
  'ملزومات اداری',
  'پذیرایی',
  'کارمزد بانکی',
  'بیمه',
  'مالیات و عوارض',
  'خدمات حسابداری و حقوقی',
  'سایر هزینه‌ها',
];

/// An expense: money paid out that is not for goods on an invoice and not to a
/// person's account (rent, bills, repairs...).
class Expense {
  Expense(this.id, this.date, this.amount, this.accountId, this.categoryId, this.description);
  final String id, date, accountId, description;
  final String? categoryId;
  final int amount;
}

/// A category's share of the expenses of a period.
class ExpenseGroup {
  ExpenseGroup(this.categoryId, this.name, this.total, this.count);
  final String? categoryId;
  final String name;
  final int total, count;
}

/// A standing monthly expense.
class RecurringExpense {
  RecurringExpense({required this.id, required this.title, this.categoryId, required this.amount, this.accountId, required this.day, required this.active, required this.lastMonth, this.note = ''});
  final String id, title, note;
  final String? categoryId, accountId;
  final int amount, day, lastMonth;
  final bool active;

  /// Registered for this Jalali month already?
  bool postedFor(int year, int month) => lastMonth >= year * 100 + month;
}

extension ExpensesRepo on Repo {
  /// The category with this name among the expense categories; made when missing.
  Future<String> ensureExpenseCategory(String name) async {
    final n = name.trim();
    if (n.isEmpty) throw StateError('دستهٔ هزینه را مشخص کنید.');
    final rows = await store.db.query('categories', where: "deleted=0 AND kind='expense' AND name=?", whereArgs: [n]);
    if (rows.isNotEmpty) return rows.first['id'] as String;
    final id = AppDb.newId();
    await store.save('categories', {'id': id, 'name': n, 'kind': 'expense'});
    changed();
    return id;
  }

  static const _expenseWhere = "t.deleted=0 AND t.kind='payment' AND t.party_id IS NULL AND t.invoice_id IS NULL";

  /// Expenses of a period (newest first), optionally of one category.
  Future<List<Expense>> expenses({String? from, String? toExclusive, String? categoryId}) async {
    final rows = await store.db.rawQuery('''
      SELECT t.* FROM transactions t
      WHERE ${ExpensesRepo._expenseWhere} ${from == null ? '' : 'AND t.date>=?'} ${toExclusive == null ? '' : 'AND t.date<?'} ${categoryId == null ? '' : 'AND t.category_id=?'}
      ORDER BY t.date DESC, t.updated_at DESC''', [?from, ?toExclusive, ?categoryId]);
    return [for (final r in rows) Expense(r['id'] as String, r['date'] as String, r['amount'] as int, r['account_id'] as String, r['category_id'] as String?, r['description'] as String)];
  }

  /// Totals per category for a period, biggest first.
  Future<List<ExpenseGroup>> expenseGroups({String? from, String? toExclusive}) async {
    final rows = await store.db.rawQuery('''
      SELECT t.category_id AS cid, COALESCE(c.name,'بدون دسته‌بندی') AS name, SUM(t.amount) AS total, COUNT(*) AS n
      FROM transactions t LEFT JOIN categories c ON c.id=t.category_id
      WHERE ${ExpensesRepo._expenseWhere} ${from == null ? '' : 'AND t.date>=?'} ${toExclusive == null ? '' : 'AND t.date<?'}
      GROUP BY t.category_id ORDER BY total DESC''', [?from, ?toExclusive]);
    return [for (final r in rows) ExpenseGroup(r['cid'] as String?, r['name'] as String, (r['total'] as num).round(), r['n'] as int)];
  }

  /// Registers (or changes) an expense. Either [categoryId] or a [newCategory]
  /// name is needed. No invoice and no person are involved: the money simply
  /// leaves [accountId] and counts as a cost in the profit and loss report.
  Future<String> saveExpense({String? id, required String date, required int amount, required String accountId, String? categoryId, String? newCategory, String description = ''}) async {
    if (amount <= 0) throw StateError('مبلغ را وارد کنید.');
    final cat = (newCategory ?? '').trim().isNotEmpty ? await ensureExpenseCategory(newCategory!) : categoryId;
    if (cat == null) throw StateError('دستهٔ هزینه را انتخاب کنید.');
    return saveTx(id: id, date: date, kind: 'payment', amount: amount, accountId: accountId, categoryId: cat, description: description.trim());
  }

  // ---- standing expenses --------------------------------------------------

  RecurringExpense _recurring(Map<String, Object?> r) => RecurringExpense(
        id: r['id'] as String,
        title: r['title'] as String,
        categoryId: r['category_id'] as String?,
        amount: r['amount'] as int,
        accountId: r['account_id'] as String?,
        day: r['day'] as int,
        active: (r['active'] as int) == 1,
        lastMonth: r['last_month'] as int,
        note: r['note'] as String,
      );

  Future<List<RecurringExpense>> recurringExpenses() async =>
      [for (final r in await store.db.query('recurring_expenses', where: 'deleted=0', orderBy: 'active DESC, day, title')) _recurring(r)];

  Future<String> saveRecurring({String? id, required String title, String? categoryId, String? newCategory, required int amount, required String accountId, int day = 1, bool active = true, String note = ''}) async {
    if (title.trim().isEmpty) throw StateError('عنوان را بنویسید.');
    if (amount <= 0) throw StateError('مبلغ را وارد کنید.');
    if (day < 1 || day > 31) throw StateError('روز ماه باید بین ۱ و ۳۱ باشد.');
    final cat = (newCategory ?? '').trim().isNotEmpty ? await ensureExpenseCategory(newCategory!) : categoryId;
    if (cat == null) throw StateError('دستهٔ هزینه را انتخاب کنید.');
    final rid = id ?? AppDb.newId();
    final old = id == null ? null : (await store.db.query('recurring_expenses', where: 'id=?', whereArgs: [id])).firstOrNull;
    await store.save('recurring_expenses', {
      'id': rid, 'title': title.trim(), 'category_id': cat, 'amount': amount, 'account_id': accountId, 'day': day, 'active': active ? 1 : 0,
      'last_month': old?['last_month'] ?? 0, 'note': note,
    });
    changed();
    return rid;
  }

  Future<void> deleteRecurring(String id) async {
    await store.softDelete('recurring_expenses', id);
    changed();
  }

  /// Registers a standing expense for a Jalali month (dated on its day, or the
  /// last day of a shorter month). Refuses a month that was registered already.
  Future<String> postRecurring(String id, int year, int month, {bool force = false}) async {
    final rows = await store.db.query('recurring_expenses', where: 'id=? AND deleted=0', whereArgs: [id]);
    if (rows.isEmpty) throw StateError('هزینهٔ ثابت پیدا نشد.');
    final r = _recurring(rows.first);
    if (r.postedFor(year, month) && !force) throw StateError('«${r.title}» برای این ماه ثبت شده است.');
    final accountId = r.accountId;
    if (accountId == null) throw StateError('حساب پرداخت مشخص نیست.');
    final len = Jalali(year, month, 1).monthLength;
    final date = isoOf(Jalali(year, month, r.day > len ? len : r.day).toDateTime());
    final tx = await saveTx(date: date, kind: 'payment', amount: r.amount, accountId: accountId, categoryId: r.categoryId, description: '${r.title} ${monthNames[month - 1]} ${faDigits('$year')}');
    final newLast = year * 100 + month;
    await store.save('recurring_expenses', {...rows.first, 'last_month': newLast > r.lastMonth ? newLast : r.lastMonth});
    changed();
    return tx;
  }

  /// Active standing expenses not yet registered for the month.
  Future<List<RecurringExpense>> recurringDue(int year, int month) async => [for (final r in await recurringExpenses()) if (r.active && !r.postedFor(year, month)) r];
}
