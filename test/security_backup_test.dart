import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_accounting/data/app_lock.dart';
import 'package:simple_accounting/data/backup_service.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('AppLock', () {
    var now = DateTime(2025, 1, 1, 12);
    AppLock make([DevicePrefs? prefs]) => AppLock(prefs ?? DevicePrefs.memory(), clock: () => now);

    test('no PIN means open; with a PIN the company is locked until the right one is typed', () async {
      final lock = make();
      expect(lock.hasPin('a'), isFalse);
      expect(lock.isUnlocked('a'), isTrue);

      await lock.setPin('a', '1234');
      expect(lock.hasPin('a'), isTrue);
      expect(lock.isUnlocked('a'), isTrue); // the person who set it is in
      lock.lockAll();
      expect(lock.isUnlocked('a'), isFalse);
      expect(lock.isUnlocked('b'), isTrue); // other companies are unaffected

      expect(lock.unlock('a', '0000'), isFalse);
      expect(lock.isUnlocked('a'), isFalse);
      expect(lock.unlock('a', '1234'), isTrue);
      expect(lock.isUnlocked('a'), isTrue);
    });

    test('the PIN is stored salted and hashed, and survives a restart', () async {
      final prefs = DevicePrefs.memory();
      final lock = make(prefs);
      await lock.setPin('a', '987654');
      final stored = prefs.get('lock_a')!;
      expect(stored.contains('987654'), isFalse);
      expect(stored.split(':').length, 2);
      // Two companies with the same PIN do not share a hash.
      await lock.setPin('b', '987654');
      expect(prefs.get('lock_b'), isNot(stored));

      final again = make(prefs); // a new session starts locked
      expect(again.isUnlocked('a'), isFalse);
      expect(again.check('a', '987654'), isTrue);
      expect(again.check('a', '987655'), isFalse);
    });

    test('only 4 to 8 digits are accepted; clearing removes the lock', () async {
      final lock = make();
      for (final bad in ['123', '123456789', 'abcd', '12 34', '']) {
        await expectLater(lock.setPin('a', bad), throwsFormatException, reason: bad);
      }
      await lock.setPin('a', '12345678');
      await lock.clearPin('a');
      expect(lock.hasPin('a'), isFalse);
      expect(lock.isUnlocked('a'), isTrue);
    });

    test('five wrong attempts pause trying for thirty seconds', () async {
      now = DateTime(2025, 1, 1, 12);
      final lock = make();
      await lock.setPin('a', '1111');
      lock.lockAll();
      for (var i = 0; i < 5; i++) {
        expect(lock.unlock('a', '9999'), isFalse);
      }
      expect(lock.waitSeconds, greaterThan(25));
      expect(lock.unlock('a', '1111'), isFalse); // even the right PIN is refused while waiting
      now = now.add(const Duration(seconds: 31));
      expect(lock.waitSeconds, 0);
      expect(lock.unlock('a', '1111'), isTrue);
    });

    test('the app locks itself after being in the background for a while', () async {
      now = DateTime(2025, 1, 1, 12);
      final lock = make();
      await lock.setPin('a', '1234');
      lock.appPaused();
      now = now.add(const Duration(seconds: 30));
      lock.appResumed();
      expect(lock.isUnlocked('a'), isTrue); // a short trip to another app
      lock.appPaused();
      now = now.add(const Duration(minutes: 3));
      lock.appResumed();
      expect(lock.isUnlocked('a'), isFalse);
    });
  });

  group('BackupService', () {
    Future<(CompanyManager, BackupService)> setup() async {
      final dir = Directory.systemTemp.createTempSync('acc_bk');
      final m = await CompanyManager.open(dir: dir, factory: databaseFactoryFfi);
      return (m, BackupService(m));
    }

    test('writes a restorable backup and keeps only the newest ones', () async {
      final (m, b) = await setup();
      await m.active.saveParty(name: 'ثبت‌شده');
      await b.setKeep(3);
      final base = DateTime(2025, 3, 1, 10);
      final files = <File>[];
      for (var i = 0; i < 5; i++) {
        files.add(await b.backupNow(m.activeId, now: base.add(Duration(days: i))));
      }
      final list = await b.list(m.activeId);
      expect(list.length, 3);
      expect(list.first.name, 'backup-2025-03-05_100000.json'); // newest first
      expect(files.first.existsSync(), isFalse); // oldest were pruned

      // A backup restores into another company.
      final other = await m.create('دیگر', seed: false);
      final repo = (await m.repoFor(other.id))!;
      final n = await repo.importJson(await list.first.file.readAsString());
      expect(n, greaterThan(0));
      expect((await repo.parties()).single.name, 'ثبت‌شده');
    });

    test('runs once a day for every company, and can be switched off', () async {
      final (m, b) = await setup();
      await m.create('دوم', seed: false);
      final day = DateTime(2025, 5, 10, 8);
      expect(await b.runIfDue(now: day), 2); // one per company
      expect(await b.runIfDue(now: day.add(const Duration(hours: 5))), 0); // same day
      expect(await b.runIfDue(now: day.add(const Duration(days: 1))), 2); // next day
      expect(Directory(p.join(m.dir.path, 'backups')).listSync().length, 2);

      await b.setEnabled(false);
      expect(await b.runIfDue(now: day.add(const Duration(days: 2))), 0);
      expect(b.enabled, isFalse);
    });
  });
}
