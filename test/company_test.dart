import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/sync/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Directory tempDir() => Directory.systemTemp.createTempSync('acc_co');

Future<CompanyManager> open(Directory d) => CompanyManager.open(dir: d, factory: databaseFactoryFfi);

void main() {
  setUpAll(sqfliteFfiInit);

  test('a fresh install gets one seeded company', () async {
    final m = await open(tempDir());
    expect(m.companies.length, 1);
    expect(m.activeInfo.name, 'شرکت من');
    expect((await m.active.accounts()).single.name, 'صندوق');
    expect((await m.active.categories(kind: 'expense')).length, greaterThan(3));
    await m.dispose_();
  });

  test('companies are isolated and survive a restart', () async {
    final dir = tempDir();
    var m = await open(dir);
    final firstId = m.activeId;
    await m.active.saveParty(name: 'فقط در شرکت اول');
    final second = await m.create('فروشگاه دوم', seed: false, activate: true);
    expect(m.activeId, second.id);
    expect(await m.active.parties(), isEmpty); // nothing leaks from the first company
    expect(await m.active.accounts(), isEmpty); // not seeded
    await m.active.saveParty(name: 'فقط در شرکت دوم');
    await m.dispose_();

    m = await open(dir);
    expect(m.companies.map((c) => c.name), ['شرکت من', 'فروشگاه دوم']);
    expect(m.activeId, second.id); // the active company is remembered
    expect((await m.active.parties()).single.name, 'فقط در شرکت دوم');
    await m.switchTo(firstId);
    expect((await m.active.parties()).single.name, 'فقط در شرکت اول');
    await m.dispose_();
  });

  test('rename, delete and the last-company rule', () async {
    final dir = tempDir();
    final m = await open(dir);
    final a = m.activeId;
    final b = (await m.create('دوم', activate: true)).id;
    await m.rename(b, '  نام تازه  ');
    expect(m.companies.firstWhere((c) => c.id == b).name, 'نام تازه');
    final file = File(p.join(dir.path, m.companies.firstWhere((c) => c.id == b).file));
    expect(file.existsSync(), isTrue);

    await m.delete(b); // deleting the active one falls back to another
    expect(m.activeId, a);
    expect(file.existsSync(), isFalse);
    expect(() => m.delete(a), throwsStateError); // never zero companies
    await m.dispose_();
  });

  test('the single database of an older version becomes the first company and keeps its settings', () async {
    final dir = tempDir();
    // Old layout: accounting.db with the business name, theme and pair code inside.
    final old = await AppDb.open(path: p.join(dir.path, 'accounting.db'), factory: databaseFactoryFfi);
    await Repo(old).setSetting('business_name', 'فروشگاه قدیمی');
    await Repo(old).saveParty(name: 'مشتری قدیمی');
    await old.setMeta('theme_mode', 'dark');
    await old.setMeta('print_paper', 'a5');
    await old.setMeta('pair_code', '123456');
    await old.close();

    final m = await open(dir);
    expect(m.companies.single.name, 'فروشگاه قدیمی');
    expect(m.companies.single.file, 'accounting.db');
    expect((await m.active.parties()).single.name, 'مشتری قدیمی');
    expect(m.prefs.get('theme_mode'), 'dark');
    expect(m.active.printSettings.paper, 'a5');
    expect(m.prefs.get('pair_code'), '123456');
    await m.dispose_();
  });

  test('device preferences are shared by all companies and stored in prefs.json', () async {
    final dir = tempDir();
    var m = await open(dir);
    await m.active.setPrint(m.active.printSettings.copyWith(paper: 'a5', landscape: true));
    final other = await m.create('دیگر', activate: true);
    expect(m.active.printSettings.paper, 'a5'); // device-wide: every company sees it
    await m.active.setPrint(m.active.printSettings.copyWith(paper: 'a4'));
    expect((await m.repoFor(m.companies.first.id))!.printSettings.paper, 'a4'); // ...even one that was already open
    await m.active.setPrint(m.active.printSettings.copyWith(paper: 'a5'));
    await m.dispose_();
    m = await open(dir);
    await m.switchTo(other.id);
    expect(m.active.printSettings.paper, 'a5');
    expect(m.active.printSettings.landscape, isTrue);
    await m.dispose_();
  });

  group('sync between two devices with several companies', () {
    late CompanyManager devA, devB;
    late SyncService sa, sb;

    setUp(() async {
      devA = await open(tempDir());
      devB = await open(tempDir());
      sa = SyncService(devA);
      sb = SyncService(devB);
      await sb.startServer(port: 0);
      await sa.setPairCode('4321');
      await sb.setPairCode('4321');
    });

    tearDown(() async {
      await sb.stopServer();
      await devA.dispose_();
      await devB.dispose_();
    });

    test('companies with different ids are refused until linked; then data flows both ways', () async {
      await devA.active.saveParty(name: 'از ویندوز');
      await devB.active.saveParty(name: 'از اندروید');
      // Different identities: the other device does not know this company.
      await expectLater(sa.syncWith(devA.active, '127.0.0.1', port: sb.port!), throwsA(isA<SyncException>()));

      // The other device lists its companies and the user says "that is the same company".
      final theirs = await sa.fetchCompanies('127.0.0.1', port: sb.port!);
      expect(theirs.single.$2, 'شرکت من');
      expect(await devA.adoptId(devA.activeId, theirs.single.$1), isTrue);
      expect(devA.active.companyId, theirs.single.$1);

      final r = await sa.syncWith(devA.active, '127.0.0.1', port: sb.port!);
      expect(r.received, greaterThan(0));
      expect((await devA.active.parties()).map((e) => e.name).toSet(), {'از ویندوز', 'از اندروید'});
      expect((await devB.active.parties()).map((e) => e.name).toSet(), {'از ویندوز', 'از اندروید'});
    });

    test('a company can be copied from the other device and only that company syncs', () async {
      final shop = await devB.create('فروشگاه', seed: false);
      final shopRepo = (await devB.repoFor(shop.id))!;
      await shopRepo.saveParty(name: 'فقط فروشگاه');
      await devB.active.saveParty(name: 'شرکت دیگر'); // must not travel

      final copy = await devA.create(shop.name, seed: false, activate: true, id: shop.id);
      expect(copy.id, shop.id);
      await sa.syncWith(devA.active, '127.0.0.1', port: sb.port!);
      expect((await devA.active.parties()).single.name, 'فقط فروشگاه');

      // Changes made on A reach B's copy of that company, not B's other company.
      await devA.active.saveParty(name: 'جدید روی A');
      await sa.syncWith(devA.active, '127.0.0.1', port: sb.port!);
      expect((await shopRepo.parties()).map((e) => e.name).toSet(), {'فقط فروشگاه', 'جدید روی A'});
      expect((await devB.active.parties()).single.name, 'شرکت دیگر');
    });

    test('wrong pairing code is refused for the company list too', () async {
      await sa.setPairCode('0000');
      await expectLater(sa.fetchCompanies('127.0.0.1', port: sb.port!), throwsA(isA<SyncException>()));
    });

    test('adopting an id that already exists is refused', () async {
      final other = await devA.create('دوم', seed: false);
      expect(await devA.adoptId(devA.activeId, other.id), isFalse);
    });
  });
}

extension on CompanyManager {
  /// Closes every database (the real dispose is for the widget tree).
  Future<void> dispose_() async {
    for (final c in companies) {
      final r = await repoFor(c.id);
      await r?.store.close();
    }
  }
}
