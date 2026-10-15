import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/csv.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/ui/products_page.dart';
import 'package:simple_accounting/util/format.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_price');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

Future<Product> byName(Repo r, String n) async => (await r.products()).firstWhere((p) => p.name == n);

void main() {
  test('percent changes: both prices or one, rounding, dollar prices follow, and bad input is refused', () async {
    final r = await newRepo();
    await r.saveProduct(name: 'الف', salePrice: 1000, buyPrice: 800, usdSale: 10);
    await r.saveProduct(name: 'ب', salePrice: 5000, buyPrice: 4000);
    expect(Repo.changeByPercent(1000, 10), 1100);
    expect(Repo.changeByPercent(1000, -10), 900);
    expect(Repo.changeByPercent(1234, 10, roundTo: 100), 1400); // 1357.4 -> 1400
    await expectLater(r.adjustPrices(-100), throwsA(isA<StateError>()));

    expect(await r.adjustPrices(10), 2);
    var a = await byName(r, 'الف');
    expect((a.salePrice, a.buyPrice), (1100, 880));
    expect(a.usdSale, closeTo(11, 1e-9)); // the dollar price moves with it
    // Only the sale price, only some products.
    expect(await r.adjustPrices(-50, buy: false, ids: {a.id}), 1);
    a = await byName(r, 'الف');
    expect((a.salePrice, a.buyPrice), (550, 880));
    final b = await byName(r, 'ب');
    expect((b.salePrice, b.buyPrice), (5500, 4400));
    // With rounding.
    await r.adjustPrices(3, sale: true, buy: false, roundTo: 100);
    expect((await byName(r, 'ب')).salePrice, 5700); // 5665 -> 5700
  });

  test('the dollar rate reprices every product that has a dollar price', () async {
    final r = await newRepo();
    await r.saveProduct(name: 'دلاری', salePrice: 1, buyPrice: 1, usdSale: 12, usdBuy: 10);
    await r.saveProduct(name: 'نیمه', salePrice: 7, buyPrice: 500, usdSale: 2); // only the sale price is in dollars
    await r.saveProduct(name: 'ریالی', salePrice: 999, buyPrice: 888);
    expect(r.usdRate, 0);
    await expectLater(r.applyUsdRate(0), throwsA(isA<StateError>()));
    expect(await r.applyUsdRate(60000), 2);
    expect(r.usdRate, 60000);
    var d = await byName(r, 'دلاری');
    expect((d.salePrice, d.buyPrice), (720000, 600000));
    var h = await byName(r, 'نیمه');
    expect((h.salePrice, h.buyPrice), (120000, 500));
    expect((await byName(r, 'ریالی')).salePrice, 999);
    expect(await r.applyUsdRate(62500.5), 2);
    d = await byName(r, 'دلاری');
    expect(d.salePrice, 750006); // 12 x 62500.5
    expect(r.usdRate, 62500.5);
    // Saving through the ordinary call keeps the dollar prices (callers that do not know them).
    await r.saveProduct(id: h.id, name: 'نیمه', salePrice: 5, buyPrice: 6);
    h = await byName(r, 'نیمه');
    expect(h.usdSale, 2);
  });

  test('spreadsheet import: dollar prices with a rate, percent columns, and a rate alone', () async {
    final r = await newRepo();
    await r.saveProduct(name: 'قدیمی', code: '1', salePrice: 1000, buyPrice: 700);
    await r.saveProduct(name: 'دلاریِ قبلی', code: '2', usdSale: 5);
    await r.applyUsdRate(100);
    expect((await byName(r, 'دلاریِ قبلی')).salePrice, 500);

    // Dollar prices + rate in the file: price = dollars x rate; the rate becomes the company's rate,
    // so the dollar product that is not in the file follows too.
    var res = await r.importProducts([
      ['نام', 'کد', 'قیمت ارزی فروش', 'قیمت ارزی خرید', 'نرخ دلار'],
      ['جدید', '3', '12', '10', '60000'],
    ]);
    expect((res.added, res.updated), (1, 0));
    final n = await byName(r, 'جدید');
    expect((n.salePrice, n.buyPrice, n.usdSale, n.usdBuy), (720000, 600000, 12.0, 10.0));
    expect(r.usdRate, 60000);
    expect((await byName(r, 'دلاریِ قبلی')).salePrice, 300000);

    // Percent column: +10% on both prices of existing products, -5% on sale only via the specific column.
    res = await r.importProducts([
      ['نام', 'کد', 'درصد تغییر قیمت'],
      ['قدیمی', '1', '10'],
    ]);
    expect((res.added, res.updated), (0, 1));
    var o = await byName(r, 'قدیمی');
    expect((o.salePrice, o.buyPrice), (1100, 770));
    res = await r.importProducts([
      ['نام', 'کد', 'درصد تغییر قیمت فروش', 'درصد تغییر قیمت خرید'],
      ['قدیمی', '1', '-50', ''],
    ]);
    o = await byName(r, 'قدیمی');
    expect((o.salePrice, o.buyPrice), (550, 770));
    // Percent on top of a price given in the same file.
    await r.importProducts([
      ['نام', 'کد', 'قیمت فروش', 'قیمت خرید', 'درصد تغییر'],
      ['قدیمی', '1', '2000', '1000', '-10'],
    ]);
    o = await byName(r, 'قدیمی');
    expect((o.salePrice, o.buyPrice), (1800, 900));
    // Persian digits and the "rate" header alone.
    await r.importProducts([
      ['نام', 'کد', 'نرخ دلار'],
      ['جدید', '3', '۷۰٬۰۰۰'],
    ]);
    expect(r.usdRate, 70000);
    expect((await byName(r, 'جدید')).salePrice, 840000);
  });

  test('export carries the dollar prices', () async {
    final r = await newRepo();
    await r.saveProduct(name: 'x', usdSale: 2.5, usdBuy: 2);
    final rows = await r.exportRows('products');
    final i = rows.first.indexOf('قیمت ارزی فروش');
    expect(rows.first[i + 1], 'قیمت ارزی خرید');
    expect(rows[1].sublist(i, i + 2), ['2.5', '2']);
  });

  testWidgets('product form: percent button and the dollar rate change the prices on the spot', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    sqfliteFfiInit();
    late Repo repo;
    await tester.runAsync(() async {
      repo = await newRepo();
      await repo.saveProduct(name: 'کالا', salePrice: 1000, buyPrice: 800);
    });
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () async => editProduct(c, repo, product: (await repo.products()).single), child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await settle();
    TextEditingController field(String label) => tester.widget<TextFormField>(find.widgetWithText(TextFormField, label)).controller!;

    // +10 % on both prices.
    await tester.enterText(find.widgetWithText(TextFormField, 'درصد'), '10');
    await tester.tap(find.text('اعمال'));
    await settle();
    expect(parseAmount(field('قیمت فروش').text), 1100);
    expect(parseAmount(field('قیمت خرید').text), 880);

    // A dollar price and a rate: the price follows, and changing the rate changes it again.
    await tester.enterText(find.widgetWithText(TextFormField, 'فروش (دلار)'), '2');
    await tester.enterText(find.widgetWithText(TextFormField, 'نرخ هر دلار'), '50000');
    await settle();
    expect(parseAmount(field('قیمت فروش').text), 100000);
    await tester.enterText(find.widgetWithText(TextFormField, 'نرخ هر دلار'), '60000');
    await settle();
    expect(parseAmount(field('قیمت فروش').text), 120000);

    await tester.tap(find.text('ذخیره'));
    await settle();
    final saved = (await tester.runAsync(repo.products))!.single;
    expect((saved.salePrice, saved.buyPrice, saved.usdSale), (120000, 880, 2.0));
    expect(repo.usdRate, 60000); // saved as the company's rate (no other dollar product to ask about)
  });
}
