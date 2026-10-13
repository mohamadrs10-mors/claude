import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/app_lock.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/ui/lock_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('forgotten PIN: wrong key is refused, the right key sets a new PIN and shows a new key', (tester) async {
    sqfliteFfiInit();
    late CompanyManager companies;
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('acc_lockui');
      final repo = Repo(await AppDb.open(path: '${dir.path}/x.db', factory: databaseFactoryFfi));
      companies = CompanyManager.forRepos({'c1': repo}, DevicePrefs.memory());
    });
    final lock = AppLock(DevicePrefs.memory());
    final key = await lock.setPin('c1', '1234');
    lock.lockAll();

    await tester.pumpWidget(MaterialApp(home: LockScreen(lock: lock, companies: companies)));
    // The normal way in.
    await tester.enterText(find.byType(TextField).first, '9999');
    await tester.tap(find.text('ورود'));
    await tester.pump();
    expect(lock.isUnlocked('c1'), isFalse);
    expect(find.text('رمز اشتباه است.'), findsOneWidget);

    await tester.tap(find.text('رمز را فراموش کرده‌ام'));
    await tester.pumpAndSettle();
    expect(find.text('بازیابی رمز'), findsOneWidget);

    Future<void> submit(String k, String pin, String repeat) async {
      final fields = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
      await tester.enterText(fields.at(0), k);
      await tester.enterText(fields.at(1), pin);
      await tester.enterText(fields.at(2), repeat);
      await tester.tap(find.text('تغییر رمز'));
      await tester.pumpAndSettle();
    }

    await submit('AAAA-BBBB-CCCC-DDDD', '5678', '5678');
    expect(find.text('کلید اشتباه است.'), findsOneWidget);
    expect(lock.isUnlocked('c1'), isFalse);

    await submit(key, '5678', '1111'); // the two PINs differ
    expect(find.text('تکرار رمز یکسان نیست.'), findsOneWidget);

    await submit(key, '5678', '5678');
    expect(find.text('کلید بازیابی تازه'), findsOneWidget); // the new key is shown
    expect(lock.isUnlocked('c1'), isTrue);
    // The dialog cannot be closed before confirming.
    final close = find.widgetWithText(FilledButton, 'بستن');
    expect(tester.widget<FilledButton>(close).onPressed, isNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(tester.widget<FilledButton>(close).onPressed, isNotNull);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text('کلید بازیابی تازه'), findsNothing);

    lock.lockAll();
    expect(lock.unlock('c1', '1234'), isFalse);
    expect(lock.unlock('c1', '5678'), isTrue);
  });
}
