import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shamsi_date/shamsi_date.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/payroll_repo.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/ui/payroll_page.dart';
import 'package:simple_accounting/util/format.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 150));
  }
}

Widget host(Widget child) => MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: child)));

void main() {
  testWidgets('payroll screens: add people, clock in, see the payslip, add items and save/finalise/pay it', (tester) async {
    tester.view.physicalSize = const Size(1100, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sqfliteFfiInit();
    late Repo repo;
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('acc_payui');
      repo = Repo(await AppDb.open(path: '${dir.path}/x.db', factory: databaseFactoryFfi));
      await repo.init();
      await repo.saveAccount(name: 'صندوق', kind: 'cash', opening: 50000000);
    });
    await tester.pumpWidget(host(PayrollPage(repo: repo)));
    await settle(tester);

    // Employees tab: empty, then add a monthly person with a bad formula type first.
    await tester.tap(find.text('کارکنان'));
    await settle(tester);
    expect(find.textContaining('هنوز کسی ثبت نشده'), findsOneWidget);
    await tester.tap(find.text('کارمند جدید'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'نام'), 'سارا');
    await tester.enterText(find.widgetWithText(TextFormField, 'حقوق ماهانه'), '12000000');
    await tester.tap(find.text('فرمول دلخواه'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'فرمول حقوق'), 'hours *');
    await tester.tap(find.text('ذخیره'));
    await settle(tester);
    expect(find.textContaining('فرمول درست نیست'), findsOneWidget); // refused with a reason
    await tester.enterText(find.widgetWithText(TextField, 'فرمول حقوق'), 'hours * 100000 + if(ratio >= 1, 1, 0)');
    await tester.tap(find.text('ذخیره'));
    await settle(tester);
    final people = (await tester.runAsync(repo.employees))!;
    expect(people.single.payType, 'formula');
    expect(find.text('فرمول دلخواه'), findsWidgets);

    // A second person, monthly attendance-based (set up in the repo).
    late String bob;
    await tester.runAsync(() async {
      bob = await repo.saveEmployee(name: 'بابک', payType: 'monthly', base: 8000000, attendanceBased: true, overtimeRate: 1.4);
    });
    await settle(tester);
    expect(find.text('بابک'), findsOneWidget);

    // Time clock tab: clock bob in and out for today.
    await tester.tap(find.text('حضور و غیاب'));
    await settle(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await settle(tester);
    await tester.tap(find.text('بابک').last);
    await settle(tester);
    await tester.tap(find.text('ثبت دستی'));
    await settle(tester);
    final today = isoOf(DateTime.now());
    final j = Jalali.now();
    await tester.enterText(find.widgetWithText(TextField, 'ورود'), '08:00');
    await tester.enterText(find.widgetWithText(TextField, 'خروج'), '17:30');
    await tester.tap(find.text('ثبت'));
    await settle(tester);
    var entries = (await tester.runAsync(() => repo.attendanceOf(bob)))!;
    expect(entries.single.minutes, 570);
    expect(entries.single.date, today);
    expect(find.textContaining('۸:۰۰'.replaceAll('۸:۰۰', '۰۸:۰۰')), findsWidgets);
    // A wrong time is refused with a message and nothing is stored.
    await tester.tap(find.text('ثبت دستی'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'ورود'), '99:99');
    await tester.tap(find.text('ثبت'));
    await settle(tester);
    expect(find.textContaining('ساعت ورود'), findsOneWidget);
    await tester.tap(find.text('انصراف'));
    await settle(tester);

    // Payslips tab for the current month.
    await tester.tap(find.text('حقوق و فیش‌ها'));
    await settle(tester);
    expect(find.text('بابک'), findsOneWidget);
    await tester.tap(find.text('بابک'));
    await settle(tester);
    expect(find.text('فیش بابک • ${monthNames[j.month - 1]} ${faDigits('${j.year}')}'), findsOneWidget);
    expect(find.text('ذخیره‌نشده'), findsOneWidget);
    // Add a bonus and a deduction; the net follows.
    await tester.tap(find.text('افزودن (پاداش...)'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'عنوان'), 'پاداش');
    await tester.enterText(find.widgetWithText(TextFormField, 'مبلغ'), '500000');
    await tester.tap(find.text('افزودن'));
    await settle(tester);
    expect(find.text('پاداش'), findsOneWidget);
    await tester.tap(find.text('ذخیرهٔ فیش'));
    await settle(tester);
    Future<Payslip> slipOf() async => (await repo.payslipOf(bob, j.year, j.month))!;
    var slip = (await tester.runAsync(slipOf))!;
    expect(slip.status, 'draft');
    expect(slip.items.single.amount, 500000);
    expect(slip.calc.workedMin, 570);
    // On a day off (Friday by default) all of the work is overtime; otherwise what exceeds 8 hours.
    expect(slip.calc.overtimeMin, DateTime.now().weekday == 5 ? 570 : 90);
    // Finalise, then pay all of it.
    await tester.tap(find.text('نهایی کردن'));
    await settle(tester);
    slip = (await tester.runAsync(slipOf))!;
    expect(slip.isFinal, isTrue);
    await tester.tap(find.text('پرداخت').first);
    await settle(tester);
    await tester.tap(find.text('ثبت پرداخت'));
    await settle(tester);
    slip = (await tester.runAsync(slipOf))!;
    expect(slip.remaining, 0);
    expect(slip.paid, slip.calc.net);
    expect((await tester.runAsync(repo.accounts))!.single.balance, 50000000 - slip.calc.net);
  });
}
