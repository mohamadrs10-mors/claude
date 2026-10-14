import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shamsi_date/shamsi_date.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;

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
  Party(this.id, this.name, this.phone, this.note, this.balance, [this.opening = 0]);
  final String id, name, phone, note;

  /// Balance carried in when the party was created (positive: owes us).
  final int opening;

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
    this.groupId,
  });
  final String id, name, code, unit, note;

  /// The product group (گروه کالایی), if any.
  final String? groupId;

  /// Final cost of one unit from the cost sheet (0 when there is none).
  final int salePrice, buyPrice, costPrice;
  final double openingStock, minStock, stock;
  bool get low => minStock > 0 && stock <= minStock;
}

/// A group of products (گروه کالایی) such as "چوب" or "پارچه".
class ProductGroup {
  ProductGroup(this.id, this.name, this.count);
  final String id, name;

  /// Number of products in the group.
  final int count;
}

class SavedFormula {
  SavedFormula(this.id, this.name, this.expression);
  final String id, name, expression;
}

class Tx {
  Tx(this.id, this.date, this.kind, this.amount, this.accountId, this.partyId,
      this.categoryId, this.invoiceId, this.description, [this.toAccountId]);
  final String id, date, kind; // kind: receipt | payment | transfer (accountId -> toAccountId)
  final String? toAccountId;
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
    this.orderId,
  });
  final String id, kind, number, bank, dueDate, status, note; // kind: received | issued
  final int amount;
  final String? partyId, accountId, txId;

  /// The order whose advance payment this cheque is (all or part of).
  final String? orderId;
}

class InvoiceItem {
  InvoiceItem(this.title, this.qty, this.unitPrice, {this.productId});
  final String title;
  final double qty;
  final int unitPrice;
  final String? productId;
  int get total => (qty * unitPrice).round();
}

/// A delivery receipt (رسید تحویل) that is not tied to an invoice. It has no
/// prices and changes neither balances nor stock.
class Delivery {
  Delivery(this.id, this.number, this.date, this.partyId, this.recipient, this.address, this.note);
  final String id, date, recipient, address, note;
  final int number;
  final String? partyId;
}

class DeliveryItem {
  DeliveryItem(this.title, this.qty, {this.unit = '', this.productId});
  final String title, unit;
  final double qty;
  final String? productId;
}

/// A cheque received from the customer as (part of) an order's advance,
/// created together with the order.
class ChequeDraft {
  ChequeDraft({required this.amount, required this.dueDate, this.number = '', this.bank = ''});
  final int amount;
  final String dueDate, number, bank;
}

/// One product of an order with the quantity and unit price agreed.
class OrderItem {
  OrderItem(this.title, this.qty, this.unitPrice, {this.productId, this.invoicedQty = 0});
  final String title;
  final double qty, invoicedQty;
  final int unitPrice;
  final String? productId;
  int get total => (qty * unitPrice).round();
  double get remainingQty => (qty - invoicedQty) < 0 ? 0 : qty - invoicedQty;

  /// Whether an invoice line is for this product (by product, or by name for
  /// products that were typed in by hand).
  bool matches(InvoiceItem it) => productId != null ? it.productId == productId : it.title.trim() == title.trim();
}

/// An order for one or several products with an advance payment (سفارش و
/// پیش‌دریافت). The advance is cash received without crediting the customer;
/// each sale invoice made for the order counts [percent] of the part of its
/// total that is for products of the order as paid from the advance.
class Order {
  Order({
    required this.id, required this.number, required this.date, required this.partyId,
    required this.title, required this.items, required this.percent,
    required this.cash, this.chequeAmount = 0, this.accountId, this.txId, required this.status, required this.released,
    required this.closedDate, required this.note, required this.applied,
  });
  final String id, date, partyId, title, status, closedDate, note;
  final String? accountId, txId;
  final int number, cash, chequeAmount, released, applied;
  final double percent;
  final List<OrderItem> items;

  bool get open => status == 'open';
  int get total => items.fold(0, (a, i) => a + i.total);

  /// Everything received as advance: cash plus cheques that did not bounce.
  int get advance => cash + chequeAmount;

  /// Share of the order's value already invoiced, 0..1.
  double get progress {
    if (total <= 0) return 0;
    final done = items.fold<double>(0, (a, i) => a + (i.invoicedQty > i.qty ? i.qty : i.invoicedQty) * i.unitPrice);
    return (done / total).clamp(0, 1).toDouble();
  }

  /// Advance not yet counted on an invoice or released to the customer.
  int get available => (advance - applied - released).clamp(0, advance);
}

/// The four kinds of invoice and how each one affects the party balance and
/// the stock.
class InvoiceKind {
  const InvoiceKind(this.code, this.label, this.partyOwesUs, this.stockIn, this.paymentKind, this.partyLabel, {this.ledger = true});
  final String code, label, partyLabel;

  /// false for a pro-forma: it changes no balance, stock or report.
  final bool ledger;

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
  InvoiceKind('proforma', 'پیش‌فاکتور', true, false, 'receipt', 'مشتری', ledger: false),
];

InvoiceKind invoiceKind(String code) =>
    invoiceKinds.firstWhere((k) => k.code == code, orElse: () => invoiceKinds.first);

class Invoice {
  Invoice(this.id, this.number, this.kind, this.date, this.partyId, this.discount,
      this.note, this.subtotal, this.paid, this.taxPercent, [this.refId, this.orderId, this.prepaid = 0]);
  final String id, kind, date, partyId, note;

  /// The order (with an advance payment) this sale invoice was made for.
  final String? orderId;

  /// Part of [total] that counts as already paid out of the order's advance.
  final int prepaid;

  /// For a pro-forma: the invoice it was turned into.
  final String? refId;
  final int number, discount, subtotal, paid, taxPercent;
  int get net => subtotal - discount;
  int get tax => (net * taxPercent / 100).round();
  int get total => net + tax;
  int get remaining => total - paid - prepaid;
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

/// One line of a party's ledger (معین): an invoice, a payment or a receipt.
class PartyLedgerRow {
  PartyLedgerRow({
    required this.date,
    required this.type,
    required this.description,
    required this.balance,
    this.number = '',
    this.debit = 0,
    this.credit = 0,
    this.invoiceId,
  });
  final String date, type, number, description;

  /// Increases what the party owes us (sale invoice, a payment we made).
  final int debit;

  /// Decreases it (money received, a purchase invoice, advance used).
  final int credit;

  /// Running balance after this line. Positive: the party owes us.
  final int balance;

  /// Set on invoice lines so the screen can open the invoice.
  final String? invoiceId;
}

/// Everything between us and one party in a period: invoices and money, with
/// the balance carried in from before and the cheques still waiting.
class PartyLedger {
  PartyLedger(this.opening, this.rows, this.closing, this.pendingCheques);
  final int opening, closing;
  final List<PartyLedgerRow> rows;

  /// Cheques of this party that are not cleared yet (they are not in the balance).
  final List<Cheque> pendingCheques;
  int get totalDebit => rows.fold(0, (a, r) => a + r.debit);
  int get totalCredit => rows.fold(0, (a, r) => a + r.credit);
  int get invoiceCount => rows.where((r) => r.invoiceId != null && r.credit + r.debit > 0 && r.type != 'کسر از پیش‌دریافت').length;
}

/// VAT collected (sales) and paid (purchases) in a period.
class VatLine {
  VatLine(this.date, this.number, this.kind, this.party, this.base, this.tax);
  final String date, kind, party;
  final int number;

  /// Taxable amount and VAT, negative for returns.
  final int base, tax;
}

class VatReport {
  VatReport(this.lines);
  final List<VatLine> lines;
  int get outputTax => lines.where((l) => l.kind.startsWith('sale')).fold(0, (a, l) => a + l.tax);
  int get inputTax => lines.where((l) => l.kind.startsWith('purchase')).fold(0, (a, l) => a + l.tax);
  int get salesBase => lines.where((l) => l.kind.startsWith('sale')).fold(0, (a, l) => a + l.base);
  int get purchasesBase => lines.where((l) => l.kind.startsWith('purchase')).fold(0, (a, l) => a + l.base);

  /// Positive: VAT to pay; negative: VAT to claim back.
  int get payable => outputTax - inputTax;
}

class ProfitLoss {
  ProfitLoss({
    required this.sales,
    required this.cogs,
    required this.otherIncome,
    required this.expenses,
    required this.otherIncomeByCategory,
    required this.uncategorized,
    required this.unlinkedSales,
  });

  /// Sales minus returns and discounts, without VAT.
  final int sales;

  /// Cost of the goods sold.
  final int cogs;
  final int otherIncome, expenses;
  final List<(String, int)> otherIncomeByCategory;

  /// Expenses by category, largest first.
  List<(String, int)> expensesByCategory = [];

  /// Payments without a person and without a category (not counted anywhere).
  final int uncategorized;

  /// Sales of lines that are not linked to a product (their cost is unknown).
  final int unlinkedSales;

  int get grossProfit => sales - cogs;
  int get netProfit => grossProfit + otherIncome - expenses;
}

class FinancialPosition {
  FinancialPosition({
    required this.accounts,
    required this.receivables,
    required this.inventory,
    required this.chequesReceived,
    required this.payables,
    required this.chequesIssued,
    this.advances = 0,
  });

  /// (name, balance) of every account (negative balances count as liabilities).
  final List<(String, int)> accounts;
  final int receivables, inventory, chequesReceived, payables, chequesIssued;

  /// Advance payments received from customers and not yet counted on an invoice.
  final int advances;

  int get cash => accounts.where((a) => a.$2 > 0).fold(0, (s, a) => s + a.$2);
  int get overdrafts => accounts.where((a) => a.$2 < 0).fold(0, (s, a) => s - a.$2);
  int get assets => cash + receivables + inventory + chequesReceived;
  int get liabilities => payables + chequesIssued + overdrafts + advances;
  int get equity => assets - liabilities;
}

/// What one party owes, by age of the oldest unpaid invoices (FIFO).
class AgeingRow {
  AgeingRow(this.partyId, this.name, this.buckets, this.total);
  final String partyId, name;

  /// 0-30, 31-60, 61-90, over 90 days.
  final List<int> buckets;
  final int total;
}

/// One line of an account ledger or a product card.
class LedgerLine {
  LedgerLine(this.date, this.description, this.inAmount, this.outAmount, this.balance);
  final String date, description;
  final num inAmount, outAmount, balance;
}

class Ledger {
  Ledger(this.opening, this.lines, this.closing);
  final num opening, closing;
  final List<LedgerLine> lines;
  num get totalIn => lines.fold(0, (a, l) => a + l.inAmount);
  num get totalOut => lines.fold(0, (a, l) => a + l.outAmount);
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
        a.opening
          + COALESCE((SELECT SUM(CASE t.kind WHEN 'receipt' THEN t.amount ELSE -t.amount END)
              FROM transactions t WHERE t.account_id=a.id AND t.deleted=0),0)
          + COALESCE((SELECT SUM(t.amount) FROM transactions t
              WHERE t.to_account_id=a.id AND t.kind='transfer' AND t.deleted=0),0) AS balance
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
      SELECT i.party_id, i.kind, i.discount, i.tax_percent, i.prepaid,
        COALESCE((SELECT SUM(ROUND(it.qty*it.unit_price)) FROM invoice_items it
          WHERE it.invoice_id=i.id AND it.deleted=0),0) AS sub
      FROM invoices i WHERE i.deleted=0),
    tot AS (
      SELECT party_id, kind, (sub-discount) + ROUND((sub-discount)*tax_percent/100.0) - prepaid AS total FROM inv
      WHERE kind<>'proforma')''';

  Future<List<Party>> parties() async {
    final rows = await store.db.rawQuery('''
      $_invoiceTotals
      SELECT p.id, p.name, p.phone, p.note, p.opening,
        p.opening
        + COALESCE((SELECT SUM(total * CASE WHEN kind IN ('sale','purchase_return') THEN 1 ELSE -1 END)
          FROM tot WHERE tot.party_id=p.id),0)
        - COALESCE((SELECT SUM(o.released) FROM orders o WHERE o.party_id=p.id AND o.deleted=0),0)
        + COALESCE((SELECT SUM(CASE t.kind WHEN 'payment' THEN t.amount ELSE -t.amount END)
          FROM transactions t WHERE t.party_id=p.id AND t.deleted=0 AND t.kind IN ('receipt','payment')),0) AS balance
      FROM parties p WHERE p.deleted=0 ORDER BY p.name''');
    return [
      for (final r in rows)
        Party(r['id'] as String, r['name'] as String, r['phone'] as String,
            r['note'] as String, (r['balance'] as num).round(), r['opening'] as int)
    ];
  }

  Future<void> saveParty({String? id, required String name, String phone = '', String note = '', int opening = 0}) async {
    await store.save('parties', {'id': ?id, 'name': name, 'phone': phone, 'note': note, 'opening': opening});
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
        WHERE it.product_id=p.id AND it.deleted=0 AND i.deleted=0 AND i.kind<>'proforma'),0) AS stock,
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
          groupId: r['group_id'] as String?,
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
    String? groupId,
    bool clearGroup = false,
  }) async {
    // Callers that do not know about groups (spreadsheet import...) keep the group a product has.
    var group = groupId;
    if (group == null && !clearGroup && id != null) {
      group = (await store.db.query('products', columns: ['group_id'], where: 'id=?', whereArgs: [id])).firstOrNull?['group_id'] as String?;
    }
    await store.save('products', {
      'id': ?id,
      'name': name, 'code': code, 'unit': unit, 'sale_price': salePrice, 'buy_price': buyPrice,
      'opening_stock': openingStock, 'min_stock': minStock, 'note': note, 'group_id': group,
    });
    changed();
  }

  // ---- product groups -----------------------------------------------------

  Future<List<ProductGroup>> productGroups() async {
    final rows = await store.db.rawQuery('''
      SELECT g.id, g.name, (SELECT COUNT(*) FROM products p WHERE p.group_id=g.id AND p.deleted=0) AS n
      FROM product_groups g WHERE g.deleted=0 ORDER BY g.name''');
    return [for (final r in rows) ProductGroup(r['id'] as String, r['name'] as String, (r['n'] as num).toInt())];
  }

  Future<String> saveProductGroup({String? id, required String name}) async {
    final gid = id ?? AppDb.newId();
    await store.save('product_groups', {'id': gid, 'name': name});
    changed();
    return gid;
  }

  /// The group called [name] (created when there is none).
  Future<String> groupIdByName(String name) async {
    final t = name.trim();
    final found = (await productGroups()).where((g) => g.name == t).firstOrNull;
    return found?.id ?? await saveProductGroup(name: t);
  }

  /// Deleting a group keeps its products; they just have no group any more.
  Future<void> deleteProductGroup(String id) async {
    await store.db.transaction((tx) async {
      await store.softDelete('product_groups', id, exec: tx);
      for (final p in await tx.query('products', where: 'group_id=? AND deleted=0', whereArgs: [id])) {
        await store.save('products', {...p, 'group_id': null}, exec: tx);
      }
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
    if (accountId != null) { where.add('(account_id=? OR to_account_id=?)'); args..add(accountId)..add(accountId); }
    if (partyId != null) { where.add('party_id=?'); args.add(partyId); }
    if (from != null) { where.add('date>=?'); args.add(from); }
    if (toExclusive != null) { where.add('date<?'); args.add(toExclusive); }
    final rows = await store.db.query('transactions',
        where: where.join(' AND '), whereArgs: args, orderBy: 'date DESC, updated_at DESC', limit: limit);
    return [
      for (final r in rows)
        Tx(r['id'] as String, r['date'] as String, r['kind'] as String, r['amount'] as int,
            r['account_id'] as String, r['party_id'] as String?, r['category_id'] as String?,
            r['invoice_id'] as String?, r['description'] as String, r['to_account_id'] as String?)
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
    String? toAccountId,
  }) async {
    final txId = id ?? AppDb.newId();
    await store.save('transactions', {
      'id': txId,
      'date': date, 'kind': kind, 'amount': amount, 'account_id': accountId,
      'party_id': partyId, 'category_id': categoryId, 'invoice_id': invoiceId,
      'description': description, 'to_account_id': toAccountId,
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
            (r['subtotal'] as num).round(), (r['paid'] as num).round(), r['tax_percent'] as int, r['ref_id'] as String?,
            r['order_id'] as String?, r['prepaid'] as int)
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

  /// Next free number. Pro-formas have their own series so real invoices
  /// never get gaps in their numbering.
  Future<int> nextInvoiceNumber([String kind = 'sale']) async {
    final r = await store.db.rawQuery(
        "SELECT COALESCE(MAX(number),0)+1 AS n FROM invoices WHERE deleted=0 AND ((kind='proforma')=?)", [kind == 'proforma' ? 1 : 0]);
    return r.first['n'] as int;
  }

  /// Makes a sale invoice from a pro-forma (same party, items, discount and
  /// VAT; dated today) and links the two. Returns the new invoice's id.
  Future<String> convertProforma(String proformaId) async {
    final pro = (await invoices()).firstWhere((i) => i.id == proformaId);
    if (pro.kind != 'proforma') throw StateError('این سند پیش‌فاکتور نیست.');
    if (pro.refId != null) throw StateError('این پیش‌فاکتور قبلاً به فاکتور تبدیل شده است.');
    final items = await invoiceItems(proformaId);
    final id = await saveInvoice(
      number: await nextInvoiceNumber('sale'),
      kind: 'sale',
      date: todayIso(),
      partyId: pro.partyId,
      discount: pro.discount,
      taxPercent: pro.taxPercent,
      note: pro.note,
      items: items,
    );
    await store.save('invoices', {
      ...(await store.db.query('invoices', where: 'id=?', whereArgs: [proformaId])).first,
      'ref_id': id,
    });
    changed();
    return id;
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
    String? orderId,
  }) async {
    final invId = id ?? AppDb.newId();
    await store.db.transaction((tx) async {
      // Editing keeps the link between a pro-forma and the invoice made from it.
      final keepRef = id == null ? null : (await tx.query('invoices', columns: ['ref_id'], where: 'id=?', whereArgs: [id])).firstOrNull?['ref_id'];
      // A sale made for an order counts the agreed percent of its total as paid
      // from the advance, never more than what is left of that advance.
      var prepaid = 0;
      final linked = kind == 'sale' ? orderId : null;
      if (linked != null) {
        final o = (await tx.query('orders', where: 'id=? AND deleted=0', whereArgs: [linked])).firstOrNull;
        if (o != null) {
          final net = items.fold<int>(0, (a, it) => a + it.total) - discount;
          final total = net + (net * taxPercent / 100).round();
          final others = (await tx.rawQuery(
                  'SELECT COALESCE(SUM(prepaid),0) AS n FROM invoices WHERE order_id=? AND deleted=0 AND id<>?', [linked, invId]))
              .first['n'] as num;
          final chq = await _orderCheques(tx, linked);
          final left = (o['advance_amount'] as int) + chq - (o['released'] as int) - others.round();
          final oi = await _orderItemsOf(tx, linked);
          prepaid = prepaidFor(total, (o['advance_percent'] as num).toDouble(), left, share: orderShare(oi, items));
        }
      }
      await store.save('invoices', {
        'id': invId, 'number': number, 'kind': kind, 'date': date,
        'party_id': partyId, 'discount': discount, 'tax_percent': taxPercent, 'note': note, 'ref_id': keepRef,
        'order_id': linked, 'prepaid': prepaid,
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

  /// Share (0..1) of an invoice's lines that are products of the order.
  static double orderShare(List<OrderItem> orderItems, List<InvoiceItem> items) {
    final sub = items.fold<int>(0, (a, it) => a + it.total);
    if (sub <= 0) return 0;
    final mine = items.where((it) => orderItems.any((o) => o.matches(it))).fold<int>(0, (a, it) => a + it.total);
    return mine / sub;
  }

  /// The part of an invoice [total] paid from an advance: [percent] of the
  /// [share] of the invoice that is for the order's products, capped by [left].
  static int prepaidFor(int total, double percent, int left, {double share = 1}) {
    final want = (total * share * percent / 100).round();
    return want.clamp(0, left < 0 ? 0 : left);
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

  // ---- orders with an advance payment ---------------------------------------

  Future<List<OrderItem>> _orderItemsOf(DatabaseExecutor ex, String orderId) async {
    final rows = await ex.query('order_items', where: 'order_id=? AND deleted=0', whereArgs: [orderId], orderBy: 'position');
    return [
      for (final r in rows)
        OrderItem(r['title'] as String, (r['qty'] as num).toDouble(), r['unit_price'] as int, productId: r['product_id'] as String?)
    ];
  }

  /// Cheques received for the order that have not bounced.
  Future<int> _orderCheques(DatabaseExecutor ex, String orderId) async {
    final r = await ex.rawQuery(
        "SELECT COALESCE(SUM(amount),0) AS n FROM cheques WHERE order_id=? AND deleted=0 AND status<>'bounced'", [orderId]);
    return (r.first['n'] as num).round();
  }

  /// Keeps an order consistent after one of its cheques changed (bounced,
  /// deleted, smaller...). If less advance is left than invoices already took
  /// from it, the credit given to the customer on closing is taken back first,
  /// then the newest invoices lose their prepaid part, so the customer owes it.
  Future<void> _rebalanceOrder(DatabaseExecutor ex, String orderId) async {
    final o = (await ex.query('orders', where: 'id=? AND deleted=0', whereArgs: [orderId])).firstOrNull;
    if (o == null) return;
    final eff = (o['advance_amount'] as int) + await _orderCheques(ex, orderId);
    final invs = await ex.query('invoices',
        where: 'order_id=? AND deleted=0 AND prepaid>0', whereArgs: [orderId], orderBy: 'date DESC, number DESC');
    final applied = invs.fold<int>(0, (a, i) => a + (i['prepaid'] as int));
    var released = o['released'] as int;
    var over = applied + released - eff;
    if (over <= 0) return;
    final cutReleased = released < over ? released : over;
    released -= cutReleased;
    over -= cutReleased;
    for (final inv in invs) {
      if (over <= 0) break;
      final cut = (inv['prepaid'] as int) < over ? inv['prepaid'] as int : over;
      await store.save('invoices', {...inv, 'prepaid': (inv['prepaid'] as int) - cut}, exec: ex);
      over -= cut;
    }
    if (cutReleased > 0) await store.save('orders', {...o, 'released': released}, exec: ex);
  }

  Future<List<Order>> orders({String? partyId}) async {
    final rows = await store.db.rawQuery('''
      SELECT o.*,
        COALESCE((SELECT SUM(i.prepaid) FROM invoices i WHERE i.order_id=o.id AND i.deleted=0),0) AS applied,
        COALESCE((SELECT SUM(c.amount) FROM cheques c WHERE c.order_id=o.id AND c.deleted=0 AND c.status<>'bounced'),0) AS chq
      FROM orders o WHERE o.deleted=0 ${partyId == null ? '' : 'AND o.party_id=?'}
      ORDER BY o.date DESC, o.number DESC''', partyId == null ? null : [partyId]);
    final itemRows = await store.db.rawQuery('''
      SELECT oi.*,
        COALESCE((SELECT SUM(it.qty) FROM invoice_items it JOIN invoices i ON i.id=it.invoice_id
          WHERE i.order_id=oi.order_id AND i.deleted=0 AND it.deleted=0
            AND ((oi.product_id IS NOT NULL AND it.product_id=oi.product_id)
              OR (oi.product_id IS NULL AND it.title=oi.title))),0) AS invoiced
      FROM order_items oi JOIN orders o ON o.id=oi.order_id AND o.deleted=0
      WHERE oi.deleted=0 ORDER BY oi.position''');
    final byOrder = <String, List<OrderItem>>{};
    for (final r in itemRows) {
      (byOrder[r['order_id'] as String] ??= []).add(OrderItem(r['title'] as String, (r['qty'] as num).toDouble(),
          r['unit_price'] as int, productId: r['product_id'] as String?, invoicedQty: (r['invoiced'] as num).toDouble()));
    }
    return [
      for (final r in rows)
        Order(
          id: r['id'] as String, number: r['number'] as int, date: r['date'] as String, partyId: r['party_id'] as String,
          title: r['title'] as String, items: byOrder[r['id']] ?? [], percent: (r['advance_percent'] as num).toDouble(),
          cash: r['advance_amount'] as int, chequeAmount: (r['chq'] as num).round(), accountId: r['account_id'] as String?, txId: r['tx_id'] as String?,
          status: r['status'] as String, released: r['released'] as int, closedDate: r['closed_date'] as String,
          note: r['note'] as String, applied: (r['applied'] as num).round(),
        )
    ];
  }

  Future<int> nextOrderNumber() async {
    final r = await store.db.rawQuery('SELECT COALESCE(MAX(number),0)+1 AS n FROM orders WHERE deleted=0');
    return r.first['n'] as int;
  }

  /// Creates or edits an order with one or several products. The advance is
  /// booked as a receipt into [accountId] that has no party, so the customer
  /// does not become a creditor; it is applied to invoices as they are issued.
  Future<String> saveOrder({
    String? id,
    required int number,
    required String date,
    required String partyId,
    required List<OrderItem> items,
    required double percent,
    required int advance,
    String? accountId,
    String note = '',
    List<ChequeDraft> cheques = const [],
  }) async {
    if (items.isEmpty) throw StateError('حداقل یک کالا برای سفارش لازم است.');
    if (advance > 0 && accountId == null) throw StateError('حساب دریافت پیش‌دریافت را انتخاب کنید.');
    final oid = id ?? AppDb.newId();
    await store.db.transaction((tx) async {
      final old = id == null ? null : (await tx.query('orders', where: 'id=?', whereArgs: [id])).firstOrNull;
      final applied = id == null
          ? 0
          : ((await tx.rawQuery('SELECT COALESCE(SUM(prepaid),0) AS n FROM invoices WHERE order_id=? AND deleted=0', [id])).first['n'] as num).round();
      final released = (old?['released'] as int?) ?? 0;
      final chequeSum = id == null ? 0 : await _orderCheques(tx, id);
      if (advance + chequeSum < applied + released) {
        throw StateError('جمع پیش‌دریافت (نقدی و چکی) نمی‌تواند از مقدار کسرشده روی فاکتورها (${money(applied + released)}) کمتر باشد.');
      }
      final partyName = (await tx.query('parties', columns: ['name'], where: 'id=?', whereArgs: [partyId])).firstOrNull?['name'] ?? '';
      var txId = old?['tx_id'] as String?;
      if (advance > 0) {
        txId ??= AppDb.newId();
        await store.save('transactions', {
          'id': txId, 'date': date, 'kind': 'receipt', 'amount': advance, 'account_id': accountId,
          'party_id': null, 'category_id': null, 'invoice_id': null,
          'description': 'پیش‌دریافت سفارش ${faDigits('$number')} - $partyName', 'to_account_id': null,
        }, exec: tx);
      } else if (txId != null) {
        await store.softDelete('transactions', txId, exec: tx);
        txId = null;
      }
      // The order row keeps a short summary of its products (for lists).
      final summary = items.length == 1 ? items.first.title : '${items.first.title} و ${faDigits('${items.length - 1}')} کالای دیگر';
      await store.save('orders', {
        'id': oid, 'number': number, 'date': date, 'party_id': partyId, 'product_id': null, 'title': summary,
        'qty': items.fold<double>(0, (a, i) => a + i.qty), 'unit_price': 0, 'advance_percent': percent, 'advance_amount': advance,
        'account_id': accountId, 'tx_id': txId, 'status': old?['status'] ?? 'open', 'released': released,
        'closed_date': old?['closed_date'] ?? '', 'note': note,
      }, exec: tx);
      for (final o in await tx.query('order_items', columns: ['id'], where: 'order_id=? AND deleted=0', whereArgs: [oid])) {
        await store.softDelete('order_items', o['id'] as String, exec: tx);
      }
      for (var i = 0; i < items.length; i++) {
        await store.save('order_items', {
          'order_id': oid, 'product_id': items[i].productId, 'title': items[i].title, 'qty': items[i].qty,
          'unit_price': items[i].unitPrice, 'position': i,
        }, exec: tx);
      }
      // Part (or all) of the advance can come as cheques received from the customer.
      for (final d in cheques.where((d) => d.amount > 0)) {
        await store.save('cheques', {
          'kind': 'received', 'number': d.number, 'bank': d.bank, 'amount': d.amount, 'due_date': d.dueDate,
          'party_id': partyId, 'status': 'pending', 'note': 'پیش‌دریافت سفارش ${faDigits('$number')}', 'order_id': oid,
        }, exec: tx);
      }
    });
    changed();
    return oid;
  }

  /// Closes an order: whatever is left of the advance becomes a credit of the
  /// customer. Reopening takes that credit back.
  Future<void> setOrderOpen(String id, bool open) async {
    final o = (await orders()).firstWhere((x) => x.id == id);
    await store.save('orders', {
      ...(await store.db.query('orders', where: 'id=?', whereArgs: [id])).first,
      'status': open ? 'open' : 'closed',
      'released': open ? 0 : o.available,
      'closed_date': open ? '' : todayIso(),
    });
    changed();
  }

  /// Returns an error message when invoices still use the order.
  Future<String?> deleteOrder(String id) async {
    if (await _count('invoices', 'order_id', id) > 0) return 'برای این سفارش فاکتور صادر شده است؛ ابتدا فاکتورها را حذف یا از سفارش جدا کنید.';
    final o = (await store.db.query('orders', where: 'id=?', whereArgs: [id])).first;
    await store.db.transaction((tx) async {
      await store.softDelete('orders', id, exec: tx);
      for (final it in await tx.query('order_items', columns: ['id'], where: 'order_id=? AND deleted=0', whereArgs: [id])) {
        await store.softDelete('order_items', it['id'] as String, exec: tx);
      }
      if (o['tx_id'] != null) await store.softDelete('transactions', o['tx_id'] as String, exec: tx);
    });
    changed();
    return null;
  }

  // ---- delivery receipts --------------------------------------------------

  Future<List<Delivery>> deliveries() async {
    final rows = await store.db.query('deliveries', where: 'deleted=0', orderBy: 'date DESC, number DESC');
    return [
      for (final r in rows)
        Delivery(r['id'] as String, r['number'] as int, r['date'] as String, r['party_id'] as String?,
            r['recipient'] as String, r['address'] as String, r['note'] as String)
    ];
  }

  Future<List<DeliveryItem>> deliveryItems(String deliveryId) async {
    final rows = await store.db.query('delivery_items',
        where: 'delivery_id=? AND deleted=0', whereArgs: [deliveryId], orderBy: 'position');
    return [
      for (final r in rows)
        DeliveryItem(r['title'] as String, (r['qty'] as num).toDouble(),
            unit: r['unit'] as String, productId: r['product_id'] as String?)
    ];
  }

  Future<int> nextDeliveryNumber() async {
    final r = await store.db.rawQuery('SELECT COALESCE(MAX(number),0)+1 AS n FROM deliveries WHERE deleted=0');
    return r.first['n'] as int;
  }

  /// Creates or replaces a delivery receipt together with its items.
  Future<String> saveDelivery({
    String? id,
    required int number,
    required String date,
    String? partyId,
    String recipient = '',
    String address = '',
    String note = '',
    required List<DeliveryItem> items,
  }) async {
    final did = id ?? AppDb.newId();
    await store.db.transaction((tx) async {
      await store.save('deliveries', {
        'id': did, 'number': number, 'date': date, 'party_id': partyId,
        'recipient': recipient, 'address': address, 'note': note,
      }, exec: tx);
      final old = await tx.query('delivery_items',
          columns: ['id'], where: 'delivery_id=? AND deleted=0', whereArgs: [did]);
      for (final o in old) {
        await store.softDelete('delivery_items', o['id'] as String, exec: tx);
      }
      for (var i = 0; i < items.length; i++) {
        await store.save('delivery_items', {
          'delivery_id': did, 'title': items[i].title, 'qty': items[i].qty,
          'unit': items[i].unit, 'position': i, 'product_id': items[i].productId,
        }, exec: tx);
      }
    });
    changed();
    return did;
  }

  Future<void> deleteDelivery(String id) async {
    await store.db.transaction((tx) async {
      await store.softDelete('deliveries', id, exec: tx);
      final items = await tx.query('delivery_items',
          columns: ['id'], where: 'delivery_id=? AND deleted=0', whereArgs: [id]);
      for (final o in items) {
        await store.softDelete('delivery_items', o['id'] as String, exec: tx);
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
          orderId: r['order_id'] as String?,
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
    String? orderId,
  }) async {
    // Editing keeps the status/transaction/order link of an existing cheque.
    Map<String, Object?> keep = {};
    if (id != null) {
      final old = await store.db.query('cheques', where: 'id=?', whereArgs: [id]);
      if (old.isNotEmpty) {
        keep = {'status': old.first['status'], 'account_id': old.first['account_id'], 'tx_id': old.first['tx_id'], 'order_id': old.first['order_id']};
      }
    }
    final linked = (keep['order_id'] as String?) ?? orderId;
    await store.save('cheques', {
      'id': ?id, 'kind': kind, 'number': number, 'bank': bank, 'amount': amount,
      'due_date': dueDate, 'party_id': partyId, 'note': note, ...keep, 'order_id': linked,
    });
    if (linked != null) await _rebalanceOrder(store.db, linked);
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
        // The cash of an advance cheque must not credit the customer: the advance is already counted on the order.
        partyId: c.orderId != null ? null : c.partyId,
        description: c.orderId != null ? 'وصول چک پیش‌دریافت ${c.number}'.trim() : 'وصول چک ${c.number}'.trim(),
      );
    }
    await store.save('cheques', {
      'id': c.id, 'kind': c.kind, 'number': c.number, 'bank': c.bank, 'amount': c.amount,
      'due_date': c.dueDate, 'party_id': c.partyId, 'note': c.note,
      'status': status, 'account_id': status == 'cleared' ? accountId : null, 'tx_id': txId, 'order_id': c.orderId,
    });
    if (c.orderId != null) await _rebalanceOrder(store.db, c.orderId!);
    changed();
  }

  Future<void> deleteCheque(Cheque c) async {
    if (c.txId != null) await store.softDelete('transactions', c.txId!);
    await store.softDelete('cheques', c.id);
    if (c.orderId != null) await _rebalanceOrder(store.db, c.orderId!);
    changed();
  }

  // ---- reports ------------------------------------------------------------

  Future<MonthReport> report(String from, String toExclusive) async {
    final rows = await store.db.rawQuery('''
      SELECT COALESCE(c.name,'بدون دسته‌بندی') AS name, t.kind AS kind, SUM(t.amount) AS total
      FROM transactions t LEFT JOIN categories c ON c.id=t.category_id
      WHERE t.deleted=0 AND t.kind IN ('receipt','payment') AND t.date>=? AND t.date<?
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
      if (!i.info.ledger) continue;
      items.add((i.date, 0, '${i.info.label} ${faDigits('${i.number}')}', i.info.partyOwesUs ? i.total : -i.total));
      if (i.prepaid > 0) items.add((i.date, 1, 'کسر از پیش‌دریافت (فاکتور ${faDigits('${i.number}')})', -i.prepaid));
    }
    for (final o in await orders(partyId: partyId)) {
      if (o.released > 0 && o.closedDate.isNotEmpty) {
        items.add((o.closedDate, 1, 'پیش‌دریافت مصرف‌نشدهٔ سفارش ${faDigits('${o.number}')} (اعتبار مشتری)', -o.released));
      }
    }
    for (final t in await transactions(partyId: partyId)) {
      final what = t.kind == 'receipt' ? 'دریافت' : 'پرداخت';
      items.add((t.date, 1, t.description.isEmpty ? what : '$what - ${t.description}', t.kind == 'payment' ? t.amount : -t.amount));
    }
    items.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    // A party can start with a balance (e.g. when moving from another system).
    final party = (await parties()).where((p) => p.id == partyId).firstOrNull;
    var running = party?.opening ?? 0;
    var opening = running;
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

  /// The ledger (معین) of one party: every invoice and every payment/receipt
  /// between us, oldest first, with a running balance. Same numbers as the
  /// party statement, with the kind and number of each document.
  Future<PartyLedger> partyLedger(String partyId, {String? from, String? toExclusive}) async {
    final accNames = {for (final a in await accounts()) a.id: a.name};
    final invNumbers = <String, int>{};
    // date, order within the day, row without balance, signed amount
    final items = <(String, int, PartyLedgerRow, int)>[];
    for (final i in await invoices(partyId: partyId)) {
      invNumbers[i.id] = i.number;
      if (!i.info.ledger) continue;
      final lines = await invoiceItems(i.id);
      final names = lines.take(3).map((l) => '${l.title} × ${faDigits(numText(l.qty))}').join('، ');
      final more = lines.length > 3 ? ' و ${faDigits('${lines.length - 3}')} قلم دیگر' : '';
      final signed = i.info.partyOwesUs ? i.total : -i.total;
      items.add((
        i.date,
        0,
        PartyLedgerRow(
          date: i.date, type: i.info.label, number: faDigits('${i.number}'), invoiceId: i.id,
          description: [names + more, if (i.note.isNotEmpty) i.note].where((t) => t.isNotEmpty).join(' • '),
          debit: signed > 0 ? signed : 0, credit: signed < 0 ? -signed : 0, balance: 0,
        ),
        signed,
      ));
      if (i.prepaid > 0) {
        items.add((
          i.date,
          1,
          PartyLedgerRow(
            date: i.date, type: 'کسر از پیش‌دریافت', number: faDigits('${i.number}'), invoiceId: i.id,
            description: 'پیش‌دریافت سفارش برای ${i.info.label} ${faDigits('${i.number}')}', credit: i.prepaid, balance: 0,
          ),
          -i.prepaid,
        ));
      }
    }
    for (final t in await transactions(partyId: partyId)) {
      if (t.kind != 'receipt' && t.kind != 'payment') continue;
      final signed = t.kind == 'payment' ? t.amount : -t.amount;
      final inv = t.invoiceId == null ? null : invNumbers[t.invoiceId];
      items.add((
        t.date,
        2,
        PartyLedgerRow(
          date: t.date, type: t.kind == 'receipt' ? 'دریافت' : 'پرداخت', number: inv == null ? '' : faDigits('$inv'),
          description: [
            if (accNames[t.accountId] != null) accNames[t.accountId]!,
            if (inv != null) 'بابت فاکتور ${faDigits('$inv')}',
            if (t.description.isNotEmpty) t.description,
          ].join(' • '),
          debit: signed > 0 ? signed : 0, credit: signed < 0 ? -signed : 0, balance: 0,
        ),
        signed,
      ));
    }
    for (final o in await orders(partyId: partyId)) {
      if (o.released > 0 && o.closedDate.isNotEmpty) {
        items.add((
          o.closedDate,
          3,
          PartyLedgerRow(
            date: o.closedDate, type: 'اعتبار پیش‌دریافت', number: faDigits('${o.number}'),
            description: 'پیش‌دریافت مصرف‌نشدهٔ سفارش ${faDigits('${o.number}')}', credit: o.released, balance: 0,
          ),
          -o.released,
        ));
      }
    }
    items.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    final party = (await parties()).where((p) => p.id == partyId).firstOrNull;
    var running = party?.opening ?? 0;
    var opening = running;
    final rows = <PartyLedgerRow>[];
    for (final it in items) {
      if (toExclusive != null && it.$1.compareTo(toExclusive) >= 0) continue;
      running += it.$4;
      if (from != null && it.$1.compareTo(from) < 0) {
        opening = running;
        continue;
      }
      final r = it.$3;
      rows.add(PartyLedgerRow(
        date: r.date, type: r.type, number: r.number, description: r.description,
        debit: r.debit, credit: r.credit, balance: running, invoiceId: r.invoiceId,
      ));
    }
    final pending = (await cheques(status: 'pending')).where((c) => c.partyId == partyId).toList();
    return PartyLedger(opening, rows, running, pending);
  }

  // ---- financial reports ---------------------------------------------------

  /// VAT of the invoices of a period (pro-formas never count).
  Future<VatReport> vatReport(String from, String toExclusive) async {
    final names = {for (final p in await parties()) p.id: p.name};
    final lines = <VatLine>[];
    for (final i in await invoices()) {
      if (!i.info.ledger || i.date.compareTo(from) < 0 || i.date.compareTo(toExclusive) >= 0) continue;
      final sign = i.kind.endsWith('return') ? -1 : 1;
      lines.add(VatLine(i.date, i.number, i.kind, names[i.partyId] ?? '', sign * i.net, sign * i.tax));
    }
    lines.sort((a, b) => a.date.compareTo(b.date));
    return VatReport(lines);
  }

  /// Unit cost used to value stock and goods sold: the cost sheet if there is
  /// one, otherwise the weighted average of the opening stock (at the buy
  /// price) and the purchases before [toExclusive].
  Future<Map<String, double>> unitCosts(String toExclusive) async {
    final rows = await store.db.rawQuery('''
      SELECT p.id AS id, p.buy_price AS buy, p.opening_stock AS opening,
        COALESCE((SELECT c.unit_cost FROM costings c WHERE c.product_id=p.id AND c.deleted=0),0) AS cost,
        COALESCE(SUM(CASE WHEN i.kind='purchase' THEN it.qty WHEN i.kind='purchase_return' THEN -it.qty ELSE 0 END),0) AS qty,
        COALESCE(SUM(CASE WHEN i.kind='purchase' THEN it.qty*it.unit_price WHEN i.kind='purchase_return' THEN -it.qty*it.unit_price ELSE 0 END),0) AS value
      FROM products p
      LEFT JOIN invoice_items it ON it.product_id=p.id AND it.deleted=0
      LEFT JOIN invoices i ON i.id=it.invoice_id AND i.deleted=0 AND i.date<?
      WHERE p.deleted=0 GROUP BY p.id''', [toExclusive]);
    final out = <String, double>{};
    for (final r in rows) {
      final cost = (r['cost'] as num).toDouble();
      if (cost > 0) {
        out[r['id'] as String] = cost;
        continue;
      }
      final buy = (r['buy'] as num).toDouble();
      final qty = (r['opening'] as num).toDouble() + (r['qty'] as num).toDouble();
      final value = (r['opening'] as num).toDouble() * buy + (r['value'] as num).toDouble();
      out[r['id'] as String] = qty > 0 ? value / qty : buy;
    }
    return out;
  }

  /// Profit and loss of a period. Sales come from invoices; other income and
  /// expenses come from categorised money movements that have no person and
  /// no invoice (rent, salaries, bank interest...).
  Future<ProfitLoss> profitLoss(String from, String toExclusive) async {
    final costs = await unitCosts(toExclusive);
    final lines = await store.db.rawQuery('''
      SELECT i.kind AS kind, it.product_id AS pid, it.qty AS qty, ROUND(it.qty*it.unit_price) AS amount, i.id AS inv
      FROM invoice_items it JOIN invoices i ON i.id=it.invoice_id
      WHERE it.deleted=0 AND i.deleted=0 AND i.kind IN ('sale','sale_return') AND i.date>=? AND i.date<?''', [from, toExclusive]);
    var sales = 0.0, cogs = 0.0, unlinked = 0.0;
    for (final l in lines) {
      final sign = l['kind'] == 'sale' ? 1 : -1;
      final amount = (l['amount'] as num).toDouble() * sign;
      sales += amount;
      final pid = l['pid'] as String?;
      if (pid == null || !costs.containsKey(pid)) {
        unlinked += amount;
      } else {
        cogs += (l['qty'] as num).toDouble() * sign * costs[pid]!;
      }
    }
    // Invoice discounts reduce sales (returns give them back).
    for (final i in await invoices()) {
      if (i.date.compareTo(from) < 0 || i.date.compareTo(toExclusive) >= 0) continue;
      if (i.kind == 'sale') sales -= i.discount;
      if (i.kind == 'sale_return') sales += i.discount;
    }
    final cat = await store.db.rawQuery('''
      SELECT t.kind AS kind, COALESCE(c.name,'') AS name, c.kind AS ckind, SUM(t.amount) AS total
      FROM transactions t LEFT JOIN categories c ON c.id=t.category_id AND c.deleted=0
      WHERE t.deleted=0 AND t.kind IN ('receipt','payment') AND t.party_id IS NULL AND t.invoice_id IS NULL
        AND t.date>=? AND t.date<? GROUP BY t.kind, c.id''', [from, toExclusive]);
    final income = <(String, int)>[];
    final expense = <(String, int)>[];
    var uncategorized = 0;
    for (final r in cat) {
      final total = (r['total'] as num).round();
      if (r['name'] == '') {
        if (r['kind'] == 'payment') uncategorized += total;
      } else if (r['kind'] == 'receipt' && r['ckind'] == 'income') {
        income.add((r['name'] as String, total));
      } else if (r['kind'] == 'payment' && r['ckind'] == 'expense') {
        expense.add((r['name'] as String, total));
      }
    }
    expense.sort((a, b) => b.$2.compareTo(a.$2));
    income.sort((a, b) => b.$2.compareTo(a.$2));
    return ProfitLoss(
      sales: sales.round(),
      cogs: cogs.round(),
      otherIncome: income.fold(0, (a, e) => a + e.$2),
      expenses: expense.fold(0, (a, e) => a + e.$2),
      otherIncomeByCategory: income,
      uncategorized: uncategorized,
      unlinkedSales: unlinked.round(),
    )..expensesByCategory = expense;
  }

  /// What the business owns and owes right now.
  Future<FinancialPosition> financialPosition() async {
    final accs = await accounts();
    final parts = await parties();
    final costs = await unitCosts('9999-12-31');
    var inventory = 0.0;
    for (final p in await products()) {
      if (p.stock > 0) inventory += p.stock * (costs[p.id] ?? p.buyPrice);
    }
    final cheques = await this.cheques(status: 'pending');
    return FinancialPosition(
      accounts: [for (final a in accs) (a.name, a.balance)],
      receivables: parts.where((p) => p.balance > 0).fold(0, (a, p) => a + p.balance),
      inventory: inventory.round(),
      chequesReceived: cheques.where((c) => c.kind == 'received').fold(0, (a, c) => a + c.amount),
      payables: parts.where((p) => p.balance < 0).fold(0, (a, p) => a - p.balance),
      chequesIssued: cheques.where((c) => c.kind == 'issued').fold(0, (a, c) => a + c.amount),
      advances: (await orders()).fold(0, (a, o) => a + o.available),
    );
  }

  /// Who owes us, by how long ago the unpaid sales were made. Payments are
  /// applied to the oldest invoices first, so what remains is the newest.
  Future<List<AgeingRow>> ageing({DateTime? asOf}) async {
    final now = asOf ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final byParty = <String, List<Invoice>>{};
    for (final i in await invoices()) {
      if (i.info.ledger && i.info.partyOwesUs) (byParty[i.partyId] ??= []).add(i);
    }
    final rows = <AgeingRow>[];
    for (final p in await parties()) {
      if (p.balance <= 0) continue;
      var left = p.balance;
      final buckets = [0, 0, 0, 0];
      final list = (byParty[p.id] ?? [])..sort((a, b) => b.date.compareTo(a.date)); // newest first
      for (final i in list) {
        if (left <= 0) break;
        final owed = i.total - i.prepaid;
        final part = owed < left ? owed : left;
        left -= part;
        final age = today.difference(DateTime.parse(i.date)).inDays;
        buckets[age <= 30 ? 0 : (age <= 60 ? 1 : (age <= 90 ? 2 : 3))] += part;
      }
      buckets[3] += left; // opening balance and anything older than the invoices on record
      rows.add(AgeingRow(p.id, p.name, buckets, p.balance));
    }
    rows.sort((a, b) => b.total.compareTo(a.total));
    return rows;
  }

  /// Movements of one account in a period with a running balance.
  Future<Ledger> accountLedger(String accountId, {String? from, String? toExclusive}) async {
    final acc = (await accounts()).firstWhere((a) => a.id == accountId);
    final names = {for (final a in await accounts()) a.id: a.name, for (final p in await parties()) p.id: p.name};
    final txs = (await transactions(accountId: accountId)).reversed.toList(); // oldest first
    var running = acc.opening;
    num opening = running;
    final lines = <LedgerLine>[];
    for (final t in txs) {
      final inAmt = t.kind == 'receipt' || (t.kind == 'transfer' && t.toAccountId == accountId) ? t.amount : 0;
      final outAmt = t.kind == 'payment' || (t.kind == 'transfer' && t.accountId == accountId) ? t.amount : 0;
      running += inAmt - outAmt;
      if (from != null && t.date.compareTo(from) < 0) {
        opening = running;
        continue;
      }
      if (toExclusive != null && t.date.compareTo(toExclusive) >= 0) continue;
      final who = t.kind == 'transfer'
          ? (t.accountId == accountId ? 'انتقال به ${names[t.toAccountId] ?? ''}' : 'انتقال از ${names[t.accountId] ?? ''}')
          : [txKindLabel(t.kind), if (t.partyId != null) names[t.partyId] ?? ''].join(' • ');
      lines.add(LedgerLine(t.date, [who, if (t.description.isNotEmpty) t.description].join(' - '), inAmt, outAmt, running));
    }
    final closing = lines.isEmpty ? opening : lines.last.balance;
    return Ledger(opening, lines, closing);
  }

  /// Stock movements of one product (kardex): purchases and returns in, sales out.
  Future<Ledger> productCard(String productId, {String? from, String? toExclusive}) async {
    final prod = (await products()).firstWhere((p) => p.id == productId);
    final names = {for (final p in await parties()) p.id: p.name};
    final rows = await store.db.rawQuery('''
      SELECT i.date AS date, i.number AS number, i.kind AS kind, i.party_id AS party, it.qty AS qty
      FROM invoice_items it JOIN invoices i ON i.id=it.invoice_id
      WHERE it.deleted=0 AND i.deleted=0 AND i.kind<>'proforma' AND it.product_id=?
      ORDER BY i.date, i.number''', [productId]);
    num running = prod.openingStock;
    num opening = running;
    final lines = <LedgerLine>[];
    for (final r in rows) {
      final kind = r['kind'] as String;
      final qty = (r['qty'] as num).toDouble();
      final stockIn = invoiceKind(kind).stockIn;
      running += stockIn ? qty : -qty;
      final date = r['date'] as String;
      if (from != null && date.compareTo(from) < 0) {
        opening = running;
        continue;
      }
      if (toExclusive != null && date.compareTo(toExclusive) >= 0) continue;
      lines.add(LedgerLine(date, '${invoiceKind(kind).label} ${faDigits('${r['number']}')} • ${names[r['party']] ?? ''}', stockIn ? qty : 0, stockIn ? 0 : qty, running));
    }
    return Ledger(opening, lines, lines.isEmpty ? opening : lines.last.balance);
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
      await scale('parties', ['opening']);
      await scale('transactions', ['amount']);
      await scale('invoices', ['discount', 'prepaid']);
      await scale('orders', ['advance_amount', 'released']);
      await scale('order_items', ['unit_price']);
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
