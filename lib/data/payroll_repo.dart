import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;

import '../util/format.dart';
import 'db.dart';
import 'payroll.dart';
import 'repo.dart';

class Employee {
  Employee({
    required this.id,
    required this.name,
    this.phone = '',
    this.payType = 'monthly',
    this.base = 0,
    this.attendanceBased = false,
    this.dailyHours = 8,
    this.overtimeRate = 0,
    this.insurancePercent = 0,
    this.formula = '',
    this.contractMonths = 0,
    this.offDays = const {5},
    this.startDate = '',
    this.active = true,
    this.note = '',
  });
  final String id, name, phone, payType, formula, startDate, note;
  final int base, contractMonths;
  final bool attendanceBased, active;
  final double dailyHours, overtimeRate, insurancePercent;

  /// Weekly days off (DateTime.weekday: Monday = 1 ... Sunday = 7); Friday by default.
  final Set<int> offDays;

  /// Short description of how this person is paid.
  String get payText => switch (payType) {
        'hourly' => 'ساعتی • ${money(base)} $currencyLabel در ساعت',
        'contract' => 'قراردادی • ${money(base)} $currencyLabel${contractMonths > 0 ? ' در ${faDigits('$contractMonths')} ماه' : ''}',
        'formula' => 'فرمول دلخواه',
        _ => 'ماهانه • ${money(base)} $currencyLabel${attendanceBased ? ' (بر اساس حضور)' : ''}',
      };
}

class AttendanceEntry {
  AttendanceEntry(this.id, this.employeeId, this.date, this.kind, this.inTime, this.outTime, this.minutes, this.note);
  final String id, employeeId, date, kind, inTime, outTime, note;
  final int minutes;
  bool get leave => kind == 'leave';

  /// Entered but not left yet.
  bool get open => !leave && outTime.isEmpty;
}

class PayItem {
  PayItem({this.id, required this.kind, required this.title, required this.amount, this.txId});
  final String? id;

  /// `add` or `deduct`.
  final String kind, title;
  final int amount;

  /// The advance payment this deduction settles, if any.
  final String? txId;
  bool get isAdd => kind == 'add';
}

class Payslip {
  Payslip({
    required this.id,
    required this.employeeId,
    required this.year,
    required this.month,
    required this.status,
    required this.payType,
    required this.calc,
    required this.manualBase,
    required this.note,
    required this.paid,
    required this.items,
  });
  final String id, employeeId, status, payType, note;
  final int year, month, paid;
  final int? manualBase;
  final PayCalc calc;
  final List<PayItem> items;
  bool get isFinal => status == 'final';
  int get remaining => calc.net - paid;
}

/// Payroll: people, time clock, payslips, payments and advances.
extension PayrollRepo on Repo {
  // ---- people -------------------------------------------------------------

  Employee _employee(Map<String, Object?> r) => Employee(
        id: r['id'] as String,
        name: r['name'] as String,
        phone: r['phone'] as String,
        payType: r['pay_type'] as String,
        base: r['base_amount'] as int,
        attendanceBased: (r['attendance_based'] as int) == 1,
        dailyHours: (r['daily_hours'] as num).toDouble(),
        overtimeRate: (r['overtime_rate'] as num).toDouble(),
        insurancePercent: (r['insurance_percent'] as num).toDouble(),
        formula: r['formula'] as String,
        contractMonths: r['contract_months'] as int,
        offDays: {for (final d in (r['off_days'] as String).split(',')) if (int.tryParse(d.trim()) != null) int.parse(d.trim())},
        startDate: r['start_date'] as String,
        active: (r['active'] as int) == 1,
        note: r['note'] as String,
      );

  Future<List<Employee>> employees({bool onlyActive = false}) async {
    final rows = await store.db.query('employees', where: onlyActive ? 'deleted=0 AND active=1' : 'deleted=0', orderBy: 'active DESC, name');
    return [for (final r in rows) _employee(r)];
  }

  Future<Employee?> employee(String id) async {
    final rows = await store.db.query('employees', where: 'id=? AND deleted=0', whereArgs: [id]);
    return rows.isEmpty ? null : _employee(rows.first);
  }

  Future<String> saveEmployee({
    String? id,
    required String name,
    String phone = '',
    String payType = 'monthly',
    int base = 0,
    bool attendanceBased = false,
    double dailyHours = 8,
    double overtimeRate = 0,
    double insurancePercent = 0,
    String formula = '',
    int contractMonths = 0,
    Set<int> offDays = const {5},
    String startDate = '',
    bool active = true,
    String note = '',
  }) async {
    if (name.trim().isEmpty) throw StateError('نام را وارد کنید.');
    if (dailyHours <= 0 || dailyHours > 24) throw StateError('ساعت کار روزانه باید بین ۰ و ۲۴ باشد.');
    if (payType == 'formula') {
      // Check the formula against sample numbers so a typo is caught now, not at payday.
      try {
        Payroll.calculate(PayInput(
            payType: 'formula', base: base, formula: formula, dailyHours: dailyHours, overtimeRate: overtimeRate, entries: [WorkEntry('2025-01-01', 480)], workdays: 22, offDates: {}, monthDays: 30));
      } on FormatException catch (e) {
        throw StateError('فرمول درست نیست: ${e.message}');
      }
    }
    final eid = id ?? AppDb.newId();
    await store.save('employees', {
      'id': eid, 'name': name.trim(), 'phone': phone, 'pay_type': payType, 'base_amount': base, 'attendance_based': attendanceBased ? 1 : 0,
      'daily_hours': dailyHours, 'overtime_rate': overtimeRate, 'insurance_percent': insurancePercent, 'formula': formula.trim(),
      'contract_months': contractMonths, 'off_days': (offDays.toList()..sort()).join(','), 'start_date': startDate, 'active': active ? 1 : 0, 'note': note,
    });
    changed();
    return eid;
  }

  /// Removes a person; someone who already has payslips is made inactive instead.
  /// Returns a message when that happened, null when really deleted.
  Future<String?> deleteEmployee(String id) async {
    final n = (await store.db.rawQuery('SELECT COUNT(*) AS n FROM payslips WHERE employee_id=? AND deleted=0', [id])).first['n'] as int;
    if (n > 0) {
      final e = (await employee(id))!;
      await saveEmployee(
          id: id, name: e.name, phone: e.phone, payType: e.payType, base: e.base, attendanceBased: e.attendanceBased, dailyHours: e.dailyHours,
          overtimeRate: e.overtimeRate, insurancePercent: e.insurancePercent, formula: e.formula, contractMonths: e.contractMonths, offDays: e.offDays,
          startDate: e.startDate, active: false, note: e.note);
      return 'این شخص فیش حقوقی دارد؛ حذف نشد و غیرفعال شد.';
    }
    for (final r in await store.db.query('attendance', columns: ['id'], where: 'employee_id=? AND deleted=0', whereArgs: [id])) {
      await store.softDelete('attendance', r['id'] as String);
    }
    await store.softDelete('employees', id);
    changed();
    return null;
  }

  // ---- calendar -----------------------------------------------------------

  /// Official holidays (ISO dates) the payroll treats as days off.
  Set<String> get payrollHolidays => {for (final d in setting('payroll_holidays').split(',')) if (d.trim().isNotEmpty) d.trim()};

  Future<void> setPayrollHolidays(Set<String> dates) => setSetting('payroll_holidays', (dates.toList()..sort()).join(','));

  // ---- time clock ---------------------------------------------------------

  Future<List<AttendanceEntry>> attendanceOf(String employeeId, {String? from, String? toExclusive}) async {
    final where = ['employee_id=?', 'deleted=0', if (from != null) 'date>=?', if (toExclusive != null) 'date<?'];
    final rows = await store.db.query('attendance',
        where: where.join(' AND '), whereArgs: [employeeId, ?from, ?toExclusive], orderBy: 'date, in_time');
    return [
      for (final r in rows)
        AttendanceEntry(r['id'] as String, r['employee_id'] as String, r['date'] as String, r['kind'] as String, r['in_time'] as String,
            r['out_time'] as String, r['minutes'] as int, r['note'] as String)
    ];
  }

  /// Adds or changes a time-clock entry. [outTime] empty = still at work. A
  /// paid-leave entry ([kind] `leave`) counts [leaveMinutes] (a whole day by default).
  Future<String> saveAttendance({
    String? id,
    required String employeeId,
    required String date,
    String kind = 'work',
    String inTime = '',
    String outTime = '',
    int? leaveMinutes,
    String note = '',
  }) async {
    final e = await employee(employeeId);
    if (e == null) throw StateError('شخص پیدا نشد.');
    var minutes = 0;
    var inT = '', outT = '';
    if (kind == 'leave') {
      minutes = leaveMinutes ?? (e.dailyHours * 60).round();
    } else {
      final a = Payroll.parseClock(enDigits(inTime));
      if (a == null) throw StateError('ساعت ورود را به شکل 08:30 بنویسید.');
      inT = Payroll.clockText(a);
      if (outTime.trim().isNotEmpty) {
        final b = Payroll.parseClock(enDigits(outTime));
        if (b == null) throw StateError('ساعت خروج را به شکل 17:00 بنویسید.');
        outT = Payroll.clockText(b);
        minutes = Payroll.minutesBetween(inT, outT);
      } else {
        final open = await store.db.query('attendance', where: "employee_id=? AND deleted=0 AND kind='work' AND out_time='' AND id<>?", whereArgs: [employeeId, id ?? '']);
        if (open.isNotEmpty) throw StateError('برای این شخص یک ورود بدون خروج هست؛ اول خروج را ثبت کنید.');
      }
    }
    final aid = id ?? AppDb.newId();
    await store.save('attendance', {'id': aid, 'employee_id': employeeId, 'date': date, 'kind': kind, 'in_time': inT, 'out_time': outT, 'minutes': minutes, 'note': note});
    changed();
    return aid;
  }

  Future<void> deleteAttendance(String id) async {
    await store.softDelete('attendance', id);
    changed();
  }

  /// "Arrived now": an open entry for today.
  Future<String> clockIn(String employeeId, {DateTime? now}) {
    final t = now ?? DateTime.now();
    return saveAttendance(employeeId: employeeId, date: isoOf(t), inTime: Payroll.clockText(t.hour * 60 + t.minute));
  }

  /// "Left now": closes the open entry. Returns false when there was none.
  Future<bool> clockOut(String employeeId, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final open = await store.db.query('attendance', where: "employee_id=? AND deleted=0 AND kind='work' AND out_time=''", whereArgs: [employeeId], orderBy: 'date DESC, in_time DESC', limit: 1);
    if (open.isEmpty) return false;
    final r = open.first;
    final out = Payroll.clockText(t.hour * 60 + t.minute);
    await store.save('attendance', {...r, 'out_time': out, 'minutes': Payroll.minutesBetween(r['in_time'] as String, out)});
    changed();
    return true;
  }

  // ---- calculation --------------------------------------------------------

  Future<PayInput> payInput(Employee e, int year, int month, {int? manualBase, List<PayItem> items = const []}) async {
    final (from, to) = jalaliMonthRange(year, month);
    final entries = await attendanceOf(e.id, from: from, toExclusive: to);
    final cal = Payroll.monthDays(DateTime.parse(from), DateTime.parse(to), e.offDays, payrollHolidays, start: e.startDate);
    return PayInput(
      payType: e.payType,
      base: e.base,
      attendanceBased: e.attendanceBased,
      dailyHours: e.dailyHours,
      overtimeRate: e.overtimeRate,
      insurancePercent: e.insurancePercent,
      formula: e.formula,
      contractMonths: e.contractMonths,
      manualBase: manualBase,
      entries: [for (final a in entries) if (a.minutes > 0 || a.leave) WorkEntry(a.date, a.minutes, leave: a.leave)],
      workdays: cal.workdays,
      offDates: cal.offDates,
      monthDays: cal.monthDays,
      additions: items.where((i) => i.isAdd).fold(0, (a, i) => a + i.amount),
      manualDeductions: items.where((i) => !i.isAdd).fold(0, (a, i) => a + i.amount),
    );
  }

  /// The payslip figures of [e] for a Jalali month, from the time clock as it is now.
  Future<PayCalc> calcPayslip(Employee e, int year, int month, {int? manualBase, List<PayItem> items = const []}) async =>
      Payroll.calculate(await payInput(e, year, month, manualBase: manualBase, items: items));

  // ---- payslips -----------------------------------------------------------

  Future<Payslip> _slip(Map<String, Object?> r, {DatabaseExecutor? ex}) async {
    final e = ex ?? store.db;
    final items = [
      for (final i in await e.query('payroll_items', where: 'payslip_id=? AND deleted=0', whereArgs: [r['id']]))
        PayItem(id: i['id'] as String, kind: i['kind'] as String, title: i['title'] as String, amount: i['amount'] as int, txId: i['tx_id'] as String?)
    ];
    final paid = ((await e.rawQuery('SELECT COALESCE(SUM(amount),0) AS n FROM transactions WHERE payslip_id=? AND deleted=0', [r['id']])).first['n'] as num).round();
    final basePay = r['base_pay'] as int, ot = r['overtime_pay'] as int, add = r['additions'] as int, ded = r['deductions'] as int, ins = r['insurance'] as int;
    return Payslip(
      id: r['id'] as String,
      employeeId: r['employee_id'] as String,
      year: r['year'] as int,
      month: r['month'] as int,
      status: r['status'] as String,
      payType: r['pay_type'] as String,
      manualBase: r['manual_base'] as int?,
      note: r['note'] as String,
      paid: paid,
      items: items,
      calc: PayCalc(
        workedMin: r['worked_min'] as int,
        leaveMin: r['leave_min'] as int,
        overtimeMin: r['overtime_min'] as int,
        requiredMin: r['required_min'] as int,
        daysPresent: 0,
        basePay: basePay,
        overtimePay: ot,
        additions: add,
        manualDeductions: ded,
        insurance: ins,
        net: r['net'] as int,
        shortfall: 0,
        ratio: (r['required_min'] as int) > 0 ? ((r['worked_min'] as int) - (r['overtime_min'] as int) + (r['leave_min'] as int)) / (r['required_min'] as int) : 1,
      ),
    );
  }

  Future<Payslip?> payslipOf(String employeeId, int year, int month) async {
    final rows = await store.db.query('payslips', where: 'employee_id=? AND year=? AND month=? AND deleted=0', whereArgs: [employeeId, year, month]);
    return rows.isEmpty ? null : _slip(rows.first);
  }

  Future<List<Payslip>> payslips(int year, int month) async =>
      [for (final r in await store.db.query('payslips', where: 'year=? AND month=? AND deleted=0', whereArgs: [year, month])) await _slip(r)];

  Future<List<Payslip>> payslipsOf(String employeeId) async =>
      [for (final r in await store.db.query('payslips', where: 'employee_id=? AND deleted=0', whereArgs: [employeeId], orderBy: 'year DESC, month DESC')) await _slip(r)];

  /// Calculates and stores the payslip of [e] for a month (a draft, or final).
  /// A final payslip is not changed any more; reopen it first.
  Future<String> savePayslip(Employee e, int year, int month, {int? manualBase, List<PayItem> items = const [], String status = 'draft', String note = ''}) async {
    final old = await payslipOf(e.id, year, month);
    if (old != null && old.isFinal) throw StateError('این فیش نهایی شده است؛ اول آن را باز کنید.');
    final calc = await calcPayslip(e, year, month, manualBase: manualBase, items: items);
    final sid = old?.id ?? AppDb.newId();
    await store.db.transaction((tx) async {
      await store.save('payslips', {
        'id': sid, 'employee_id': e.id, 'year': year, 'month': month, 'status': status, 'pay_type': e.payType,
        'worked_min': calc.workedMin, 'leave_min': calc.leaveMin, 'overtime_min': calc.overtimeMin, 'required_min': calc.requiredMin,
        'base_pay': calc.basePay, 'overtime_pay': calc.overtimePay, 'additions': calc.additions, 'deductions': calc.manualDeductions,
        'insurance': calc.insurance, 'net': calc.net, 'manual_base': manualBase, 'note': note,
      }, exec: tx);
      for (final r in await tx.query('payroll_items', columns: ['id'], where: 'payslip_id=? AND deleted=0', whereArgs: [sid])) {
        await store.softDelete('payroll_items', r['id'] as String, exec: tx);
      }
      for (final i in items) {
        await store.save('payroll_items', {'payslip_id': sid, 'kind': i.kind, 'title': i.title, 'amount': i.amount, 'tx_id': i.txId}, exec: tx);
      }
    });
    changed();
    return sid;
  }

  Future<void> setPayslipStatus(String id, String status) async {
    final r = (await store.db.query('payslips', where: 'id=?', whereArgs: [id])).first;
    await store.save('payslips', {...r, 'status': status});
    changed();
  }

  /// Returns an error text, or null when the payslip was deleted.
  Future<String?> deletePayslip(String id) async {
    final r = await store.db.query('payslips', where: 'id=? AND deleted=0', whereArgs: [id]);
    if (r.isEmpty) return null;
    final s = await _slip(r.first);
    if (s.paid > 0) return 'برای این فیش پرداخت ثبت شده؛ اول پرداخت‌ها را از تراکنش‌ها حذف کنید.';
    for (final i in await store.db.query('payroll_items', columns: ['id'], where: 'payslip_id=? AND deleted=0', whereArgs: [id])) {
      await store.softDelete('payroll_items', i['id'] as String);
    }
    await store.softDelete('payslips', id);
    changed();
    return null;
  }

  // ---- payments -----------------------------------------------------------

  Future<String> _salaryCategory() async {
    final rows = await store.db.query('categories', where: "deleted=0 AND kind='expense' AND name=?", whereArgs: ['حقوق و دستمزد']);
    if (rows.isNotEmpty) return rows.first['id'] as String;
    final id = AppDb.newId();
    await store.save('categories', {'id': id, 'name': 'حقوق و دستمزد', 'kind': 'expense'});
    return id;
  }

  /// Pays (part of) a payslip from [accountId]: a payment in the accounts.
  Future<String> payPayslip({required String payslipId, required String accountId, required int amount, required String date, String note = ''}) async {
    final r = await store.db.query('payslips', where: 'id=? AND deleted=0', whereArgs: [payslipId]);
    if (r.isEmpty) throw StateError('فیش پیدا نشد.');
    final s = await _slip(r.first);
    final e = await employee(s.employeeId);
    if (amount <= 0) throw StateError('مبلغ را وارد کنید.');
    if (amount > s.remaining) throw StateError('مبلغ از باقی‌ماندهٔ فیش (${money(s.remaining)}) بیشتر است.');
    return saveTx(
      date: date,
      kind: 'payment',
      amount: amount,
      accountId: accountId,
      categoryId: await _salaryCategory(),
      description: 'حقوق ${e?.name ?? ''} ${faDigits('${s.year}/${s.month}')}${note.isEmpty ? '' : ' - $note'}',
      payslipId: payslipId,
      employeeId: s.employeeId,
    );
  }

  /// An advance (مساعده): money paid before the payslip; it can be deducted from a payslip later.
  Future<String> payAdvance({required String employeeId, required String accountId, required int amount, required String date, String note = ''}) async {
    final e = await employee(employeeId);
    if (e == null) throw StateError('شخص پیدا نشد.');
    if (amount <= 0) throw StateError('مبلغ را وارد کنید.');
    return saveTx(
      date: date,
      kind: 'payment',
      amount: amount,
      accountId: accountId,
      categoryId: await _salaryCategory(),
      description: 'مساعده ${e.name}${note.isEmpty ? '' : ' - $note'}',
      employeeId: employeeId,
    );
  }

  /// Advances of a person that no payslip has deducted yet: (transaction id, date, amount, description).
  Future<List<(String, String, int, String)>> outstandingAdvances(String employeeId) async {
    final rows = await store.db.rawQuery('''
      SELECT t.id, t.date, t.amount, t.description FROM transactions t
      WHERE t.employee_id=? AND t.payslip_id IS NULL AND t.kind='payment' AND t.deleted=0
        AND t.id NOT IN (SELECT tx_id FROM payroll_items WHERE deleted=0 AND tx_id IS NOT NULL)
      ORDER BY t.date''', [employeeId]);
    return [for (final r in rows) (r['id'] as String, r['date'] as String, r['amount'] as int, r['description'] as String)];
  }

  /// A contract person: total, what the payslips so far count and what is left.
  Future<({int total, int accrued, int remaining})> contractSummary(Employee e) async {
    final slips = await payslipsOf(e.id);
    final accrued = slips.fold<int>(0, (a, s) => a + s.calc.basePay);
    return (total: e.base, accrued: accrued, remaining: e.base - accrued);
  }

  // ---- duplicates ---------------------------------------------------------

  /// Number of time-clock entries per person (id -> count).
  Future<Map<String, int>> attendanceCounts() async => {
        for (final r in await store.db.rawQuery('SELECT employee_id AS id, COUNT(*) AS n FROM attendance WHERE deleted=0 GROUP BY employee_id')) r['id'] as String: r['n'] as int
      };

  /// People entered twice (the same name), e.g. one on each device before they
  /// were synchronised. Each group lists the people with that name.
  Future<List<List<Employee>>> duplicateEmployees() async {
    final byName = <String, List<Employee>>{};
    for (final e in await employees()) {
      byName.putIfAbsent(e.name.trim().toLowerCase(), () => []).add(e);
    }
    return [for (final g in byName.values) if (g.length > 1) g];
  }

  /// Merges [dropId] into [keepId]: its time-clock entries, payslips, advances
  /// and payments move to the person kept, then the duplicate is removed. Two
  /// payslips for the same month cannot be merged (a message says which).
  Future<void> mergeEmployees(String keepId, String dropId) async {
    if (keepId == dropId) throw StateError('یک نفر را نمی‌شود با خودش ادغام کرد.');
    final keep = await employee(keepId), drop = await employee(dropId);
    if (keep == null || drop == null) throw StateError('شخص پیدا نشد.');
    final keepSlips = {for (final s in await payslipsOf(keepId)) s.year * 100 + s.month};
    final clash = [for (final s in await payslipsOf(dropId)) if (keepSlips.contains(s.year * 100 + s.month)) '${s.year}/${s.month}'];
    if (clash.isNotEmpty) throw StateError('برای هر دو نفر فیش ماه ${clash.join('، ')} هست؛ اول یکی از آن فیش‌ها را حذف کنید.');
    await store.db.transaction((tx) async {
      for (final t in ['attendance', 'payslips', 'transactions']) {
        for (final r in await tx.query(t, where: 'employee_id=? AND deleted=0', whereArgs: [dropId])) {
          await store.save(t, {...r, 'employee_id': keepId}, exec: tx);
        }
      }
      await store.softDelete('employees', dropId, exec: tx);
    });
    changed();
  }
}
