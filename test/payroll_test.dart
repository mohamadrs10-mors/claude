import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/access.dart';
import 'package:simple_accounting/data/costing.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/guard.dart';
import 'package:simple_accounting/data/payroll.dart';
import 'package:simple_accounting/data/payroll_repo.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/sync/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_pay');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

PayInput input(String type, {int base = 0, bool att = false, double daily = 8, double ot = 0, double ins = 0, String formula = '', int months = 0, int? manual,
    List<WorkEntry> entries = const [], int workdays = 20, Set<String> off = const {}, int add = 0, int ded = 0}) =>
    PayInput(payType: type, base: base, attendanceBased: att, dailyHours: daily, overtimeRate: ot, insurancePercent: ins, formula: formula, contractMonths: months,
        manualBase: manual, entries: entries, workdays: workdays, offDates: off, monthDays: 30, additions: add, manualDeductions: ded);

/// [days] days of [hours] hours each, from 2025-03-01 on.
List<WorkEntry> days(int days, double hours) => [for (var i = 1; i <= days; i++) WorkEntry('2025-03-${i.toString().padLeft(2, '0')}', (hours * 60).round())];

void main() {
  test('time arithmetic: entries, night shifts and bad input', () {
    expect(Payroll.minutesBetween('08:30', '17:00'), 510);
    expect(Payroll.minutesBetween('22:00', '06:00'), 480); // night shift: exit the next morning
    expect(Payroll.parseClock('7:5'), 7 * 60 + 5);
    expect(Payroll.parseClock('24:00'), isNull);
    expect(Payroll.parseClock('abc'), isNull);
    expect(Payroll.clockText(65), '01:05');
  });

  test('monthly salary: fixed, or cut in proportion to the hours missing', () {
    // 20 working days x 8 h = 160 h required; salary 16,000,000.
    final fixed = Payroll.calculate(input('monthly', base: 16000000, entries: days(15, 8)));
    expect(fixed.basePay, 16000000); // attendance does not matter for this person

    final full = Payroll.calculate(input('monthly', base: 16000000, att: true, entries: days(20, 8)));
    expect(full.basePay, 16000000);
    // One hour less than required: pays one hour less (1/160 of the salary = 100,000).
    final oneLess = Payroll.calculate(input('monthly', base: 16000000, att: true, entries: [...days(19, 8), WorkEntry('2025-03-20', 7 * 60)]));
    expect(oneLess.basePay, 15900000);
    expect(oneLess.shortfall, 100000);
    // Half the hours: half the salary; paid leave counts as present; extra hours never raise the base above 100%.
    expect(Payroll.calculate(input('monthly', base: 16000000, att: true, entries: days(10, 8))).basePay, 8000000);
    expect(Payroll.calculate(input('monthly', base: 16000000, att: true, entries: [...days(10, 8), WorkEntry('2025-03-11', 10 * 60, leave: true)])).basePay, 16000000 * 90 ~/ 160);
    expect(Payroll.calculate(input('monthly', base: 16000000, att: true, entries: days(20, 10))).basePay, 16000000);
    // Nothing worked at all: nothing earned.
    expect(Payroll.calculate(input('monthly', base: 16000000, att: true)).net, 0);
  });

  test('hourly pay: rate x hours present, paid leave included', () {
    final c = Payroll.calculate(input('hourly', base: 120000, entries: [...days(10, 6), WorkEntry('2025-03-12', 120, leave: true)]));
    expect(c.workedMin, 3600);
    expect(c.basePay, 120000 * 62); // 60 h worked + 2 h leave
    expect(Payroll.calculate(input('hourly', base: 100000, entries: [WorkEntry('2025-03-01', 90)])).basePay, 150000); // 1.5 h
  });

  test('overtime: beyond the daily hours, and all work on a day off; only when a rate is set', () {
    final entries = [WorkEntry('2025-03-01', 10 * 60), WorkEntry('2025-03-02', 8 * 60), WorkEntry('2025-03-07', 4 * 60)]; // the 7th is a Friday off
    final none = Payroll.calculate(input('hourly', base: 100000, entries: entries, off: {'2025-03-07'}));
    expect(none.overtimeMin, 0);
    expect(none.basePay, 100000 * 22);
    final c = Payroll.calculate(input('hourly', base: 100000, ot: 1.5, entries: entries, off: {'2025-03-07'}));
    expect(c.overtimeMin, 2 * 60 + 4 * 60);
    expect(c.basePay, 100000 * 16); // normal hours: 8 + 8
    expect(c.overtimePay, 100000 * 6 * 1.5);
    // Monthly: the overtime hour is worth salary / required hours.
    final m = Payroll.calculate(input('monthly', base: 16000000, ot: 1.4, entries: [WorkEntry('2025-03-01', 10 * 60)]));
    expect(m.overtimePay, (100000 * 2 * 1.4).round());
  });

  test('contract pay: instalments of the contract amount, or a hand-typed amount', () {
    expect(Payroll.calculate(input('contract', base: 60000000, months: 6)).basePay, 10000000);
    expect(Payroll.calculate(input('contract', base: 60000000)).basePay, 60000000); // no months: the whole amount
    expect(Payroll.calculate(input('contract', base: 60000000, months: 6, manual: 25000000)).basePay, 25000000);
  });

  test('custom formulas: hours, days, conditions and rounding', () {
    // 90,000 an hour up to 160 h, 135,000 beyond; a bonus for full attendance.
    const f = 'min(hours, 160) * base + max(hours - 160, 0) * base * 1.5 + if(ratio >= 1, 500000, 0)';
    expect(Payroll.calculate(input('formula', base: 90000, formula: f, entries: days(20, 8))).basePay, 160 * 90000 + 500000);
    expect(Payroll.calculate(input('formula', base: 90000, formula: f, entries: days(20, 9))).basePay, 160 * 90000 + 20 * 90000 * 1.5 + 500000);
    expect(Payroll.calculate(input('formula', base: 90000, formula: f, entries: days(10, 8))).basePay, 80 * 90000);
    // Per day present, with the amount rounded up to the nearest 10,000.
    expect(Payroll.calculate(input('formula', base: 1234567, formula: 'ceil(days * 100000 + base * 10%, 10000)', entries: days(3, 8))).basePay, 430000);
    expect(() => Payroll.calculate(input('formula', base: 1, formula: 'nope * 2')), throwsA(isA<FormatException>()));
    expect(() => Payroll.calculate(input('formula', base: 1, formula: 'hours / 0')), throwsA(isA<FormatException>()));
  });

  test('payslip totals: additions, insurance on the pay, manual deductions, hand-typed base', () {
    final c = Payroll.calculate(input('monthly', base: 10000000, ins: 7, add: 500000, ded: 1200000));
    expect(c.insurance, 700000);
    expect(c.net, 10000000 + 500000 - 700000 - 1200000);
    expect(c.gross, 10500000);
    expect(c.deductions, 1900000);
    expect(Payroll.calculate(input('monthly', base: 10000000, manual: 9000000, ins: 10)).net, 8100000);
  });

  test('working days of a month: weekly days off, holidays and a start date', () {
    // Esfand 1403 = 2025-02-20 .. 2025-03-20 (29 days); Fridays off.
    final from = DateTime(2025, 3, 1), to = DateTime(2025, 4, 1); // March 2025: 31 days, 5 Fridays
    final all = Payroll.monthDays(from, to, {5}, {});
    expect((all.workdays, all.monthDays, all.offDates.length), (27, 31, 4));
    final withHoliday = Payroll.monthDays(from, to, {5}, {'2025-03-03', '2025-03-07'}); // one on a Friday already
    expect(withHoliday.workdays, 26);
    expect(Payroll.monthDays(from, to, {5}, {}, start: '2025-03-16').workdays, 14); // joined mid-month
    expect(Payroll.monthDays(from, to, {4, 5}, {}).workdays, 23); // Thursday and Friday off
  });

  test('repo: people, the time clock and a monthly payslip made from it', () async {
    final r = await newRepo();
    final id = await r.saveEmployee(name: 'سارا', payType: 'monthly', base: 12000000, attendanceBased: true, dailyHours: 8, overtimeRate: 1.5, insurancePercent: 7);
    await expectLater(r.saveEmployee(name: ' '), throwsA(isA<StateError>()));
    await expectLater(r.saveEmployee(name: 'ف', payType: 'formula', formula: 'x +'), throwsA(isA<StateError>()));
    // Farvardin 1404: 1404-01-01 = 2025-03-21. Clock in and out by hand.
    await r.saveAttendance(employeeId: id, date: '2025-03-22', inTime: '08:00', outTime: '17:00'); // 9 h -> 1 h overtime
    await r.saveAttendance(employeeId: id, date: '2025-03-23', inTime: '۰۹:۰۰', outTime: '۱۷:۰۰'); // Persian digits
    await r.saveAttendance(employeeId: id, date: '2025-03-24', kind: 'leave'); // one paid day
    final entries = await r.attendanceOf(id);
    expect(entries.map((e) => e.minutes), [540, 480, 480]);
    await expectLater(r.saveAttendance(employeeId: id, date: '2025-03-25', inTime: '99:00'), throwsA(isA<StateError>()));

    final e = (await r.employee(id))!;
    final calc = await r.calcPayslip(e, 1404, 1);
    expect(calc.workedMin, 1020);
    expect(calc.overtimeMin, 60);
    expect(calc.leaveMin, 480);
    expect(calc.requiredMin, greaterThan(20 * 480)); // ~ 26 working days
    // Present: 8 + 8 + 8 h out of the month's required hours.
    final required = calc.requiredMin / 60;
    expect(calc.basePay, (12000000 * (24 / required)).round());
    expect(calc.overtimePay, (12000000 / required * 1.5).round());
    expect(calc.insurance, ((calc.basePay + calc.overtimePay) * 0.07).round());

    // Open entries: one at a time; leaving closes it.
    await r.clockIn(id, now: DateTime(2025, 3, 25, 8, 15));
    await expectLater(r.clockIn(id, now: DateTime(2025, 3, 25, 9)), throwsA(isA<StateError>()));
    expect((await r.attendanceOf(id)).last.open, isTrue);
    expect(await r.clockOut(id, now: DateTime(2025, 3, 25, 12, 45)), isTrue);
    expect((await r.attendanceOf(id)).last.minutes, 270);
    expect(await r.clockOut(id), isFalse);
  });

  test('repo: payslip lifecycle, payments (accounts), advances and contract summary', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'بانک', kind: 'bank', opening: 100000000);
    final acc = (await r.accounts()).single.id;
    final ali = await r.saveEmployee(name: 'علی', payType: 'monthly', base: 10000000, insurancePercent: 5);
    final e = (await r.employee(ali))!;

    // An advance first; it is outstanding until a payslip deducts it.
    final adv = await r.payAdvance(employeeId: ali, accountId: acc, amount: 2000000, date: '2025-03-25', note: 'مساعده');
    expect((await r.outstandingAdvances(ali)).map((a) => a.$1), [adv]);
    expect((await r.accounts()).single.balance, 98000000);

    final items = [PayItem(kind: 'add', title: 'پاداش', amount: 1000000), PayItem(kind: 'deduct', title: 'کسر مساعده', amount: 2000000, txId: adv)];
    await r.savePayslip(e, 1404, 1, items: items);
    var s = (await r.payslipOf(ali, 1404, 1))!;
    expect((s.status, s.calc.basePay, s.calc.insurance, s.calc.net), ('draft', 10000000, 500000, 10000000 + 1000000 - 500000 - 2000000));
    expect(s.items.length, 2);
    expect(await r.outstandingAdvances(ali), isEmpty); // settled by the deduction

    // Saving again replaces (not duplicates) the payslip and its items.
    await r.savePayslip(e, 1404, 1, items: [items.first]);
    s = (await r.payslipOf(ali, 1404, 1))!;
    expect(s.items.length, 1);
    expect((await r.payslips(1404, 1)).length, 1);
    expect((await r.outstandingAdvances(ali)).length, 1); // the deduction is gone: the advance is open again
    await r.savePayslip(e, 1404, 1, items: items);

    // Pay it in two parts; more than is left is refused; the payments are expenses in the accounts.
    s = (await r.payslipOf(ali, 1404, 1))!;
    await r.payPayslip(payslipId: s.id, accountId: acc, amount: 5000000, date: '2025-04-01');
    await expectLater(r.payPayslip(payslipId: s.id, accountId: acc, amount: 99000000, date: '2025-04-01'), throwsA(isA<StateError>()));
    await expectLater(r.payPayslip(payslipId: s.id, accountId: acc, amount: 0, date: '2025-04-01'), throwsA(isA<StateError>()));
    s = (await r.payslipOf(ali, 1404, 1))!;
    expect((s.paid, s.remaining), (5000000, s.calc.net - 5000000));
    await r.payPayslip(payslipId: s.id, accountId: acc, amount: s.remaining, date: '2025-04-05');
    expect((await r.payslipOf(ali, 1404, 1))!.remaining, 0);
    expect((await r.accounts()).single.balance, 98000000 - s.calc.net);
    final cat = (await r.categories()).firstWhere((c) => c.name == 'حقوق و دستمزد');
    expect((await r.transactions()).where((t) => t.categoryId == cat.id).length, 3); // advance + 2 payments

    // A payslip with payments cannot be deleted; a final one is not recalculated until reopened.
    expect(await r.deletePayslip(s.id), isNotNull);
    await r.setPayslipStatus(s.id, 'final');
    await expectLater(r.savePayslip(e, 1404, 1), throwsA(isA<StateError>()));
    await r.setPayslipStatus(s.id, 'draft');
    await r.savePayslip(e, 1404, 1, items: items);

    // A person with payslips is made inactive instead of deleted.
    expect(await r.deleteEmployee(ali), contains('غیرفعال'));
    expect((await r.employees(onlyActive: true)), isEmpty);
    final bob = await r.saveEmployee(name: 'بی‌فیش');
    await r.saveAttendance(employeeId: bob, date: '2025-03-22', inTime: '08:00', outTime: '12:00');
    expect(await r.deleteEmployee(bob), isNull);
    expect((await r.employees()).length, 1);
    expect(await r.attendanceOf(bob), isEmpty);

    // Contract person: the payslips count against the contract total.
    final con = await r.saveEmployee(name: 'پیمانکار', payType: 'contract', base: 60000000, contractMonths: 6);
    final ce = (await r.employee(con))!;
    await r.savePayslip(ce, 1404, 1);
    await r.savePayslip(ce, 1404, 2, manualBase: 25000000);
    final sum = await r.contractSummary(ce);
    expect((sum.total, sum.accrued, sum.remaining), (60000000, 35000000, 25000000));
  });

  test('closed periods lock the time clock too; employees and payslips are logged and need payroll rights', () async {
    final r = await newRepo();
    final id = await r.saveEmployee(name: 'x');
    await r.setSetting(lockSettingKey, '2025-03-31');
    await expectLater(r.saveAttendance(employeeId: id, date: '2025-03-10', inTime: '08:00', outTime: '16:00'), throwsA(isA<AccessDenied>()));
    await r.saveAttendance(employeeId: id, date: '2025-04-10', inTime: '08:00', outTime: '16:00');
    // Rights: only payroll editors write the payroll tables.
    final seller = Access({'payroll.view', 'invoices.edit'});
    expect(seller.canWriteTable('employees'), isFalse);
    expect(seller.canWriteTable('payslips'), isFalse);
    expect(Access({'payroll.edit'}).canWriteTable('attendance'), isTrue);
    expect(Access({'payroll.edit'}).canWriteTable('transactions'), isTrue);
    expect(auditTables.containsKey('payslips'), isTrue);
  });

  test('the expression language compares and chooses', () {
    expect(Expr.evaluate('if(3 > 2, 10, 20)', {}), 10);
    expect(Expr.evaluate('if(2 >= 3, 10, 20)', {}), 20);
    expect(Expr.evaluate('1 + (5 == 5)', {}), 2);
    expect(Expr.evaluate('(4 != 4) * 7', {}), 0);
    expect(Expr.evaluate('x <= 3', {'x': 3}), 1);
  });

  test('time clock across devices: hours survive syncs, and a closed entry is never reopened by a device whose clock is behind', () async {
    final a = await newRepo(), b = await newRepo();
    a.companyId = b.companyId = 'c1';
    final sa = SyncService(CompanyManager.forRepos({'c1': a}, DevicePrefs.memory()));
    final sb = SyncService(CompanyManager.forRepos({'c1': b}, DevicePrefs.memory()));
    await sb.startServer(port: 0);
    await sa.setPairCode('1');
    await sb.setPairCode('1');
    try {
      final id = await a.saveEmployee(name: 'کارگر', payType: 'hourly', base: 100000);
      await a.saveAttendance(employeeId: id, date: '2025-04-01', inTime: '08:00', outTime: '12:00');
      await a.clockIn(id, now: DateTime(2025, 4, 2, 8));
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      expect((await b.attendanceOf(id)).length, 2);
      await b.clockOut(id, now: DateTime(2025, 4, 2, 16));
      await b.saveAttendance(employeeId: id, date: '2025-04-03', inTime: '09:00', outTime: '13:00');
      await a.saveAttendance(employeeId: id, date: '2025-04-04', inTime: '09:00', outTime: '17:00');
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      for (final r in [a, b]) {
        expect((await r.attendanceOf(id)).map((e) => (e.date, e.minutes)).toList(), [('2025-04-01', 240), ('2025-04-02', 480), ('2025-04-03', 240), ('2025-04-04', 480)]);
      }
      // Device A's copy of the open entry is "newer" by its clock: it still must not undo the clock-out.
      final open = (await a.attendanceOf(id)).firstWhere((e) => e.date == '2025-04-02');
      final row = (await a.store.raw.query('attendance', where: 'id=?', whereArgs: [open.id])).single;
      final stale = {...row, 'out_time': '', 'minutes': 0, 'updated_at': (row['updated_at'] as int) + 3600000, 'device_id': 'zzz-device'}..remove('seq');
      final applied = await a.store.applyRemote({'attendance': [stale]});
      expect(applied, 0);
      expect((await a.attendanceOf(id)).firstWhere((e) => e.date == '2025-04-02').minutes, 480);
      // The other way round: an older closed version does close a newer open one.
      final openRow = {...row, 'out_time': '', 'minutes': 0, 'id': 'open-1', 'updated_at': (row['updated_at'] as int) + 7200000}..remove('seq');
      await a.store.applyRemote({'attendance': [openRow]});
      final closedOlder = {...openRow, 'out_time': '16:00', 'minutes': 480, 'updated_at': (row['updated_at'] as int) + 1000, 'device_id': 'aaa-device'};
      expect(await a.store.applyRemote({'attendance': [closedOlder]}), 1);
      expect((await a.store.raw.query('attendance', where: "id='open-1'")).single['out_time'], '16:00');
      // A real deletion still wins by time.
      final gone = {...closedOlder, 'deleted': 1, 'updated_at': (row['updated_at'] as int) + 9000000};
      await a.store.applyRemote({'attendance': [gone]});
      expect((await a.store.raw.query('attendance', where: "id='open-1'")).single['deleted'], 1);
    } finally {
      await sb.stopServer();
    }
  });

  test('the same person entered on two devices: after syncing they show twice, and merging brings the hours together', () async {
    final a = await newRepo(), b = await newRepo();
    a.companyId = b.companyId = 'c1';
    final sa = SyncService(CompanyManager.forRepos({'c1': a}, DevicePrefs.memory()));
    final sb = SyncService(CompanyManager.forRepos({'c1': b}, DevicePrefs.memory()));
    await sb.startServer(port: 0);
    await sa.setPairCode('1');
    await sb.setPairCode('1');
    try {
      final onA = await a.saveEmployee(name: 'کارگر', payType: 'hourly', base: 100000);
      final onB = await b.saveEmployee(name: 'کارگر', payType: 'hourly', base: 100000);
      await a.saveAttendance(employeeId: onA, date: '2025-04-01', inTime: '08:00', outTime: '12:00');
      await a.saveAttendance(employeeId: onA, date: '2025-04-02', inTime: '08:00', outTime: '12:00');
      await b.saveAttendance(employeeId: onB, date: '2025-04-03', inTime: '08:00', outTime: '12:00');
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      for (final r in [a, b]) {
        expect((await r.employees()).length, 2); // the same name twice
        final dups = await r.duplicateEmployees();
        expect(dups.single.length, 2);
        expect(((await r.attendanceCounts())[onA], (await r.attendanceCounts())[onB]), (2, 1));
      }
      // Merge on B: everything under the person with more entries; the other is gone on both devices.
      await expectLater(b.mergeEmployees(onA, onA), throwsA(isA<StateError>()));
      await b.mergeEmployees(onA, onB);
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      for (final r in [a, b]) {
        expect((await r.employees()).map((e) => e.id), [onA]);
        expect(await r.duplicateEmployees(), isEmpty);
        expect((await r.attendanceOf(onA)).length, 3);
      }
      // Two payslips for the same month cannot be merged silently.
      final x = await a.saveEmployee(name: 'نفر', payType: 'monthly', base: 1);
      final y = await a.saveEmployee(name: 'نفر', payType: 'monthly', base: 1);
      await a.savePayslip((await a.employee(x))!, 1404, 1);
      await a.savePayslip((await a.employee(y))!, 1404, 1);
      await expectLater(a.mergeEmployees(x, y), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('1404/1'))));
      await a.savePayslip((await a.employee(y))!, 1404, 2);
      await a.deletePayslip((await a.payslipOf(y, 1404, 1))!.id);
      await a.mergeEmployees(x, y);
      expect((await a.payslipsOf(x)).map((s) => s.month).toSet(), {1, 2});
    } finally {
      await sb.stopServer();
    }
  });
}
