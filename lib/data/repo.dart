import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../util/format.dart';
import '../print/print_settings.dart';
import 'costing.dart';
import 'db.dart';
import 'device_prefs.dart';

class Account {
  Account(this.id, this.name, this.kind, this.opening, this.balance);
  final String id, name, kind; // kind: cash | bank
  final int opening, balance;
}

class Party {
  Party(this.id, this.name, this.phone, this.note, this.balance);
  final String id, name, phone, note;

  /// Positive: the party owes us. Negative: we owe the party.
  final int balance;
}

class Category {
  Category(this.id, this.name, this.kind);
  final String id, name, kind; // kind: income | expense
}

class Product {
  Product({
    required this.id,
    required this.name,
    this.code = '',
    this.unit = 'عدد',
    this.salePrice = 0,
    this.buyPrice = 0,
    this.openingStock = 0,
    this.minStock = 0,
    this.note = '',
    this.stock = 0,
    this.costPrice = 0,
  });
  final String id, name, code, unit, note;

  /// Final cost of one unit from the cost sheet (0 when there is none).
  final int salePrice, buyPrice, costPrice;
  final double openingStock, minStock, stock;
  bool get low => minStock > 0 && stock <= minStock;
}

class SavedFormula {
  SavedFormula(this.id, this.name, this.expression);
  final String id, name, expression;
}

class Tx {
  Tx(this.id, this.date, this.kind, this.amount, this.accountId, this.partyId,
      this.categoryId, this.invoiceId, this.description);
  final String id, date, kind; // kind: receipt | payment
  final int amount;
  final String accountId;
  final String? partyId, categoryId, invoiceId;
  final String description;
}

class Cheque {
  Cheque({
    required this.id,
    required this.kind,
    required this.number,
    required this.bank,
    required this.amount,
    required this.dueDate,
    this.partyId,
    this.status = 'pending',
    this.accountId,
    this.txId,
    this.note = '',
  });
  final String id, kind, number, bank, dueDate, status, note; // kind: received | issued
  final int amount;
  final String? partyId, accountId, txId;
}

class InvoiceItem {
  InvoiceItem(this.title, this.qty, this.unitPrice, {this.productId});
  final String title;
  final double qty;
  final int unitPrice;
  final String? productId;
  int get total => (qty * unitPrice).round();
}

/// The four kinds of invoice and how each one affects the party balance and
/// the stock.
class InvoiceKind {
  const InvoiceKind(this.code, this.label, this.partyOwesUs, this.stockIn, this.paymentKind, this.partyLabel);
  final String code, label, partyLabel;

  /// true: the invoice total increases what the party owes us.
  final bool partyOwesUs;

  /// true: goods come in (purchase, sale return), false: goods go out.
  final bool stockIn;

  /// Kind of transaction that settles it: receipt or payment.
  final String paymentKind;
}

const invoiceKinds = [
  InvoiceKind('sale', 'فاکتور فروش', true, false, 'receipt', 'مشتری'),
  InvoiceKind('purchase', 'فاکتور خرید', false, true, 'payment', 'تأمین‌کننده'),
  InvoiceKind('sale_return', 'برگشت از فروش', false, true, 'payment', 'مشتری'),
  InvoiceKind('purchase_return', 'برگشت از خرید', true, false, 'receipt', 'تأمین‌کننده'),
];

InvoiceKind invoiceKind(String code) =>
    invoiceKinds.firstWhere((k) => k.code == code, orElse: () => invoiceKinds.first);

class Invoice {
  Invoice(this.id, this.number, this.kind, this.date, this.partyId, this.discount,
      this.note, this.subtotal, this.paid, this.taxPercent);
  final String id, kind, date, partyId, note;
  final int number, discount, subtotal, paid, taxPercent;
  int get net => subtotal - discount;
  int get tax => (net * taxPercent / 100).round();
  int get total => net + tax;
  int get remaining => total - paid;
  InvoiceKind get info => invoiceKind(kind);
}

class MonthReport {
  MonthReport(this.income, this.expense, this.byCategory);
  final int income, expense;

  /// (name, kind, total) sorted by total descending.
  final List<(String, String, int)> byCategory;
  int get net => income - expense;
}

class ProductSales {
  ProductSales(this.name, this.unit, this.qty, this.revenue);
  final String name, unit;
  final double qty;
  final int revenue;
}

/// Sales of one product to one party (sales minus returns).
class PartySales {
  PartySales(this.partyId, this.name, this.qty, this.revenue, this.invoices);
  final String partyId, name;
  final double qty;
  final int revenue, invoices;
}

/// One invoice line of a product sold to a party.
class SaleLine {
  SaleLine(this.date, this.number, this.kind, this.qty, this.unitPrice, this.total);
  final String date, kind;
  final int number, unitPrice, total;
  final double qty;
}

/// One line of a party statement.
class StatementRow {
  StatementRow(this.date, this.description, this.debit, this.credit, this.balance);
  final String date, description;

  /// Increases what the party owes us (sale invoice, payment we made).
  final int debit;

  /// Decreases it (money received, purchase invoice).
  final int credit;

  /// Running balance after this line. Positive: the party owes us.
  final int balance;
}

class StatementData {
  StatementData(this.opening, this.rows, this.closing);

  /// Balance carried in from before the period.
  final int opening, closing;
  final List<StatementRow> rows;
  int get totalDebit => rows.fold(0, (a, r) => a + r.debit);
  int get totalCredit => rows.fold(0, (a, r) => a + r.credit);
}

class Dashboard {
  Dashboard({
    required this.totalBalance,
    required this.monthIncome,
    required this.monthExpense,
    required this.receivable,
    required this.payable,
    required this.months,
    required this.lowStock,
    required this.dueCheques,
    required this.recent,
    required this.names,
  });
  final int totalBalance, monthIncome, monthExpense, receivable, payable;

  /// Last six Jalali months, oldest first: (label, income, expense).
  final List<(String, int, int)> months;
  final List<Product> lowStock;
  final List<Cheque> dueCheques;
  final List<Tx> recent;
  final Map<String, String> names; // party/account id -> name
}

/// All accounting queries and mutations. UI listens to it and rebuilds when the
/// data changes (including changes that arrive from a sync).
class Repo extends ChangeNotifier {
  Repo(this.store, {DevicePrefs? prefs, this.companyId = ''}) : prefs = prefs ?? DevicePrefs.memory();
  final AppDb store;

  /// Device-wide preferences (theme, print set-up).
  final DevicePrefs prefs;

  /// Identity of the company this data belongs to; shared by the devices that sync it.
  String companyId;

  Map<String, String> settings = {};

  /// Page set-up for printing (per device, not synced).
  PrintSettings get printSettings => PrintSettings.fromPrefs(prefs);

  /// Loads synced settings (business info, VAT, currency). Call once at start.
  Future<void> init() async {
    await _loadSettings();
  }

  Future<void> setPrint(PrintSettings s) async {
    await s.save(prefs);
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    final rows = await store.db.query('settings', where: 'deleted=0');
    settings = {for (final r in rows) r['id'] as String: r['value'] as String};
    currencyLabel = settings['currency'] ?? 'تومان';
    thousandsSep = settings['thousands_sep'] == ',' ? ',' : '.';
  }

  String setting(String key, [String def = '']) => settings[key] ?? def;

  Future<void> setSetting(String key, String value) async {
    await store.save('settings', {'id': key, 'value': value});
    await _loadSettings();
    notifyListeners();
  }

  void changed() {
    _loadSettings().whenComplete(notifyListeners);
  }

  // ---- accounts -----------------------------------------------------------

  Future<List<Account>> accounts() async {
    final rows = await store.db.rawQuery('''
      SELECT a.id, a.name, a.kind, a.opening,
        a.opening + COALESCE((SELECT SUM(CASE t.kind WHEN 'receipt' THEN t.amount ELSE -t.amount END)
          FROM transactions t WHERE t.account_id=a.id AND t.deleted=0),0) AS balance
      FROM accounts a WHERE a.deleted=0 ORDER BY a.name''');
    return [
      for (final r in rows)
        Account(r['id'] as String, r['name'] as String, r['kind'] as String,
            r['opening'] as int, r['balance'] as int)
    ];
  }

  Future<void> saveAccount({String? id, required String name, required String kind, required int opening}) async {
    await store.save('accounts', {'id': ?id, 'name': name, 'kind': kind, 'opening': opening});
    changed();
  }

  /// Returns an error message if the account cannot be deleted.
  Future<String?> deleteAccount(String id) async {
    final n = await _count('transactions', 'account_id', id);
    if (n > 0) return 'این حساب دارای تراکنش است و قابل حذف نیست.';
    await store.softDelete('accounts', id);
    changed();
    return null;
  }

  // ---- parties ------------------------------------------------------------

  static const _invoiceTotals = '''
    WITH inv AS (
      SELECT i.party_id, i.kind, i.discount, i.tax_percent,
        COALESCE((SELECT SUM(ROUND(it.qty*it.unit_price)) FROM invoice_items it
          WHERE it.invoice_id=i.id AND it.deleted=0),0) AS sub
      FROM invoices i WHERE i.deleted=0),
    tot AS (
      SELECT party_id, kind, (sub-discount) + ROUND((sub-discount)*tax_percent/100.0) AS total FROM inv)''';

  Future<List<Party>> parties() async {
    final rows = await store.db.rawQuery('''
      $_invoiceTotals
      SELECT p.id, p.name, p.phone, p.note,
        COALESCE((SELECT SUM(total * CASE WHEN kind IN ('sale','purchase_return') THEN 1 ELSE -1 END)
          FROM tot WHERE tot.party_id=p.id),0)
        + COALESCE((SELECT SUM(CASE t.kind WHEN 'payment' THEN t.amount ELSE -t.amount END)
          FROM transactions t WHERE t.party_id=p.id AND t.deleted=0),0) AS balance
      FROM parties p WHERE p.deleted=0 ORDER BY p.name''');
    return [
      for (final r in rows)
        Party(r['id'] as String, r['name'] as String, r['phone'] as String,
            r['note'] as String, (r['balance'] as num).round())
    ];
  }

  Future<void> saveParty({String? id, required String name, String phone = '', String note = ''}) async {
    await store.save('parties', {'id': ?id, 'name': name, 'phone': phone, 'note': note});
    changed();
  }

  Future<String?> deleteParty(String id) async {
    final n = await _count('transactions', 'party_id', id) +
        await _count('invoices', 'party_id', id) +
        await _count('cheques', 'party_id', id);
    if (n > 0) return 'این شخص دارای تراکنش، فاکتور یا چک است و قابل حذف نیست.';
    await store.softDelete('parties', id);
    changed();
    return null;
  }

  // ---- categories ---------------------------------------------------------

  Future<List<Category>> categories({String? kind}) async {
    final rows = await store.db.query('categories',
        where: kind == null ? 'deleted=0' : 'deleted=0 AND kind=?',
        whereArgs: kind == null ? null : [kind],
        orderBy: 'name');
    return [for (final r in rows) Category(r['id'] as String, r['name'] as String, r['kind'] as String)];
  }

  Future<void> saveCategory({String? id, required String name, required String kind}) async {
    await store.save('categories', {'id': ?id, 'name': name, 'kind': kind});
    changed();
  }

  Future<String?> deleteCategory(String id) async {
    if (await _count('transactions', 'category_id', id) > 0) {
      return 'این دسته‌بندی در تراکنش‌ها استفاده شده و قابل حذف نیست.';
    }
    await store.softDelete('categories', id);
    changed();
    return null;
  }

  // ---- products -----------------------------------------------------------

  Future<List<Product>> products() async {
    final rows = await store.db.rawQuery('''
      SELECT p.*, p.opening_stock + COALESCE((
        SELECT SUM(it.qty * CASE WHEN i.kind IN ('purchase','sale_return') THEN 1 ELSE -1 END)
        FROM invoice_items it JOIN invoices i ON i.id=it.invoice_id
        WHERE it.product_id=p.id AND it.deleted=0 AND i.deleted=0),0) AS stock,
        COALESCE((SELECT c.unit_cost FROM costings c WHERE c.product_id=p.id AND c.deleted=0),0) AS cost_price
      FROM products p WHERE p.deleted=0 ORDER BY p.name''');
    return [
      for (final r in rows)
        Product(
          id: r['id'] as String,
          name: r['name'] as String,
          code: r['code'] as String,
          unit: r['unit'] as String,
          salePrice: r['sale_price'] as int,
          buyPrice: r['buy_price'] as int,
          openingStock: (r['opening_stock'] as num).toDouble(),
          minStock: (r['min_stock'] as num).toDouble(),
          note: r['note'] as String,
          stock: (r['stock'] as num).toDouble(),
          costPrice: r['cost_price'] as int,
        )
    ];
  }

  Future<void> saveProduct({
    String? id,
    required String name,
    String code = '',
    String unit = 'عدد',
    int salePrice = 0,
    int buyPrice = 0,
    double openingStock = 0,
    double minStock = 0,
    String note = '',
  }) async {
    await store.save('products', {
      'id': ?id,
      'name': name, 'code': code, 'unit': unit, 'sale_price': salePrice, 'buy_price': buyPrice,
      'opening_stock': openingStock, 'min_stock': minStock, 'note': note,
    });
    changed();
  }

  Future<void> deleteProduct(String id) async {
    await store.softDelete('products', id);
    changed();
  }

  // ---- transactions -------------------------------------------------------

  Future<List<Tx>> transactions({String? accountId, String? partyId, String? from, String? toExclusive, int? limit}) async {
    final where = <String>['deleted=0'];
    final args = <Object?>[];
    if (accountId != null) { where.add('account_id=?'); args.add(accountId); }
    if (partyId != null) { where.add('party_id=?'); args.add(partyId); }
    if (from != null) { where.add('date>=?'); args.add(from); }
    if (toExclusive != null) { where.add('date<?'); args.add(toExclusive); }
    final rows = await store.db.query('transactions',
        where: where.join(' AND '), whereArgs: args, orderBy: 'date DESC, updated_at DESC', limit: limit);
    return [
      for (final r in rows)
        Tx(r['id'] as String, r['date'] as String, r['kind'] as String, r['amount'] as int,
            r['account_id'] as String, r['party_id'] as String?, r['category_id'] as String?,
            r['invoice_id'] as String?, r['description'] as String)
    ];
  }

  Future<String> saveTx({
    String? id,
    required String date,
    required String kind,
    required int amount,
    required String accountId,
    String? partyId,
    String? categoryId,
    String? invoiceId,
    String description = '',
  }) async {
    final txId = id ?? AppDb.newId();
    await store.save('transactions', {
      'id': txId,
      'date': date, 'kind': kind, 'amount': amount, 'account_id': accountId,
      'party_id': partyId, 'category_id': categoryId, 'invoice_id': invoiceId,
      'description': description,
    });
    changed();
    return txId;
  }

  Future<void> deleteTx(String id) async {
    await store.softDelete('transactions', id);
    changed();
  }

  // ---- invoices -----------------------------------------------------------

  Future<List<Invoice>> invoices({String? partyId}) async {
    final rows = await store.db.rawQuery('''
      SELECT i.*,
        (SELECT COALESCE(SUM(ROUND(it.qty*it.unit_price)),0) FROM invoice_items it
           WHERE it.invoice_id=i.id AND it.deleted=0) AS subtotal,
        (SELECT COALESCE(SUM(t.amount),0) FROM transactions t
           WHERE t.invoice_id=i.id AND t.deleted=0) AS paid
      FROM invoices i WHERE i.deleted=0 ${partyId == null ? '' : 'AND i.party_id=?'}
      ORDER BY i.date DESC, i.number DESC''', partyId == null ? null : [partyId]);
    return [
      for (final r in rows)
        Invoice(r['id'] as String, r['number'] as int, r['kind'] as String, r['date'] as String,
            r['party_id'] as String, r['discount'] as int, r['note'] as String,
            (r['subtotal'] as num).round(), (r['paid'] as num).round(), r['tax_percent'] as int)
    ];
  }

  Future<List<InvoiceItem>> invoiceItems(String invoiceId) async {
    final rows = await store.db.query('invoice_items',
        where: 'invoice_id=? AND deleted=0', whereArgs: [invoiceId], orderBy: 'position');
    return [
      for (final r in rows)
        InvoiceItem(r['title'] as String, (r['qty'] as num).toDouble(), r['unit_price'] as int,
            productId: r['product_id'] as String?)
    ];
  }

  Future<int> nextInvoiceNumber() async {
    final r = await store.db.rawQuery('SELECT COALESCE(MAX(number),0)+1 AS n FROM invoices');
    return r.first['n'] as int;
  }

  /// Creates or replaces an invoice together with its items.
  Future<String> saveInvoice({
    String? id,
    required int number,
    required String kind,
    required String date,
    required String partyId,
    required int discount,
    int taxPercent = 0,
    required String note,
    required List<InvoiceItem> items,
  }) async {
    final invId = id ?? AppDb.newId();
    await store.db.transaction((tx) async {
      await store.save('invoices', {
        'id': invId, 'number': number, 'kind': kind, 'date': date,
        'party_id': partyId, 'discount': discount, 'tax_percent': taxPercent, 'note': note,
      }, exec: tx);
      final old = await tx.query('invoice_items',
          columns: ['id'], where: 'invoice_id=? AND deleted=0', whereArgs: [invId]);
      for (final o in old) {
        await store.softDelete('invoice_items', o['id'] as String, exec: tx);
      }
      for (var i = 0; i < items.length; i++) {
        await store.save('invoice_items', {
          'invoice_id': invId, 'title': items[i].title, 'qty': items[i].qty,
          'unit_price': items[i].unitPrice, 'position': i, 'product_id': items[i].productId,
        }, exec: tx);
      }
    });
    changed();
    return invId;
  }

  Future<void> deleteInvoice(String id) async {
    await store.db.transaction((tx) async {
      await store.softDelete('invoices', id, exec: tx);
      final items = await tx.query('invoice_items',
          columns: ['id'], where: 'invoice_id=? AND deleted=0', whereArgs: [id]);
      for (final o in items) {
        await store.softDelete('invoice_items', o['id'] as String, exec: tx);
      }
      // Payments stay, but are detached from the removed invoice.
      final txs = await tx.query('transactions',
          where: 'invoice_id=? AND deleted=0', whereArgs: [id]);
      for (final t in txs) {
        await store.save('transactions', {...t, 'invoice_id': null}, exec: tx);
      }
    });
    changed();
  }

  // ---- costing & price formulas ------------------------------------------

  Future<CostSheet?> costSheet(String productId) async {
    final rows = await store.db.query('costings', where: 'product_id=? AND deleted=0', whereArgs: [productId]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return CostSheet(
      batchQty: (r['batch_qty'] as num).toDouble(),
      wastePercent: (r['waste_percent'] as num).toDouble(),
      lines: CostSheet.linesFromJson(r['lines'] as String),
      note: r['note'] as String,
    );
  }

  /// Stores the cost sheet of a product and remembers the resulting unit cost.
  Future<void> saveCostSheet(String productId, CostSheet s) async {
    await store.save('costings', {
      'id': productId,
      'product_id': productId,
      'batch_qty': s.batchQty,
      'waste_percent': s.wastePercent,
      'lines': s.linesJson(),
      'unit_cost': computeCost(s).unitCost.round(),
      'note': s.note,
    });
    changed();
  }

  Future<void> deleteCostSheet(String productId) async {
    await store.softDelete('costings', productId);
    changed();
  }

  /// Changes the sale or purchase price of a product from the pricing screen.
  Future<void> setProductPrice(String productId, {int? salePrice, int? buyPrice}) async {
    final rows = await store.db.query('products', where: 'id=? AND deleted=0', whereArgs: [productId]);
    if (rows.isEmpty) return;
    await store.save('products', {
      ...rows.first,
      'sale_price': ?salePrice,
      'buy_price': ?buyPrice,
    });
    changed();
  }

  Future<List<SavedFormula>> formulas() async {
    final rows = await store.db.query('formulas', where: 'deleted=0', orderBy: 'name');
    return [for (final r in rows) SavedFormula(r['id'] as String, r['name'] as String, r['expression'] as String)];
  }

  Future<void> saveFormula({String? id, required String name, required String expression}) async {
    await store.save('formulas', {'id': ?id, 'name': name, 'expression': expression});
    changed();
  }

  Future<void> deleteFormula(String id) async {
    await store.softDelete('formulas', id);
    changed();
  }

  // ---- cheques ------------------------------------------------------------

  Future<List<Cheque>> cheques({String? kind, String? status}) async {
    final where = <String>['deleted=0'];
    final args = <Object?>[];
    if (kind != null) { where.add('kind=?'); args.add(kind); }
    if (status != null) { where.add('status=?'); args.add(status); }
    final rows = await store.db.query('cheques',
        where: where.join(' AND '), whereArgs: args, orderBy: 'due_date');
    return [
      for (final r in rows)
        Cheque(
          id: r['id'] as String, kind: r['kind'] as String, number: r['number'] as String,
          bank: r['bank'] as String, amount: r['amount'] as int, dueDate: r['due_date'] as String,
          partyId: r['party_id'] as String?, status: r['status'] as String,
          accountId: r['account_id'] as String?, txId: r['tx_id'] as String?, note: r['note'] as String,
        )
    ];
  }

  Future<void> saveCheque({
    String? id,
    required String kind,
    required String number,
    required String bank,
    required int amount,
    required String dueDate,
    String? partyId,
    String note = '',
  }) async {
    // Editing keeps the status/transaction link of an existing cheque.
    Map<String, Object?> keep = {};
    if (id != null) {
      final old = await store.db.query('cheques', where: 'id=?', whereArgs: [id]);
      if (old.isNotEmpty) {
        keep = {'status': old.first['status'], 'account_id': old.first['account_id'], 'tx_id': old.first['tx_id']};
      }
    }
    await store.save('cheques', {
      'id': ?id, 'kind': kind, 'number': number, 'bank': bank, 'amount': amount,
      'due_date': dueDate, 'party_id': partyId, 'note': note, ...keep,
    });
    changed();
  }

  /// Changes a cheque's status. Clearing it books a receipt/payment in
  /// [accountId]; moving it away from "cleared" removes that transaction.
  Future<void> setChequeStatus(Cheque c, String status, {String? accountId, String? date}) async {
    String? txId = c.txId;
    if (c.status == 'cleared' && status != 'cleared' && txId != null) {
      await store.softDelete('transactions', txId);
      txId = null;
    }
    if (status == 'cleared' && c.status != 'cleared') {
      txId = await saveTx(
        date: date ?? todayIso(),
        kind: c.kind == 'received' ? 'receipt' : 'payment',
        amount: c.amount,
        accountId: accountId!,
        partyId: c.partyId,
        description: 'وصول چک ${c.number}'.trim(),
      );
    }
    await store.save('cheques', {
      'id': c.id, 'kind': c.kind, 'number': c.number, 'bank': c.bank, 'amount': c.amount,
      'due_date': c.dueDate, 'party_id': c.partyId, 'note': c.note,
      'status': status, 'account_id': status == 'cleared' ? accountId : null, 'tx_id': txId,
    });
    changed();
  }

  Future<void> deleteCheque(Cheque c) async {
    if (c.txId != null) await store.softDelete('transactions', c.txId!);
    await store.softDelete('cheques', c.id);
    changed();
  }

  // ---- reports ------------------------------------------------------------

  Future<MonthReport> report(String from, String toExclusive) async {
    final rows = await store.db.rawQuery('''
      SELECT COALESCE(c.name,'بدون دسته‌بندی') AS name, t.kind AS kind, SUM(t.amount) AS total
      FROM transactions t LEFT JOIN categories c ON c.id=t.category_id
      WHERE t.deleted=0 AND t.date>=? AND t.date<?
      GROUP BY c.id, t.kind ORDER BY total DESC''', [from, toExclusive]);
    var income = 0, expense = 0;
    final list = <(String, String, int)>[];
    for (final r in rows) {
      final total = (r['total'] as num).round();
      final kind = r['kind'] as String;
      if (kind == 'receipt') { income += total; } else { expense += total; }
      list.add((r['name'] as String, kind, total));
    }
    return MonthReport(income, expense, list);
  }

  /// Quantity and revenue of sold goods (sales minus returns) in a date range.
  Future<List<ProductSales>> productSales(String from, String toExclusive) async {
    final rows = await store.db.rawQuery('''
      SELECT it.title AS name, COALESCE(p.unit,'') AS unit,
        SUM(it.qty * CASE i.kind WHEN 'sale' THEN 1 ELSE -1 END) AS qty,
        SUM(ROUND(it.qty*it.unit_price) * CASE i.kind WHEN 'sale' THEN 1 ELSE -1 END) AS revenue
      FROM invoice_items it
      JOIN invoices i ON i.id=it.invoice_id
      LEFT JOIN products p ON p.id=it.product_id
      WHERE it.deleted=0 AND i.deleted=0 AND i.kind IN ('sale','sale_return') AND i.date>=? AND i.date<?
      GROUP BY COALESCE(it.product_id, it.title) ORDER BY revenue DESC''', [from, toExclusive]);
    return [
      for (final r in rows)
        ProductSales(r['name'] as String, r['unit'] as String, (r['qty'] as num).toDouble(), (r['revenue'] as num).round())
    ];
  }

  // Lines typed by hand (not picked from the product list) are matched by name.
  static const _productLine =
      '(it.product_id=? OR (it.product_id IS NULL AND it.title=(SELECT name FROM products WHERE id=?)))';

  /// Who bought a product: quantity and revenue per party (sales minus
  /// returns), highest revenue first. Dates are ISO strings, [toExclusive] is
  /// not included.
  Future<List<PartySales>> productSalesByParty(String productId, {String? from, String? toExclusive}) async {
    final rows = await store.db.rawQuery('''
      SELECT i.party_id AS party_id, COALESCE(pa.name,'(شخص حذف‌شده)') AS name,
        SUM(it.qty * CASE i.kind WHEN 'sale' THEN 1 ELSE -1 END) AS qty,
        SUM(ROUND(it.qty*it.unit_price) * CASE i.kind WHEN 'sale' THEN 1 ELSE -1 END) AS revenue,
        COUNT(DISTINCT i.id) AS invoices
      FROM invoice_items it
      JOIN invoices i ON i.id=it.invoice_id
      LEFT JOIN parties pa ON pa.id=i.party_id
      WHERE it.deleted=0 AND i.deleted=0 AND i.kind IN ('sale','sale_return') AND $_productLine
        ${from == null ? '' : 'AND i.date>=?'} ${toExclusive == null ? '' : 'AND i.date<?'}
      GROUP BY i.party_id ORDER BY revenue DESC, name''', [productId, productId, ?from, ?toExclusive]);
    return [
      for (final r in rows)
        PartySales(r['party_id'] as String, r['name'] as String, (r['qty'] as num).toDouble(),
            (r['revenue'] as num).round(), r['invoices'] as int)
    ];
  }

  /// The invoice lines behind one row of [productSalesByParty].
  Future<List<SaleLine>> productSaleLines(String productId, String partyId, {String? from, String? toExclusive}) async {
    final rows = await store.db.rawQuery('''
      SELECT i.date AS date, i.number AS number, i.kind AS kind, it.qty AS qty, it.unit_price AS unit_price
      FROM invoice_items it JOIN invoices i ON i.id=it.invoice_id
      WHERE it.deleted=0 AND i.deleted=0 AND i.kind IN ('sale','sale_return') AND i.party_id=? AND $_productLine
        ${from == null ? '' : 'AND i.date>=?'} ${toExclusive == null ? '' : 'AND i.date<?'}
      ORDER BY i.date DESC, i.number DESC''', [partyId, productId, productId, ?from, ?toExclusive]);
    return [
      for (final r in rows)
        SaleLine(r['date'] as String, r['number'] as int, r['kind'] as String, (r['qty'] as num).toDouble(),
            r['unit_price'] as int, ((r['qty'] as num) * (r['unit_price'] as int)).round())
    ];
  }

  /// Chronological statement of a party for [from, toExclusive) with the
  /// balance carried in from before the period.
  Future<StatementData> statement(String partyId, {String? from, String? toExclusive}) async {
    final items = <(String, int, String, int)>[]; // date, order, description, signed amount
    for (final i in await invoices(partyId: partyId)) {
      items.add((i.date, 0, '${i.info.label} ${faDigits('${i.number}')}', i.info.partyOwesUs ? i.total : -i.total));
    }
    for (final t in await transactions(partyId: partyId)) {
      final what = t.kind == 'receipt' ? 'دریافت' : 'پرداخت';
      items.add((t.date, 1, t.description.isEmpty ? what : '$what - ${t.description}', t.kind == 'payment' ? t.amount : -t.amount));
    }
    items.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    var running = 0;
    var opening = 0;
    final rows = <StatementRow>[];
    for (final it in items) {
      final before = from != null && it.$1.compareTo(from) < 0;
      final after = toExclusive != null && it.$1.compareTo(toExclusive) >= 0;
      if (after) continue;
      running += it.$4;
      if (before) {
        opening = running;
        continue;
      }
      rows.add(StatementRow(it.$1, it.$3, it.$4 > 0 ? it.$4 : 0, it.$4 < 0 ? -it.$4 : 0, running));
    }
    return StatementData(opening, rows, running);
  }

  Future<Dashboard> dashboard() async {
    final accs = await accounts();
    final parts = await parties();
    final now = Jalali.now();
    final months = <(String, int, int)>[];
    var y = now.year, m = now.month;
    final starts = <(int, int)>[];
    for (var i = 0; i < 6; i++) {
      starts.add((y, m));
      m--;
      if (m < 1) { m = 12; y--; }
    }
    for (final (yy, mm) in starts.reversed) {
      final (a, b) = jalaliMonthRange(yy, mm);
      final r = await report(a, b);
      months.add((monthNames[mm - 1], r.income, r.expense));
    }
    final cur = months.last;
    final soon = isoOf(DateTime.now().add(const Duration(days: 7)));
    final pending = await cheques(status: 'pending');
    return Dashboard(
      totalBalance: accs.fold(0, (a, b) => a + b.balance),
      monthIncome: cur.$2,
      monthExpense: cur.$3,
      receivable: parts.where((p) => p.balance > 0).fold(0, (a, p) => a + p.balance),
      payable: parts.where((p) => p.balance < 0).fold(0, (a, p) => a - p.balance),
      months: months,
      lowStock: (await products()).where((p) => p.low).toList(),
      dueCheques: pending.where((c) => c.dueDate.compareTo(soon) <= 0).toList(),
      recent: await transactions(limit: 6),
      names: {for (final p in parts) p.id: p.name, for (final a in accs) a.id: a.name},
    );
  }

  // ---- currency -----------------------------------------------------------

  /// Multiplies every stored amount by [factor] (10 for تومان → ریال, 0.1 for
  /// the way back). Foreign-currency amounts and percentages stay as they are;
  /// exchange rates follow the local currency. Returns the number of rows
  /// rewritten. Saved custom formulas are not touched.
  Future<int> convertAmounts(double factor) async {
    var rewritten = 0;
    await store.db.transaction((tx) async {
      Future<void> scale(String table, List<String> cols) async {
        for (final r in await tx.query(table, where: 'deleted=0')) {
          final row = {...r};
          for (final c in cols) {
            row[c] = ((r[c] as num) * factor).round();
          }
          await store.save(table, row, exec: tx);
          rewritten++;
        }
      }

      await scale('accounts', ['opening']);
      await scale('transactions', ['amount']);
      await scale('invoices', ['discount']);
      await scale('invoice_items', ['unit_price']);
      await scale('products', ['sale_price', 'buy_price']);
      await scale('cheques', ['amount']);
      for (final r in await tx.query('costings', where: 'deleted=0')) {
        final lines = CostSheet.linesFromJson(r['lines'] as String);
        for (final l in lines) {
          if (l.type == 'amount') l.value *= factor;
          if (l.type == 'fx') l.rate *= factor;
        }
        await store.save('costings', {
          ...r,
          'unit_cost': ((r['unit_cost'] as num) * factor).round(),
          'lines': CostSheet(lines: lines).linesJson(),
        }, exec: tx);
        rewritten++;
      }
    });
    await _loadSettings();
    notifyListeners();
    return rewritten;
  }

  /// Switches the currency name. With [convert] the stored amounts are scaled
  /// too (×10 to ریال, ÷10 to تومان).
  Future<void> setCurrency(String unit, {required bool convert}) async {
    if (unit == currencyLabel) return;
    if (convert) await convertAmounts(unit == 'ریال' ? 10 : 0.1);
    await setSetting('currency', unit);
  }

  Future<void> setThousandsSep(String sep) => setSetting('thousands_sep', sep == ',' ? ',' : '.');

  // ---- backup -------------------------------------------------------------

  /// Complete copy of the data as JSON text.
  Future<String> exportJson() async => jsonEncode({
        'app': 'simple_accounting',
        'version': 2,
        'exportedAt': DateTime.now().toIso8601String(),
        'data': await store.changesSince(0),
      });

  /// Merges a backup into the database (newer rows win). Returns the number of
  /// rows that changed.
  Future<int> importJson(String text) async {
    final map = jsonDecode(text);
    if (map is! Map || map['app'] != 'simple_accounting' || map['data'] is! Map) {
      throw const FormatException('این فایل پشتیبان این برنامه نیست.');
    }
    final n = await store.applyRemote(Map<String, dynamic>.from(map['data'] as Map));
    await _loadSettings();
    notifyListeners();
    return n;
  }

  // ---- helpers ------------------------------------------------------------

  Future<int> _count(String table, String column, String id) async {
    final r = await store.db.rawQuery(
        'SELECT COUNT(*) AS n FROM $table WHERE deleted=0 AND $column=?', [id]);
    return r.first['n'] as int;
  }
}
