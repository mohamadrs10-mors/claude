import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_accounting/data/app_lock.dart';
import 'package:simple_accounting/data/backup_service.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/recovery.dart';
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


  group('PIN recovery', () {
    var now = DateTime(2025, 1, 1, 12);
    AppLock make({DevicePrefs? prefs, String? master}) => AppLock(prefs ?? DevicePrefs.memory(), clock: () => now, masterHash: master);

    test('setting a PIN returns a recovery key that is stored only as a hash', () async {
      final prefs = DevicePrefs.memory();
      final lock = make(prefs: prefs);
      final key = await lock.setPin('a', '1234');
      expect(key, matches(RegExp(r'^[A-HJKMNP-Z2-9]{4}(-[A-HJKMNP-Z2-9]{4}){3}$')));
      expect(lock.hasRecoveryKey('a'), isTrue);
      expect(prefs.get('lockrk_a')!.contains(key), isFalse);
      expect(prefs.get('lockrk_a')!.contains(Recovery.normalize(key)), isFalse);
      expect(make(prefs: prefs).hasRecoveryKey('a'), isTrue); // survives a restart
    });

    test('the recovery key resets the PIN; case and dashes do not matter; the old key and PIN die', () async {
      final lock = make();
      final key = await lock.setPin('a', '1111');
      lock.lockAll();
      final typed = key.toLowerCase().replaceAll('-', ' ');
      final fresh = await lock.recover('a', typed, '2222');
      expect(fresh, isNotNull);
      expect(fresh, isNot(key));
      expect(lock.isUnlocked('a'), isTrue); // recovering signs you in
      lock.lockAll();
      expect(lock.unlock('a', '1111'), isFalse);
      expect(lock.unlock('a', '2222'), isTrue);
      lock.lockAll();
      expect(await lock.recover('a', key, '3333'), isNull); // the used key is gone
      expect(await lock.recover('a', fresh!, '3333'), isNotNull);
    });

    test('wrong keys are limited like wrong PINs and a bad new PIN is refused', () async {
      now = DateTime(2025, 1, 1, 12);
      final lock = make();
      final key = await lock.setPin('a', '1111');
      lock.lockAll();
      for (var i = 0; i < 5; i++) {
        expect(await lock.recover('a', 'AAAA-BBBB-CCCC-DDDD', '2222'), isNull);
      }
      expect(lock.waitSeconds, greaterThan(25));
      expect(await lock.recover('a', key, '2222'), isNull); // even the right key waits
      now = now.add(const Duration(seconds: 31));
      await expectLater(lock.recover('a', key, '12'), throwsFormatException);
      expect(await lock.recover('a', key, '2222'), isNotNull);
    });

    test('a PIN made before recovery keys existed can get one while signed in', () async {
      final prefs = DevicePrefs.memory();
      final lock = make(prefs: prefs);
      // Old layout: only lock_<id>, no key.
      final salt = Recovery.newSalt();
      await lock.setPin('a', '1234');
      await prefs.set('lockrk_a', ''); // pretend it never had one
      expect(lock.hasPin('a'), isTrue);
      expect(lock.hasRecoveryKey('a'), isFalse);
      expect(await lock.recover('a', 'ANYTHING', '2222'), isNull);
      expect(salt, isNotEmpty);
      final key = await lock.newRecoveryKey('a');
      expect(lock.hasRecoveryKey('a'), isTrue);
      expect(await lock.recover('a', key, '5555'), isNotNull);
    });

    test('clearing the PIN also clears the recovery key', () async {
      final lock = make();
      await lock.setPin('a', '1234');
      await lock.clearPin('a');
      expect(lock.hasRecoveryKey('a'), isFalse);
    });

    test('the owner master phrase works for any company, only in a build that has its hash', () async {
      const phrase = 'MASTER-TEST-PHRASE-2025';
      final enabled = make(master: Recovery.masterHash(phrase));
      expect(enabled.masterEnabled, isTrue);
      await enabled.setPin('a', '1111');
      await enabled.setPin('b', '2222');
      enabled.lockAll();
      expect(await enabled.recover('a', 'wrong-phrase', '9999'), isNull);
      expect(await enabled.recover('a', 'master test phrase 2025', '9999'), isNotNull); // normalised
      enabled.lockAll();
      expect(enabled.unlock('a', '9999'), isTrue);
      expect(await enabled.recover('b', phrase, '8888'), isNotNull); // another company, no stored key needed

      // A normal build has no master recovery at all, even if the phrase is known.
      final plain = make();
      expect(plain.masterEnabled, isFalse);
      await plain.setPin('c', '1111');
      plain.lockAll();
      expect(await plain.recover('c', phrase, '9999'), isNull);
    });

    test('helper functions', () {
      expect(Recovery.normalize(' ab-cd 12!'), 'ABCD12');
      expect(Recovery.masterHash('abc-def'), Recovery.masterHash('ABCDEF'));
      expect(Recovery.masterHash('abc'), isNot(Recovery.masterHash('abd')));
      expect(Recovery.masterHash('x'), hasLength(64));
      expect(Recovery.matches(Recovery.store('K7QX-2M9P'), 'k7qx 2m9p'), isTrue);
      expect(Recovery.matches(Recovery.store('K7QX-2M9P'), 'K7QX-2M9Q'), isFalse);
      expect(Recovery.matches('', 'K7QX'), isFalse);
      expect(Recovery.matches('garbage', 'K7QX'), isFalse);
      expect(Recovery.newKey(groups: 6), matches(RegExp(r'^([A-Z2-9]{4}-){5}[A-Z2-9]{4}$')));

      final prefs = <String, dynamic>{'theme_mode': 'dark', 'lock_a': 'x', 'lockrk_a': 'y', 'lock_b': 'x', 'lockrk_b': 'y'};
      expect(Recovery.stripLocks(prefs, companyId: 'a'), 2);
      expect(prefs.keys.toSet(), {'theme_mode', 'lock_b', 'lockrk_b'});
      expect(Recovery.stripLocks(prefs), 2);
      expect(prefs, {'theme_mode': 'dark'});
      expect(Recovery.stripLocks(prefs), 0);
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
