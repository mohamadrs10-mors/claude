import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/csv.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_csv');
  final r = Repo(await AppDb.open(path: '${dir.path}/db.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

void main() {
  group('Csv', () {
    test('round trip with quotes, commas, newlines and Persian text', () {
      final rows = [
        ['نام', 'توضیحات'],
        ['برنج، ایرانی', 'او گفت: "عالی"'],
        ['خط\nدوم', ''],
      ];
      final text = Csv.encode(rows);
      expect(text.startsWith(Csv.bom), isTrue);
      expect(Csv.decode(text), [
        ['نام', 'توضیحات'],
        ['برنج، ایرانی', 'او گفت: "عالی"'],
        ['خط\nدوم', ''],
      ]);
    });

    test('Excel flavours: semicolon and tab separated, CRLF, blank lines, BOM', () {
      expect(Csv.decode('a;b;c\r\n1;2;3\r\n\r\n4;5;6\r\n'), [['a', 'b', 'c'], ['1', '2', '3'], ['4', '5', '6']]);
      expect(Csv.decode('a\tb\n1\t2'), [['a', 'b'], ['1', '2']]);
      expect(Csv.decode('${Csv.bom}x,y\n"1,5",2'), [['x', 'y'], ['1,5', '2']]);
      expect(Csv.decode('   \n'), isEmpty);
    });

    test('numbers in every common notation', () {
      expect(Csv.number('1,250,000'), 1250000);
      expect(Csv.number('۱.۲۵۰.۰۰۰'), 1250000);
      expect(Csv.number('۱٬۲۵۰٬۰۰۰'), 1250000);
      expect(Csv.number('12.5'), 12.5);
      expect(Csv.number('١٢٣'), 123);
      expect(Csv.number('abc'), 0);
      expect(Csv.number('-500'), -500);
    });
  });

  group('import and export', () {
    test('products: new ones are added, matching code or name is updated, bad rows skipped', () async {
      final r = await newRepo();
      await r.saveProduct(name: 'برنج', code: '1001', salePrice: 100, unit: 'کیلوگرم');
      final rows = Csv.decode('نام,کد,واحد,قیمت فروش,قیمت خرید,موجودی اولیه\n'
          'برنج ایرانی,1001,کیلوگرم,"185,000",150000,12.5\n' // matches by code
          'شکر,,کیلوگرم,60.000,50000,100\n'
          ',,,,,\n'
          'روغن,2002,,320000,,3\n');
      final res = await r.importProducts(rows);
      expect([res.added, res.updated, res.skipped], [2, 1, 0]); // the empty line is dropped by the parser
      final byName = {for (final p in await r.products()) p.name: p};
      expect(byName['برنج ایرانی']!.salePrice, 185000);
      expect(byName['برنج ایرانی']!.openingStock, 12.5);
      expect(byName['برنج ایرانی']!.code, '1001');
      expect(byName['شکر']!.salePrice, 60000); // dot as thousands separator
      expect(byName['روغن']!.unit, 'عدد'); // default unit
      expect(byName.length, 3);

      // English headers work too, and a missing name column is reported.
      await r.importProducts(Csv.decode('name,sale_price\nچای,25000'));
      expect((await r.products()).any((p) => p.name == 'چای' && p.salePrice == 25000), isTrue);
      expect(() => r.importProducts(Csv.decode('قیمت\n100\n')), throwsFormatException);
    });

    test('parties: matched by name, keeps what the file does not mention', () async {
      final r = await newRepo();
      await r.saveParty(name: 'علی', phone: '0912', note: 'قدیمی', opening: 10);
      final res = await r.importParties(Csv.decode('نام;تلفن;مانده اول دوره\nعلی;۰۹۳۵;"-2.500"\nمریم;0911;7000\n'));
      expect([res.added, res.updated], [1, 1]);
      final ps = {for (final p in await r.parties()) p.name: p};
      expect(ps['علی']!.phone, '0935');
      expect(ps['علی']!.opening, -2500);
      expect(ps['علی']!.note, 'قدیمی'); // no note column: untouched
      expect(ps['مریم']!.opening, 7000);
    });

    test('export gives a header and one row per record, importable again', () async {
      final r = await newRepo();
      await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
      await r.saveProduct(name: 'کالا، ویژه', code: '7', salePrice: 5000, buyPrice: 3000, openingStock: 2.5, unit: 'عدد');
      await r.saveParty(name: 'شخص', phone: '0912');
      final prod = await r.exportRows('products');
      expect(prod.first.first, 'نام');
      expect(prod[1].take(4).toList(), ['کالا، ویژه', '7', 'عدد', '5000']);
      expect(prod[1][5], '2.5');

      // Writing and reading the file gives back the same products.
      final other = await newRepo();
      await other.importProducts(Csv.decode(Csv.encode(prod)));
      final p = (await other.products()).single;
      expect([p.name, p.code, p.salePrice, p.buyPrice, p.openingStock], ['کالا، ویژه', '7', 5000, 3000, 2.5]);

      expect((await r.exportRows('parties'))[1].first, 'شخص');
      expect((await r.exportRows('transactions')).length, 1); // header only
      expect((await r.exportRows('invoices')).first.length, 10);
      expect(() => r.exportRows('nope'), throwsArgumentError);
    });
  });
}
