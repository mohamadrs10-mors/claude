import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'access.dart';
import 'db_ops.dart';

/// Tables that take part in synchronisation. Every one of them carries the
/// common columns: id, updated_at, deleted, device_id and the local-only seq.
const syncTables = [
  'accounts',
  'parties',
  'categories',
  'products',
  'cheques',
  'settings',
  'costings',
  'formulas',
  'invoices',
  'invoice_items',
  'transactions',
  'deliveries',
  'delivery_items',
  'orders',
  'order_items',
  'product_groups',
  'warehouses',
  'stock_moves',
  'employees',
  'attendance',
  'payslips',
  'payroll_items',
  'recurring_expenses',
];

const _schemaVersion = 17;

const _v2Tables = [
  '''CREATE TABLE products (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    name TEXT NOT NULL, code TEXT NOT NULL DEFAULT '', unit TEXT NOT NULL DEFAULT 'عدد',
    sale_price INTEGER NOT NULL DEFAULT 0, buy_price INTEGER NOT NULL DEFAULT 0,
    opening_stock REAL NOT NULL DEFAULT 0, min_stock REAL NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE cheques (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    kind TEXT NOT NULL, number TEXT NOT NULL DEFAULT '', bank TEXT NOT NULL DEFAULT '',
    amount INTEGER NOT NULL, due_date TEXT NOT NULL, party_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending', account_id TEXT, tx_id TEXT,
    note TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE settings (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL, value TEXT NOT NULL DEFAULT '')''',
  'CREATE INDEX idx_items_product ON invoice_items(product_id)',
];

const _v3Tables = [
  // One cost sheet per product (its id is the product id). `lines` is JSON.
  '''CREATE TABLE costings (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    product_id TEXT NOT NULL, batch_qty REAL NOT NULL DEFAULT 1, waste_percent REAL NOT NULL DEFAULT 0,
    lines TEXT NOT NULL DEFAULT '[]', unit_cost INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE formulas (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    name TEXT NOT NULL, expression TEXT NOT NULL)''',
];

/// Delivery receipts (رسید تحویل): a document without prices that is not tied
/// to an invoice. Neither table touches balances or stock.
const _v5Tables = [
  '''CREATE TABLE deliveries (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    number INTEGER NOT NULL, date TEXT NOT NULL, party_id TEXT,
    recipient TEXT NOT NULL DEFAULT '', address TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE delivery_items (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    delivery_id TEXT NOT NULL, title TEXT NOT NULL, qty REAL NOT NULL,
    unit TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, product_id TEXT)''',
  'CREATE INDEX idx_delivery_items_dlv ON delivery_items(delivery_id)',
  'CREATE INDEX idx_deliveries_seq ON deliveries(seq)',
  'CREATE INDEX idx_delivery_items_seq ON delivery_items(seq)',
];

/// Orders with an advance payment (سفارش و پیش‌دریافت). The advance is received
/// into an account without crediting the party; every sale invoice made for the
/// order counts `advance_percent` of its total as already paid (invoices.prepaid).
const _v6Tables = [
  '''CREATE TABLE orders (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    number INTEGER NOT NULL, date TEXT NOT NULL, party_id TEXT NOT NULL,
    product_id TEXT, title TEXT NOT NULL, qty REAL NOT NULL DEFAULT 0, unit_price INTEGER NOT NULL DEFAULT 0,
    advance_percent REAL NOT NULL DEFAULT 0, advance_amount INTEGER NOT NULL DEFAULT 0,
    account_id TEXT, tx_id TEXT, status TEXT NOT NULL DEFAULT 'open',
    released INTEGER NOT NULL DEFAULT 0, closed_date TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '')''',
  'CREATE INDEX idx_orders_seq ON orders(seq)',
  'CREATE INDEX idx_invoices_order ON invoices(order_id)',
];

/// An order can hold several products. Each row is one product with the
/// quantity and unit price agreed in the order.
const _v7Tables = [
  '''CREATE TABLE order_items (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    order_id TEXT NOT NULL, product_id TEXT, title TEXT NOT NULL, qty REAL NOT NULL DEFAULT 0,
    unit_price INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0)''',
  'CREATE INDEX idx_order_items_seq ON order_items(seq)',
  'CREATE INDEX idx_order_items_order ON order_items(order_id)',
];

/// Users and their roles (never synced, never exported: they hold the password
/// hashes). Only the server-side code reads them, through [UserStore].
const _v10Tables = [
  '''CREATE TABLE roles (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, perms TEXT NOT NULL DEFAULT '[]', builtin INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE users (
    id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, full_name TEXT NOT NULL DEFAULT '', role_id TEXT NOT NULL,
    salt TEXT NOT NULL, hash TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL DEFAULT '')''',
];

/// Delivery date of an order (تاریخ تحویل); an order can also be a draft.
const _v17Tables = [
  "ALTER TABLE orders ADD COLUMN delivery_date TEXT NOT NULL DEFAULT ''",
];

/// Standing monthly expenses (هزینهٔ ثابت: اجاره، اینترنت...) that are
/// registered with one tap each month.
const _v16Tables = [
  '''CREATE TABLE recurring_expenses (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    title TEXT NOT NULL, category_id TEXT, amount INTEGER NOT NULL DEFAULT 0, account_id TEXT,
    day INTEGER NOT NULL DEFAULT 1, active INTEGER NOT NULL DEFAULT 1, last_month INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT '')''',
  'CREATE INDEX idx_recurring_expenses_seq ON recurring_expenses(seq)',
];

/// Payroll (حقوق و دستمزد): people on the payroll, their time clock entries,
/// monthly payslips with their additions/deductions, and the links from
/// payments (and advances) to them.
const _v15Tables = [
  '''CREATE TABLE employees (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    name TEXT NOT NULL, phone TEXT NOT NULL DEFAULT '', pay_type TEXT NOT NULL DEFAULT 'monthly',
    base_amount INTEGER NOT NULL DEFAULT 0, attendance_based INTEGER NOT NULL DEFAULT 0,
    daily_hours REAL NOT NULL DEFAULT 8, overtime_rate REAL NOT NULL DEFAULT 0, insurance_percent REAL NOT NULL DEFAULT 0,
    formula TEXT NOT NULL DEFAULT '', contract_months INTEGER NOT NULL DEFAULT 0, off_days TEXT NOT NULL DEFAULT '5',
    start_date TEXT NOT NULL DEFAULT '', active INTEGER NOT NULL DEFAULT 1, note TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE attendance (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    employee_id TEXT NOT NULL, date TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'work',
    in_time TEXT NOT NULL DEFAULT '', out_time TEXT NOT NULL DEFAULT '', minutes INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE payslips (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    employee_id TEXT NOT NULL, year INTEGER NOT NULL, month INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'draft',
    pay_type TEXT NOT NULL DEFAULT 'monthly', worked_min INTEGER NOT NULL DEFAULT 0, leave_min INTEGER NOT NULL DEFAULT 0,
    overtime_min INTEGER NOT NULL DEFAULT 0, required_min INTEGER NOT NULL DEFAULT 0,
    base_pay INTEGER NOT NULL DEFAULT 0, overtime_pay INTEGER NOT NULL DEFAULT 0, additions INTEGER NOT NULL DEFAULT 0,
    deductions INTEGER NOT NULL DEFAULT 0, insurance INTEGER NOT NULL DEFAULT 0, net INTEGER NOT NULL DEFAULT 0,
    manual_base INTEGER, note TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE payroll_items (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    payslip_id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, amount INTEGER NOT NULL DEFAULT 0, tx_id TEXT)''',
  'CREATE INDEX idx_attendance_emp_date ON attendance(employee_id, date)',
  'CREATE INDEX idx_payslips_emp ON payslips(employee_id, year, month)',
  'CREATE INDEX idx_payroll_items_slip ON payroll_items(payslip_id)',
  'CREATE INDEX idx_employees_seq ON employees(seq)',
  'CREATE INDEX idx_attendance_seq ON attendance(seq)',
  'CREATE INDEX idx_payslips_seq ON payslips(seq)',
  'CREATE INDEX idx_payroll_items_seq ON payroll_items(seq)',
  'ALTER TABLE transactions ADD COLUMN payslip_id TEXT',
  'ALTER TABLE transactions ADD COLUMN employee_id TEXT',
];

/// Payment due date of an invoice (سررسید) and indexes that keep lists and
/// reports fast with many documents.
const _v14Tables = [
  'ALTER TABLE invoices ADD COLUMN due_date TEXT',
  'CREATE INDEX IF NOT EXISTS idx_invoices_party_date ON invoices(party_id, date)',
  'CREATE INDEX IF NOT EXISTS idx_invoices_date ON invoices(date)',
  'CREATE INDEX IF NOT EXISTS idx_tx_account ON transactions(account_id)',
  'CREATE INDEX IF NOT EXISTS idx_tx_invoice ON transactions(invoice_id)',
  'CREATE INDEX IF NOT EXISTS idx_cheques_status_due ON cheques(status, due_date)',
];

/// Dollar prices (قیمت ارزی): a product can carry its price in dollars; the
/// price in the current currency follows the dollar rate (setting `usd_rate`).
const _v13Tables = [
  'ALTER TABLE products ADD COLUMN usd_sale REAL NOT NULL DEFAULT 0',
  'ALTER TABLE products ADD COLUMN usd_buy REAL NOT NULL DEFAULT 0',
];

/// Warehouses (چند انبار): every invoice is for one warehouse (none = the main
/// one), and goods move between warehouses or are corrected by a count.
const _v12Tables = [
  '''CREATE TABLE warehouses (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL, name TEXT NOT NULL, note TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE stock_moves (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    date TEXT NOT NULL, kind TEXT NOT NULL, product_id TEXT NOT NULL, warehouse_id TEXT NOT NULL,
    to_warehouse_id TEXT, qty REAL NOT NULL, note TEXT NOT NULL DEFAULT '')''',
  'CREATE INDEX idx_stock_moves_product ON stock_moves(product_id)',
  'CREATE INDEX idx_warehouses_seq ON warehouses(seq)',
  'CREATE INDEX idx_stock_moves_seq ON stock_moves(seq)',
  'ALTER TABLE invoices ADD COLUMN warehouse_id TEXT',
  // The main warehouse exists on every device with the same id.
  "INSERT INTO warehouses (id, updated_at, deleted, device_id, seq, name) VALUES ('wh-main', 1, 0, 'init', 0, 'انبار اصلی')",
];

/// Who did what (گزارش فعالیت کاربران). Local to the system that holds the
/// data: not synced and not part of the JSON backups.
const _v11Tables = [
  '''CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, user_id TEXT NOT NULL DEFAULT '',
    user_name TEXT NOT NULL DEFAULT '', device TEXT NOT NULL DEFAULT '', action TEXT NOT NULL,
    tbl TEXT NOT NULL DEFAULT '', row_id TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '')''',
  'CREATE INDEX idx_audit_at ON audit_log(at)',
];

/// Product groups (گروه کالایی): every product can belong to one group.
const _v9Tables = [
  '''CREATE TABLE product_groups (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL, name TEXT NOT NULL)''',
  'CREATE INDEX idx_product_groups_seq ON product_groups(seq)',
];

/// Upgrade 8 -> 9: product groups and the group of a product.
const _migrate8to9 = [
  'ALTER TABLE products ADD COLUMN group_id TEXT',
  ..._v9Tables,
];

/// Upgrade 7 -> 8: a received cheque can be (part of) an order's advance.
const _migrate7to8 = [
  'ALTER TABLE cheques ADD COLUMN order_id TEXT',
];

/// Upgrade 5 -> 6: orders and the advance applied to each invoice.
const _migrate5to6 = [
  'ALTER TABLE invoices ADD COLUMN order_id TEXT',
  'ALTER TABLE invoices ADD COLUMN prepaid INTEGER NOT NULL DEFAULT 0',
  ..._v6Tables,
];

/// Upgrade 3 -> 4: opening balance of a party, transfers between accounts,
/// the link from a pro-forma to the invoice made from it.
const _migrate3to4 = [
  'ALTER TABLE parties ADD COLUMN opening INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE transactions ADD COLUMN to_account_id TEXT',
  'ALTER TABLE invoices ADD COLUMN ref_id TEXT',
];

/// Upgrade 2 -> 3: cost sheets and saved price formulas.
const _migrate2to3 = [
  ..._v3Tables,
  'CREATE INDEX idx_costings_seq ON costings(seq)',
  'CREATE INDEX idx_formulas_seq ON formulas(seq)',
];

/// Upgrade 1 -> 2: products, cheques, settings, VAT and product link.
const _migrate1to2 = [
  "ALTER TABLE invoices ADD COLUMN tax_percent INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE invoice_items ADD COLUMN product_id TEXT",
  ..._v2Tables,
  'CREATE INDEX idx_products_seq ON products(seq)',
  'CREATE INDEX idx_cheques_seq ON cheques(seq)',
  'CREATE INDEX idx_settings_seq ON settings(seq)',
];

/// Upgrade 4 -> 5: delivery receipts.
const _migrate4to5 = _v5Tables;

final _schema = [
  '''CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)''',
  '''CREATE TABLE accounts (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    name TEXT NOT NULL, kind TEXT NOT NULL, opening INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE parties (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    name TEXT NOT NULL, phone TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
    opening INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE categories (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    name TEXT NOT NULL, kind TEXT NOT NULL)''',
  '''CREATE TABLE invoices (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    number INTEGER NOT NULL, kind TEXT NOT NULL, date TEXT NOT NULL, party_id TEXT NOT NULL,
    discount INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '',
    tax_percent INTEGER NOT NULL DEFAULT 0, ref_id TEXT,
    order_id TEXT, prepaid INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE invoice_items (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    invoice_id TEXT NOT NULL, title TEXT NOT NULL, qty REAL NOT NULL,
    unit_price INTEGER NOT NULL, position INTEGER NOT NULL DEFAULT 0, product_id TEXT)''',
  ..._v2Tables,
  ..._migrate7to8,
  ..._migrate8to9,
  ..._v10Tables,
  ..._v11Tables,
  ..._v12Tables,
  ..._v13Tables,
  ..._v3Tables,
  ..._v5Tables,
  ..._v6Tables,
  ..._v7Tables,
  '''CREATE TABLE transactions (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    date TEXT NOT NULL, kind TEXT NOT NULL, amount INTEGER NOT NULL, account_id TEXT NOT NULL,
    party_id TEXT, category_id TEXT, invoice_id TEXT, description TEXT NOT NULL DEFAULT '',
    to_account_id TEXT)''',
  'CREATE INDEX idx_tx_date ON transactions(date)',
  'CREATE INDEX idx_tx_party ON transactions(party_id)',
  'CREATE INDEX idx_items_inv ON invoice_items(invoice_id)',
  for (final t in syncTables)
    if (!const {'deliveries', 'delivery_items', 'orders', 'order_items', 'product_groups', 'warehouses', 'stock_moves', 'employees', 'attendance', 'payslips', 'payroll_items', 'recurring_expenses'}.contains(t)) 'CREATE INDEX idx_${t}_seq ON $t(seq)',
  ..._v14Tables, // after the tables its indexes belong to
  ..._v15Tables,
  ..._v16Tables,
  ..._v17Tables,
];

/// Orders made before orders could hold several products have one product in
/// the order row itself; give each one a single item. The item id is derived
/// from the order id, so two devices that both upgrade create the same row
/// instead of duplicates when they sync.
Future<void> _orderItemsFromOrders(Database db) async {
  var seq = int.parse((await db.query('meta', where: "key='seq'")).first['value'] as String);
  for (final o in await db.query('orders')) {
    seq++;
    await db.insert('order_items', {
      'id': '${o['id']}:0',
      'updated_at': o['updated_at'],
      'deleted': o['deleted'],
      'device_id': o['device_id'],
      'seq': seq,
      'order_id': o['id'],
      'product_id': o['product_id'],
      'title': o['title'],
      'qty': o['qty'],
      'unit_price': o['unit_price'],
      'position': 0,
    });
  }
  await db.update('meta', {'value': '$seq'}, where: "key='seq'");
}

/// Thin wrapper around the SQLite database that stamps every write with the
/// metadata needed for sync (updated_at, device_id and a local change counter).
class AppDb {
  AppDb._(this._raw, this.deviceId, {bool guard = false}) {
    // A local database always goes through the guard (period lock, activity
    // log); a remote one is guarded by the server it talks to.
    if (guard) _guarded = GuardedDatabase(_raw, const Access.unrestricted(), () => lockUntil);
    _guardLocal = guard;
  }

  late final bool _guardLocal;

  /// The closed-until date (setting `lock_until`); the Repo keeps it current.
  String? lockUntil;
  final Database _raw;
  Database? _guarded;
  final String deviceId;

  /// What the app's screens and [Repo] use. While a user with a limited role is
  /// signed in on this device it refuses writes that role may not make.
  Database get db => _guarded ?? _raw;

  /// The unrestricted database: sync, backups, the server and [UserStore]
  /// (which hold their own checks) use this one.
  Database get raw => _raw;

  /// Limits (or, with null, frees) what the screens may change on this device.
  void setAccess(Access? access) {
    _guarded = access == null || access.unrestricted
        ? (_guardLocal ? GuardedDatabase(_raw, access ?? const Access.unrestricted(), () => lockUntil) : null)
        : GuardedDatabase(_raw, access, () => lockUntil);
  }

  /// Wraps an already open database, such as the network one of a client.
  static Future<AppDb> wrap(Database db) async {
    final rows = await db.query('meta', where: "key='device_id'");
    return AppDb._(db, rows.first['value'] as String);
  }

  static const _uuid = Uuid();
  static String newId() => _uuid.v4();

  /// Opens the on-disk database (or an in-memory one when [path] is given as
  /// [inMemoryDatabasePath], used by the tests).
  static Future<AppDb> open({String? path, DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ??
        p.join((await getApplicationDocumentsDirectory()).path, 'accounting.db');
    if (path == null) await Directory(p.dirname(dbPath)).create(recursive: true);
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onUpgrade: (db, from, _) async {
          if (from < 2) {
            for (final q in _migrate1to2) {
              await db.execute(q);
            }
          }
          if (from < 3) {
            for (final q in _migrate2to3) {
              await db.execute(q);
            }
          }
          if (from < 4) {
            for (final q in _migrate3to4) {
              await db.execute(q);
            }
          }
          if (from < 5) {
            for (final q in _migrate4to5) {
              await db.execute(q);
            }
          }
          if (from < 6) {
            for (final q in _migrate5to6) {
              await db.execute(q);
            }
          }
          if (from < 7) {
            for (final q in _v7Tables) {
              await db.execute(q);
            }
            await _orderItemsFromOrders(db);
          }
          if (from < 8) {
            for (final q in _migrate7to8) {
              await db.execute(q);
            }
          }
          if (from < 9) {
            for (final q in _migrate8to9) {
              await db.execute(q);
            }
          }
          if (from < 10) {
            for (final q in _v10Tables) {
              await db.execute(q);
            }
          }
          if (from < 11) {
            for (final q in _v11Tables) {
              await db.execute(q);
            }
          }
          if (from < 12) {
            for (final q in _v12Tables) {
              await db.execute(q);
            }
          }
          if (from < 13) {
            for (final q in _v13Tables) {
              await db.execute(q);
            }
          }
          if (from < 14) {
            for (final q in _v14Tables) {
              try {
                await db.execute(q);
              } catch (_) {
                // An index is only a speed-up; never let it stop an upgrade.
                if (!q.startsWith('CREATE INDEX')) rethrow;
              }
            }
          }
          if (from < 15) {
            for (final q in _v15Tables) {
              await db.execute(q);
            }
          }
          if (from < 16) {
            for (final q in _v16Tables) {
              await db.execute(q);
            }
          }
          if (from < 17) {
            for (final q in _v17Tables) {
              await db.execute(q);
            }
          }
        },
        onCreate: (db, _) async {
          for (final s in _schema) {
            await db.execute(s);
          }
          await db.insert('meta', {'key': 'device_id', 'value': newId()});
          await db.insert('meta', {'key': 'seq', 'value': '0'});
        },
      ),
    );
    final rows = await db.query('meta', where: "key='device_id'");
    return AppDb._(db, rows.first['value'] as String, guard: true);
  }

  Future<void> close() => _raw.close();

  Future<String?> getMeta(String key) async {
    final r = await _raw.query('meta', where: 'key=?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) => _raw.insert(
      'meta', {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<int> currentSeq() async => int.parse(await getMeta('seq') ?? '0');

  Future<int> _nextSeq(DatabaseExecutor tx) async {
    final r = await tx.query('meta', where: "key='seq'");
    final n = int.parse(r.first['value'] as String) + 1;
    await tx.update('meta', {'value': '$n'}, where: "key='seq'");
    return n;
  }

  /// Inserts or updates a record created locally.
  Future<void> save(String table, Map<String, Object?> values,
      {DatabaseExecutor? exec}) async {
    Future<void> run(DatabaseExecutor tx) async {
      final row = {
        ...values,
        'id': values['id'] ?? newId(),
        'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        'deleted': values['deleted'] ?? 0,
        'device_id': deviceId,
        'seq': await _nextSeq(tx),
      };
      await tx.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (exec != null) {
      await run(exec);
    } else {
      await db.transaction((tx) => run(tx));
    }
  }

  /// Soft delete: the row stays so the deletion can be synced to the peer.
  Future<void> softDelete(String table, String id, {DatabaseExecutor? exec}) async {
    Future<void> run(DatabaseExecutor tx) async {
      await tx.update(
          table,
          {
            'deleted': 1,
            'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
            'device_id': deviceId,
            'seq': await _nextSeq(tx),
          },
          where: 'id=?',
          whereArgs: [id]);
    }

    if (exec != null) {
      await run(exec);
    } else {
      await db.transaction((tx) => run(tx));
    }
  }

  /// Rows changed locally after [seq], ready to be sent to a peer.
  Future<Map<String, List<Map<String, Object?>>>> changesSince(int seq) async {
    final out = <String, List<Map<String, Object?>>>{};
    for (final t in syncTables) {
      final rows = await _raw.query(t, where: 'seq>?', whereArgs: [seq]);
      out[t] = [
        for (final r in rows) {...r}..remove('seq'),
      ];
    }
    return out;
  }

  /// Applies rows received from a peer using last-write-wins. Returns the
  /// number of rows that actually changed the local database.
  Future<int> applyRemote(Map<String, dynamic> data,
      {Set<String>? arrived, bool Function(String table, Map<String, Object?> row)? accept, void Function(String table, Map<String, Object?> row)? onReject}) async {
    var applied = 0;
    await _raw.transaction((tx) async {
      for (final t in syncTables) {
        final list = (data[t] as List?) ?? const [];
        for (final raw in list) {
          final row = Map<String, Object?>.from(raw as Map)..remove('seq');
          if (accept != null && !accept(t, row)) {
            onReject?.call(t, row);
            continue;
          }
          final cur = await tx.query(t,
              columns: ['updated_at', 'device_id', if (t == 'attendance') 'out_time', if (t == 'attendance') 'deleted'],
              where: 'id=?',
              whereArgs: [row['id']]);
          if (cur.isNotEmpty) {
            final cu = cur.first['updated_at'] as int;
            final cd = cur.first['device_id'] as String;
            final ru = row['updated_at'] as int;
            final rd = row['device_id'] as String;
            var remoteWins = ru > cu || (ru == cu && rd.compareTo(cd) > 0);
            // A time-clock entry that has been closed (clock-out) never goes back to
            // "still at work" because of a device whose clock is behind: the closed
            // version wins over the open one, whatever the timestamps say.
            if (t == 'attendance' && cur.first['deleted'] == 0 && (row['deleted'] ?? 0) == 0) {
              final localClosed = '${cur.first['out_time']}'.isNotEmpty, remoteClosed = '${row['out_time'] ?? ''}'.isNotEmpty;
              if (localClosed && !remoteClosed) remoteWins = false;
              if (!localClosed && remoteClosed) remoteWins = true;
            }
            if (!remoteWins) continue;
          }
          row['seq'] = await _nextSeq(tx);
          await tx.insert(t, row, conflictAlgorithm: ConflictAlgorithm.replace);
          applied++;
          arrived?.add(row['id'] as String);
        }
      }
    });
    return applied;
  }

  /// Gives a new number to documents that ended up with the same number on
  /// two devices (each numbered offline). Run on the device that coordinates
  /// the exchange: among the rows sharing a number, the ones already here keep
  /// it (then the earliest by date), and the rest (those in [arrived] first)
  /// get the next free numbers of their series. The renumbered rows are normal
  /// updates, so they travel back to the other device. Returns their count.
  Future<int> renumberDuplicates(Set<String> arrived) async {
    var changed = 0;
    await _raw.transaction((tx) async {
      for (final t in const ['invoices', 'orders', 'deliveries']) {
        final rows = await tx.query(t,
            columns: [if (t == 'invoices') 'kind', 'id', 'number', 'date', 'updated_at'], where: 'deleted=0');
        String series(Map<String, Object?> r) => t == 'invoices' && r['kind'] == 'proforma' ? 'p' : 's';
        final groups = <String, List<Map<String, Object?>>>{};
        final maxNo = <String, int>{};
        for (final r in rows) {
          final n = r['number'] as int;
          groups.putIfAbsent('${series(r)}:$n', () => []).add(r);
          if (n > (maxNo[series(r)] ?? 0)) maxNo[series(r)] = n;
        }
        for (final g in groups.values) {
          if (g.length < 2) continue;
          g.sort((a, b) {
            final aa = arrived.contains(a['id']) ? 1 : 0, bb = arrived.contains(b['id']) ? 1 : 0;
            if (aa != bb) return aa - bb;
            final d = (a['date'] as String).compareTo(b['date'] as String);
            if (d != 0) return d;
            final u = (a['updated_at'] as int).compareTo(b['updated_at'] as int);
            return u != 0 ? u : (a['id'] as String).compareTo(b['id'] as String);
          });
          for (final r in g.skip(1)) {
            final k = series(r);
            final next = (maxNo[k] ?? 0) + 1;
            maxNo[k] = next;
            await tx.update(
                t,
                {
                  'number': next,
                  'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
                  'device_id': deviceId,
                  'seq': await _nextSeq(tx),
                },
                where: 'id=?',
                whereArgs: [r['id']]);
            changed++;
          }
        }
      }
    });
    return changed;
  }
}

/// Picks the right SQLite implementation for the platform.
void initDatabaseFactory() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
