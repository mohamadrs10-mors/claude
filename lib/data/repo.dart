import 'package:flutter/foundation.dart';

import 'db.dart';

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

class Tx {
  Tx(this.id, this.date, this.kind, this.amount, this.accountId, this.partyId,
      this.categoryId, this.invoiceId, this.description);
  final String id, date, kind; // kind: receipt | payment
  final int amount;
  final String accountId;
  final String? partyId, categoryId, invoiceId;
  final String description;
}

class InvoiceItem {
  InvoiceItem(this.title, this.qty, this.unitPrice);
  final String title;
  final double qty;
  final int unitPrice;
  int get total => (qty * unitPrice).round();
}

class Invoice {
  Invoice(this.id, this.number, this.kind, this.date, this.partyId, this.discount,
      this.note, this.subtotal, this.paid);
  final String id, kind, date, partyId, note; // kind: sale | purchase
  final int number, discount, subtotal, paid;
  int get total => subtotal - discount;
  int get remaining => total - paid;
}

class MonthReport {
  MonthReport(this.income, this.expense, this.byCategory);
  final int income, expense;

  /// (name, kind, total) sorted by total descending.
  final List<(String, String, int)> byCategory;
  int get net => income - expense;
}

/// All accounting queries and mutations. UI listens to it and rebuilds when the
/// data changes (including changes that arrive from a sync).
class Repo extends ChangeNotifier {
  Repo(this.store);
  final AppDb store;

  void changed() => notifyListeners();

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

  Future<List<Party>> parties() async {
    final rows = await store.db.rawQuery('''
      SELECT p.id, p.name, p.phone, p.note,
        COALESCE((SELECT SUM(
            (SELECT COALESCE(SUM(ROUND(it.qty*it.unit_price)),0) FROM invoice_items it
               WHERE it.invoice_id=i.id AND it.deleted=0) - i.discount)
            * CASE i.kind WHEN 'sale' THEN 1 ELSE -1 END
          FROM invoices i WHERE i.party_id=p.id AND i.deleted=0),0)
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
    final n = await _count('transactions', 'party_id', id) + await _count('invoices', 'party_id', id);
    if (n > 0) return 'این شخص دارای تراکنش یا فاکتور است و قابل حذف نیست.';
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

  Future<void> saveTx({
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
    await store.save('transactions', {
      'id': ?id,
      'date': date, 'kind': kind, 'amount': amount, 'account_id': accountId,
      'party_id': partyId, 'category_id': categoryId, 'invoice_id': invoiceId,
      'description': description,
    });
    changed();
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
            (r['subtotal'] as num).round(), (r['paid'] as num).round())
    ];
  }

  Future<List<InvoiceItem>> invoiceItems(String invoiceId) async {
    final rows = await store.db.query('invoice_items',
        where: 'invoice_id=? AND deleted=0', whereArgs: [invoiceId], orderBy: 'position');
    return [
      for (final r in rows)
        InvoiceItem(r['title'] as String, (r['qty'] as num).toDouble(), r['unit_price'] as int)
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
    required String note,
    required List<InvoiceItem> items,
  }) async {
    final invId = id ?? AppDb.newId();
    await store.db.transaction((tx) async {
      await store.save('invoices', {
        'id': invId, 'number': number, 'kind': kind, 'date': date,
        'party_id': partyId, 'discount': discount, 'note': note,
      }, exec: tx);
      final old = await tx.query('invoice_items',
          columns: ['id'], where: 'invoice_id=? AND deleted=0', whereArgs: [invId]);
      for (final o in old) {
        await store.softDelete('invoice_items', o['id'] as String, exec: tx);
      }
      for (var i = 0; i < items.length; i++) {
        await store.save('invoice_items', {
          'invoice_id': invId, 'title': items[i].title, 'qty': items[i].qty,
          'unit_price': items[i].unitPrice, 'position': i,
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

  // ---- helpers ------------------------------------------------------------

  Future<int> _count(String table, String column, String id) async {
    final r = await store.db.rawQuery(
        'SELECT COUNT(*) AS n FROM $table WHERE deleted=0 AND $column=?', [id]);
    return r.first['n'] as int;
  }
}
