import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/csv.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/print/report_builders.dart';
import 'package:simple_accounting/ui/products_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_grp');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

void main() {
  test('product groups: products live in a group, deleting a group keeps the products, sync carries both', () async {
    final r = await newRepo();
    final wood = await r.saveProductGroup(name: 'چوب');
    await r.saveProductGroup(name: 'پارچه');
    await r.saveProduct(name: 'تخته', groupId: wood, unit: 'متر');
    await r.saveProduct(name: 'میخ');
    var groups = await r.productGroups();
    expect(groups.map((g) => (g.name, g.count)).toList(), [('پارچه', 0), ('چوب', 1)]);
    expect((await r.products()).firstWhere((p) => p.name == 'تخته').groupId, wood);

    // Editing a product from code that does not know about groups keeps its group...
    final board = (await r.products()).firstWhere((p) => p.name == 'تخته');
    await r.saveProduct(id: board.id, name: 'تخته ۲', salePrice: 5);
    expect((await r.products()).firstWhere((p) => p.id == board.id).groupId, wood);
    // ...and clearing it is explicit.
    await r.saveProduct(id: board.id, name: 'تخته ۲', clearGroup: true);
    expect((await r.products()).firstWhere((p) => p.id == board.id).groupId, isNull);
    await r.saveProduct(id: board.id, name: 'تخته ۲', groupId: wood);

    final other = await newRepo();
    await other.store.applyRemote(await r.store.changesSince(0));
    expect((await other.productGroups()).length, 2);
    expect((await other.products()).firstWhere((p) => p.name == 'تخته ۲').groupId, wood);

    await r.deleteProductGroup(wood);
    groups = await r.productGroups();
    expect(groups.map((g) => g.name), ['پارچه']);
    expect((await r.products()).length, 2); // both products survive
    expect((await r.products()).firstWhere((p) => p.id == board.id).groupId, isNull);
    expect(await r.groupIdByName('پارچه'), groups.single.id); // an existing name is reused
    expect((await r.productGroups()).length, 1);
    await r.groupIdByName('نخ'); // a new name creates the group
    expect((await r.productGroups()).length, 2);
  });

  test('spreadsheet: group column is exported, imported (groups created) and left alone when absent', () async {
    final r = await newRepo();
    final wood = await r.saveProductGroup(name: 'چوب');
    await r.saveProduct(name: 'تخته', code: '1', groupId: wood);
    final rows = await r.exportRows('products');
    expect(rows.first.last, 'گروه');
    expect(rows[1].last, 'چوب');

    final other = await newRepo();
    final res = await other.importProducts(rows);
    expect(res.added, 1);
    final p = (await other.products()).single;
    expect((await other.productGroups()).map((g) => g.name), ['چوب']);
    expect(p.groupId, (await other.productGroups()).single.id);

    // A file without a group column does not touch the groups of existing products.
    await other.importProducts([
      ['نام', 'کد', 'قیمت فروش'],
      ['تخته', '1', '900'],
      ['رنگ', '2', '50'],
    ]);
    final all = {for (final x in await other.products()) x.name: x};
    expect(all['تخته']!.groupId, isNotNull);
    expect(all['تخته']!.salePrice, 900);
    expect(all['رنگ']!.groupId, isNull);
  });

  test('stock report prints the group column when there are groups', () async {
    final r = await newRepo();
    final g = await r.saveProductGroup(name: 'چوب');
    await r.saveProduct(name: 'تخته', groupId: g);
    final products = await r.products();
    final plain = stockDoc(products).tables.single;
    final grouped = stockDoc(products, groups: {g: 'چوب'}).tables.single;
    expect(grouped.headers.length, plain.headers.length + 1);
    expect(grouped.headers.first, 'گروه');
    expect(grouped.rows.single.first, 'چوب');
    expect(grouped.rows.single.length, grouped.headers.length);
    expect(grouped.totals!.length, grouped.headers.length);
  });

  testWidgets('products page: make a group, define a product inside it from the group, filter by group', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sqfliteFfiInit();
    late Repo repo;
    await tester.runAsync(() async {
      repo = await newRepo();
      await repo.saveProduct(name: 'نخ');
    });
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
        await tester.pump();
      }
    }

    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: ProductsPage(repo: repo))));
    await settle();
    expect(find.text('بدون گروه (۱)'), findsOneWidget);

    // Manage groups -> new group.
    await tester.tap(find.text('مدیریت گروه‌ها'));
    await settle();
    await tester.tap(find.text('گروه جدید'));
    await settle();
    await tester.enterText(find.byType(TextField).last, 'چوب');
    await tester.tap(find.text('ذخیره'));
    await settle();
    await settle();
    expect(find.text('چوب'), findsWidgets);
    await tester.tap(find.text('بستن'));
    await settle();
    await settle();
    expect(find.text('چوب (۰)'), findsWidgets); // section header and chip
    expect(find.text('هنوز کالایی در این گروه نیست.'), findsOneWidget);

    // Define a product from inside the group.
    await tester.tap(find.text('کالا در این گروه'));
    await settle();
    await tester.enterText(find.widgetWithText(TextFormField, 'نام کالا یا خدمت'), 'تخته');
    await tester.tap(find.text('ذخیره'));
    await settle();
    await settle();
    final products = {for (final p in (await tester.runAsync(repo.products))!) p.name: p};
    final wood = (await tester.runAsync(repo.productGroups))!.single;
    expect(products['تخته']!.groupId, wood.id);
    expect(products['نخ']!.groupId, isNull);
    await settle();
    expect(find.text('چوب (۱)'), findsWidgets);

    // Filter by the group: the other product disappears.
    await tester.tap(find.widgetWithText(ChoiceChip, 'چوب (۱)'));
    await settle();
    expect(find.text('تخته'), findsOneWidget);
    expect(find.text('نخ'), findsNothing);
  });
}
