import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/costing.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/ui/common.dart';
import 'package:simple_accounting/ui/thousands_formatter.dart';
import 'package:simple_accounting/util/format.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TextEditingValue type(ThousandsFormatter f, TextEditingValue old, String text, [int? cursor]) =>
    f.formatEditUpdate(old, TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor ?? text.length)));

void main() {
  setUp(() {
    thousandsSep = '.';
    currencyLabel = 'تومان';
  });
  tearDown(() {
    thousandsSep = '.';
    currencyLabel = 'تومان';
  });

  group('money display and parsing', () {
    test('groups digits in threes with the chosen separator', () {
      expect(money(1234567), '۱.۲۳۴.۵۶۷');
      expect(money(-999), '-۹۹۹');
      expect(money(1000), '۱.۰۰۰');
      expect(money(0), '۰');
      thousandsSep = ',';
      expect(money(1234567), '۱,۲۳۴,۵۶۷');
      expect(moneyC(5000), '۵,۰۰۰ تومان');
    });

    test('parses what the formatter produces, in both modes', () {
      expect(parseAmount('۱.۲۳۴.۵۶۷'), 1234567);
      expect(parseMoneyNum('۱.۲۳۴.۵۶۷'), 1234567);
      expect(parseMoneyNum('۱.۲۳۴.۵۶۷٫۵'), 1234567.5);
      expect(parseMoneyNum('1.250.000'), 1250000);
      thousandsSep = ',';
      expect(parseMoneyNum('۱,۲۳۴,۵۶۷'), 1234567);
      expect(parseMoneyNum('1,250.75'), 1250.75);
      expect(parseMoneyNum('۱,۲۵۰٫۷۵'), 1250.75);
      expect(parseMoneyNum(''), 0);
    });

    test('inputNum and plainNum', () {
      expect(inputNum(1234567), '۱.۲۳۴.۵۶۷');
      expect(inputNum(1234.5), '۱.۲۳۴٫۵');
      expect(inputNum(1000, decimals: 0), '۱.۰۰۰');
      expect(inputNum(-2500), '-۲.۵۰۰');
      expect(plainNum(12.5), '12.5');
      expect(plainNum(1000), '1000');
      expect(numText(1500), '۱.۵۰۰');
    });
  });

  group('ThousandsFormatter', () {
    test('formats while typing and accepts Persian, Arabic and Latin digits', () {
      final f = ThousandsFormatter();
      var v = TextEditingValue.empty;
      for (final t in ['1', '12', '123', '1234', '12345', '123456', '1234567']) {
        v = type(f, v, t);
      }
      expect(v.text, '۱.۲۳۴.۵۶۷');
      expect(v.selection.baseOffset, v.text.length);
      expect(type(f, v, '۱۲۳۴۵۶۷۸').text, '۱۲.۳۴۵.۶۷۸');
      expect(type(f, v, '١٢٣٤').text, '۱.۲۳۴');
      // Deleting a digit regroups.
      expect(type(f, v, '۱.۲۳۴.۵۶').text, '۱۲۳.۴۵۶');
      expect(type(f, v, '').text, '');
    });

    test('ignores letters and stray separators, strips leading zeros', () {
      final f = ThousandsFormatter();
      expect(type(f, TextEditingValue.empty, '12ab3,4.5').text, '۱۲.۳۴۵');
      expect(type(f, TextEditingValue.empty, '000123').text, '۱۲۳');
      expect(type(f, TextEditingValue.empty, '0').text, '۰');
      expect(type(f, TextEditingValue.empty, '-5').text, '۵'); // no negatives by default
    });

    test('keeps the cursor beside the edited digit', () {
      final f = ThousandsFormatter();
      // "۱.۲۳۴" with a digit typed after the first one: "۱۹.۲۳۴" -> raw "1.9234", cursor after 9.
      final v = type(f, TextEditingValue.empty, '1.9234', 3);
      expect(v.text, '۱۹.۲۳۴');
      expect(v.selection.baseOffset, 2); // right after ۹
      // Typing at the very start.
      final w = type(f, TextEditingValue.empty, '91234', 1);
      expect(w.text, '۹۱.۲۳۴');
      expect(w.selection.baseOffset, 1);
    });

    test('negative and decimal modes', () {
      final neg = ThousandsFormatter(negative: true);
      expect(type(neg, TextEditingValue.empty, '-1234').text, '-۱.۲۳۴');
      expect(type(neg, TextEditingValue.empty, '-').text, '-');
      expect(type(neg, TextEditingValue.empty, '12-3').text, '۱۲۳');

      final dec = ThousandsFormatter(decimal: true);
      expect(type(dec, TextEditingValue.empty, '1234567/5').text, '۱.۲۳۴.۵۶۷٫۵');
      expect(type(dec, TextEditingValue.empty, '1234٫25٫7').text, '۱.۲۳۴٫۲۵۷'); // second mark ignored
      expect(type(dec, TextEditingValue.empty, '0.5').text, '۵'); // '.' is a separator here (dropped), leading zero stripped
      thousandsSep = ',';
      expect(type(dec, TextEditingValue.empty, '1234.5').text, '۱,۲۳۴٫۵');
    });

    test('format() is what money fields show for values set by code', () {
      expect(ThousandsFormatter().format('1500000'), '۱.۵۰۰.۰۰۰');
    });
  });

  testWidgets('AmountField groups as you type, shows the unit and reads back as a number', (tester) async {
    final c = TextEditingController();
    final c2 = TextEditingController(text: '2500000'); // set by code before the field exists
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          AmountField(controller: c, label: 'مبلغ'),
          AmountField(controller: c2, label: 'قیمت'),
        ]),
      ),
    ));
    expect(c2.text, '۲.۵۰۰.۰۰۰');
    expect(find.text('تومان'), findsNWidgets(2));
    await tester.enterText(find.byType(TextFormField).first, '1234567');
    expect(c.text, '۱.۲۳۴.۵۶۷');
    expect(parseAmount(c.text), 1234567);
    await tester.enterText(find.byType(TextFormField).first, '۱۲۳۴');
    expect(c.text, '۱.۲۳۴');
  });

  group('currency conversion', () {
    var n = 0;
    Future<Repo> newRepo() async {
      sqfliteFfiInit();
      final dir = Directory.systemTemp.createTempSync('acc_cur');
      final r = Repo(await AppDb.open(path: '${dir.path}/db${n++}.db', factory: databaseFactoryFfi));
      await r.init();
      return r;
    }

    test('toman to rial multiplies every amount and back again restores them', () async {
      final r = await newRepo();
      await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 1000);
      final acc = (await r.accounts()).single;
      await r.saveParty(name: 'علی');
      final p = (await r.parties()).single;
      await r.saveProduct(name: 'کالا', salePrice: 250, buyPrice: 100);
      final prod = (await r.products()).single;
      await r.saveTx(date: '2025-01-01', kind: 'receipt', amount: 300, accountId: acc.id, partyId: p.id);
      await r.saveInvoice(number: 1, kind: 'sale', date: '2025-01-02', partyId: p.id, discount: 50, taxPercent: 10, note: '',
          items: [InvoiceItem('کالا', 2, 250, productId: prod.id)]);
      await r.saveCheque(kind: 'received', number: '1', bank: '', amount: 700, dueDate: '2025-02-01');
      await r.saveCostSheet(prod.id, CostSheet(batchQty: 10, lines: [
        CostLine(name: 'مواد', value: 1000),
        CostLine(name: 'ارز', type: 'fx', value: 5, rate: 200),
        CostLine(name: 'سربار', type: 'percent', value: 10),
      ]));
      final costBefore = (await r.products()).single.costPrice;
      final balanceBefore = (await r.parties()).single.balance;

      expect(currencyLabel, 'تومان');
      await r.setCurrency('ریال', convert: true);
      expect(currencyLabel, 'ریال');
      expect(r.setting('currency'), 'ریال');
      expect((await r.accounts()).single.opening, 10000);
      expect((await r.accounts()).single.balance, 10000 + 3000);
      final prods = (await r.products()).single;
      expect(prods.salePrice, 2500);
      expect(prods.buyPrice, 1000);
      expect(prods.costPrice, costBefore * 10);
      final inv = (await r.invoices()).single;
      expect(inv.subtotal, 5000);
      expect(inv.discount, 500);
      expect(inv.taxPercent, 10); // percentages are not amounts
      expect((await r.cheques()).single.amount, 7000);
      expect((await r.parties()).single.balance, balanceBefore * 10);
      final sheet = (await r.costSheet(prod.id))!;
      expect(sheet.lines[0].value, 10000);
      expect(sheet.lines[1].value, 5); // foreign amount unchanged
      expect(sheet.lines[1].rate, 2000); // rate is local currency per foreign unit
      expect(sheet.lines[2].value, 10);
      expect(computeCost(sheet).unitCost, closeTo(costBefore * 10, 10));

      await r.setCurrency('تومان', convert: true);
      expect((await r.accounts()).single.opening, 1000);
      expect((await r.products()).single.salePrice, 250);
      expect((await r.invoices()).single.total, inv.total ~/ 10);
      expect((await r.parties()).single.balance, balanceBefore);
    });

    test('label-only switch keeps the numbers; same unit is a no-op; separator is a synced setting', () async {
      final r = await newRepo();
      await r.saveAccount(name: 'ب', kind: 'bank', opening: 777);
      await r.setCurrency('ریال', convert: false);
      expect(currencyLabel, 'ریال');
      expect((await r.accounts()).single.opening, 777);
      await r.setCurrency('ریال', convert: true);
      expect((await r.accounts()).single.opening, 777);

      await r.setThousandsSep(',');
      expect(thousandsSep, ',');
      expect(money(1234), '۱,۲۳۴');
      final other = await newRepo();
      await other.importJson(await r.exportJson());
      expect(thousandsSep, ',');
      expect(currencyLabel, 'ریال');
      await r.setThousandsSep('.');
      expect(thousandsSep, '.');
    });
  });
}
