import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/access.dart';
import 'package:simple_accounting/data/company_manager.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/device_prefs.dart';
import 'package:simple_accounting/data/guard.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/sync/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_wh');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  r.companyId = 'c1';
  await r.init();
  return r;
}

void main() {
  test('every company starts with the main warehouse; names are unique; used ones cannot be removed', () async {
    final r = await newRepo();
    expect((await r.warehouses()).map((w) => (w.id, w.name)), [(mainWarehouseId, 'انبار اصلی')]);
    final w2 = await r.saveWarehouse(name: 'انبار شعبه');
    await expectLater(r.saveWarehouse(name: 'انبار شعبه'), throwsA(isA<StateError>()));
    await expectLater(r.saveWarehouse(name: '  '), throwsA(isA<StateError>()));
    expect(await r.deleteWarehouse(mainWarehouseId), isNotNull);
    expect((await r.warehouses()).length, 2);
    expect(await r.deleteWarehouse(w2), isNull); // unused
    expect((await r.warehouses()).length, 1);
  });

  test('stock per warehouse: opening in main, invoices in their warehouse, transfers move, counts correct', () async {
    final r = await newRepo();
    final w2 = await r.saveWarehouse(name: 'شعبه');
    await r.saveParty(name: 'علی');
    final ali = (await r.parties()).single.id;
    await r.saveProduct(name: 'برنج', openingStock: 100, buyPrice: 10, salePrice: 20);
    final prod = (await r.products()).single.id;

    await r.saveInvoice(number: 1, kind: 'sale', date: '2025-03-01', partyId: ali, discount: 0, note: '', items: [InvoiceItem('برنج', 30, 20, productId: prod)]); // main (no warehouse)
    await r.saveInvoice(number: 1, kind: 'purchase', date: '2025-03-02', partyId: ali, discount: 0, note: '', items: [InvoiceItem('برنج', 50, 10, productId: prod)], warehouseId: w2);
    await r.saveStockMove(kind: 'transfer', date: '2025-03-03', productId: prod, warehouseId: mainWarehouseId, toWarehouseId: w2, qty: 20);
    await r.saveStockMove(kind: 'adjust', date: '2025-03-04', productId: prod, warehouseId: w2, qty: -5, note: 'ریخته شد');

    final by = (await r.stockByWarehouse())[prod]!;
    expect(by[mainWarehouseId], 50); // 100 - 30 - 20
    expect(by[w2], 65); // 50 + 20 - 5
    // The product's total is the sum, and includes the count correction but not the transfer.
    expect((await r.products()).single.stock, 115);
    expect(by.values.fold<double>(0, (a, b) => a + b), 115);
    expect((await r.stockIn(w2))[prod], 65);

    // The stock card shows the correction and ends at the total.
    final card = await r.productCard(prod);
    expect(card.lines.any((l) => l.description.contains('تعدیل')), isTrue);
    expect(card.closing, 115);

    // An invoice edited into another warehouse moves its goods.
    final sale = (await r.invoices()).firstWhere((i) => i.kind == 'sale');
    expect(sale.warehouseId, isNull);
    await r.saveInvoice(id: sale.id, number: 1, kind: 'sale', date: '2025-03-01', partyId: ali, discount: 0, note: '', items: [InvoiceItem('برنج', 30, 20, productId: prod)], warehouseId: w2);
    final after = (await r.stockByWarehouse())[prod]!;
    expect(after[mainWarehouseId], 80);
    expect(after[w2], 35);
    expect((await r.products()).single.stock, 115);

    // Used warehouses stay; deleting a move restores the numbers.
    expect(await r.deleteWarehouse(w2), isNotNull);
    final tr = (await r.stockMoves()).firstWhere((m) => m.isTransfer);
    await r.deleteStockMove(tr.id);
    expect((await r.stockByWarehouse())[prod]![mainWarehouseId], 100);
  });

  test('transfers need two different warehouses and a positive quantity; closed periods lock moves too', () async {
    final r = await newRepo();
    final w2 = await r.saveWarehouse(name: 'شعبه');
    await r.saveProduct(name: 'x', openingStock: 10);
    final p = (await r.products()).single.id;
    await expectLater(r.saveStockMove(kind: 'transfer', date: '2025-01-01', productId: p, warehouseId: w2, toWarehouseId: w2, qty: 1), throwsA(isA<StateError>()));
    await expectLater(r.saveStockMove(kind: 'transfer', date: '2025-01-01', productId: p, warehouseId: mainWarehouseId, toWarehouseId: w2, qty: -1), throwsA(isA<StateError>()));
    await expectLater(r.saveStockMove(kind: 'adjust', date: '2025-01-01', productId: p, warehouseId: w2, qty: 0), throwsA(isA<StateError>()));
    await r.setSetting(lockSettingKey, '2025-06-30');
    await expectLater(r.saveStockMove(kind: 'adjust', date: '2025-05-01', productId: p, warehouseId: w2, qty: 3), throwsA(isA<AccessDenied>()));
    await r.saveStockMove(kind: 'adjust', date: '2025-07-01', productId: p, warehouseId: w2, qty: 3);
    expect((await r.products()).single.stock, 13);
  });

  test('warehouses, moves and the invoice warehouse sync between devices', () async {
    final a = await newRepo(), b = await newRepo();
    final sa = SyncService(CompanyManager.forRepos({'c1': a}, DevicePrefs.memory()));
    final sb = SyncService(CompanyManager.forRepos({'c1': b}, DevicePrefs.memory()));
    await sb.startServer(port: 0);
    await sa.setPairCode('1');
    await sb.setPairCode('1');
    try {
      final w2 = await a.saveWarehouse(name: 'شعبه');
      await a.saveProduct(name: 'x', openingStock: 10);
      final p = (await a.products()).single.id;
      await a.saveStockMove(kind: 'transfer', date: '2025-01-01', productId: p, warehouseId: mainWarehouseId, toWarehouseId: w2, qty: 4);
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      expect((await b.warehouses()).map((w) => w.name), contains('شعبه'));
      expect((await b.stockByWarehouse())[p]![w2], 4);
      // Renaming the main warehouse on one side reaches the other; both still have one main.
      await b.saveWarehouse(id: mainWarehouseId, name: 'انبار مرکزی');
      await sa.syncWith(a, '127.0.0.1', port: sb.port!);
      expect((await a.warehouses()).first.name, 'انبار مرکزی');
      expect((await a.warehouses()).where((w) => w.id == mainWarehouseId).length, 1);
    } finally {
      await sb.stopServer();
    }
  });
}
