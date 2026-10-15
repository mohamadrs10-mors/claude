import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../util/format.dart';
import 'access.dart';
import 'db_ops.dart';

/// Documents dated on or before the "closed until" date can no longer be
/// created, changed or deleted (قفل دورهٔ مالی). The date is a synced setting.
const lockSettingKey = 'lock_until';

/// Tables whose rows have a date, and the child tables that follow their parent.
const _dated = {'invoices', 'transactions', 'deliveries', 'orders'};
const _children = {'invoice_items': ('invoices', 'invoice_id'), 'delivery_items': ('deliveries', 'delivery_id'), 'order_items': ('orders', 'order_id')};

/// What the activity log writes down: table -> title.
const auditTables = {
  'invoices': 'فاکتور',
  'transactions': 'تراکنش',
  'orders': 'سفارش',
  'deliveries': 'رسید تحویل',
  'cheques': 'چک',
  'parties': 'شخص',
  'products': 'کالا',
  'product_groups': 'گروه کالا',
  'accounts': 'حساب',
  'categories': 'دسته‌بندی',
  'costings': 'قیمت‌گذاری',
  'formulas': 'فرمول',
  'settings': 'تنظیمات',
  'warehouses': 'انبار',
  'stock_moves': 'حرکت انبار',
};

String _invoiceKind(String k) => switch (k) {
      'sale' => 'فروش',
      'purchase' => 'خرید',
      'sale_return' => 'برگشت از فروش',
      'purchase_return' => 'برگشت از خرید',
      'proforma' => 'پیش‌فاکتور',
      _ => k,
    };

Future<String?> lockDate(DatabaseExecutor ex) async {
  final r = await ex.query('settings', columns: ['value'], where: 'id=? AND deleted=0', whereArgs: [lockSettingKey]);
  final v = r.isEmpty ? '' : (r.first['value'] as String).trim();
  return v.isEmpty ? null : v;
}

AccessDenied _locked(String lock) => AccessDenied('دورهٔ مالی تا ${faDigits(jalaliText(lock))} بسته شده است؛ سندی با این تاریخ قابل ثبت، ویرایش یا حذف نیست.');

/// Throws unless the write [op] may touch documents of a closed period.
Future<void> checkLock(DatabaseExecutor ex, Op op, String? lock) async {
  if (lock == null || !op.isWrite) return;
  String? table = op.table;
  if (table == null) return;
  final child = _children[table];
  if (!_dated.contains(table) && child == null) return;
  bool closed(Object? d) => d is String && d.isNotEmpty && d.compareTo(lock) <= 0;

  // The date the document will have.
  if (op.kind == 'insert' || op.kind == 'update') {
    final v = op.values ?? const {};
    if (child == null && closed(v['date'])) throw _locked(lock);
    if (child != null && v[child.$2] != null) {
      final p = await ex.query(child.$1, columns: ['date'], where: 'id=?', whereArgs: [v[child.$2]]);
      if (p.isNotEmpty && closed(p.first['date'])) throw _locked(lock);
    }
  }
  // The date it has now (editing or deleting an existing document).
  final List<Map<String, Object?>> existing;
  if (op.kind == 'insert') {
    final id = op.values?['id'];
    if (id == null) return;
    existing = await ex.query(table, where: 'id=? AND deleted=0', whereArgs: [id]);
  } else {
    existing = await ex.query(table, where: op.where, whereArgs: op.args);
  }
  for (final row in existing) {
    if (row['deleted'] == 1 && op.kind != 'update') continue;
    if (child == null) {
      if (closed(row['date'])) throw _locked(lock);
    } else {
      final p = await ex.query(child.$1, columns: ['date'], where: 'id=?', whereArgs: [row[child.$2]]);
      if (p.isNotEmpty && closed(p.first['date'])) throw _locked(lock);
    }
  }
}

/// Short description of a row for the activity log.
Future<String> describeRow(DatabaseExecutor ex, String table, Map<String, Object?> r) async {
  String s(String k) => '${r[k] ?? ''}'.trim();
  switch (table) {
    case 'invoices':
      final party = await ex.query('parties', columns: ['name'], where: 'id=?', whereArgs: [r['party_id']]);
      final name = party.isEmpty ? '' : ' – ${party.first['name']}';
      return '${_invoiceKind(s('kind'))} ${faDigits(s('number'))}$name';
    case 'orders':
      return 'سفارش ${faDigits(s('number'))} – ${s('title')}';
    case 'deliveries':
      return 'رسید تحویل ${faDigits(s('number'))}';
    case 'transactions':
      return '${txKindLabel(s('kind'))} ${money(r['amount'] as num? ?? 0)} ${s('description')}'.trim();
    case 'cheques':
      return 'چک ${s('number')} ${money(r['amount'] as num? ?? 0)}'.trim();
    case 'settings':
      return s('id');
    case 'stock_moves':
      return s('kind') == 'transfer' ? 'انتقال بین انبارها' : 'تعدیل موجودی';
    default:
      final n = s('name').isNotEmpty ? s('name') : s('title');
      return n.isNotEmpty ? n : s('id');
  }
}

/// Appends an activity-log row.
Future<void> logEvent(DatabaseExecutor ex, Access who, String action, {String table = '', String rowId = '', String summary = ''}) async {
  if (who.who.isEmpty) return;
  await ex.insert('audit_log', {
    'at': DateTime.now().toUtc().millisecondsSinceEpoch,
    'user_id': who.userId,
    'user_name': who.who,
    'device': who.device,
    'action': action,
    'tbl': table,
    'row_id': rowId,
    'summary': summary,
  });
}

/// Runs [op] on [ex] for [access]: permission check, closed-period check, then
/// the call itself and, for people who are signed in, an activity-log row for
/// each document it changed. The log row belongs to the same transaction as
/// the change, so a rolled-back change leaves no trace.
Future<Object?> guardedRun(DatabaseExecutor ex, Access access, Op op, {String? lock}) {
  try {
    checkOp(access, op);
  } catch (e) {
    return Future.error(e);
  }
  final table = op.table;
  final log = op.isWrite && access.who.isNotEmpty && table != null && auditTables.containsKey(table) && (op.kind == 'insert' || op.kind == 'update' || op.kind == 'delete');
  // No closed period and nobody to log: straight to the database, no extra steps.
  if (!log && (lock == null || !op.isWrite)) return runOp(ex, op);
  return _guardedSlow(ex, access, op, lock, log);
}

Future<Object?> _guardedSlow(DatabaseExecutor ex, Access access, Op op, String? lock, bool log) async {
  await checkLock(ex, op, lock);
  final table = op.table;
  if (!log) return runOp(ex, op);
  table!;

  final ids = <String>[];
  final existed = <String>{};
  if (op.kind == 'insert') {
    final id = op.values?['id'];
    if (id is String) {
      ids.add(id);
      if ((await ex.query(table, columns: ['id'], where: 'id=?', whereArgs: [id])).isNotEmpty) existed.add(id);
    }
  } else {
    final rows = await ex.query(table, columns: ['id'], where: op.where, whereArgs: op.args, limit: 50);
    for (final r in rows) {
      ids.add(r['id'] as String);
      existed.add(r['id'] as String);
    }
  }
  final deletedBefore = <String>{};
  if (op.kind == 'insert') {
    for (final r in await ex.query(table, columns: ['id', 'deleted'], where: "id IN (${ids.map((_) => '?').join(',')})", whereArgs: ids)) {
      if (r['deleted'] == 1) deletedBefore.add(r['id'] as String);
    }
  }
  final result = await runOp(ex, op);
  for (final id in ids) {
    final rows = await ex.query(table, where: 'id=?', whereArgs: [id]);
    if (op.kind == 'delete') {
      await logEvent(ex, access, 'delete', table: table, rowId: id, summary: auditTables[table]!);
      continue;
    }
    if (rows.isEmpty) continue;
    final row = rows.first;
    final gone = row['deleted'] == 1;
    if (gone && deletedBefore.contains(id)) continue;
    final action = gone ? 'delete' : (existed.contains(id) && !deletedBefore.contains(id) ? 'edit' : 'create');
    final text = await describeRow(ex, table, row);
    await logEvent(ex, access, action, table: table, rowId: id, summary: '${auditTables[table]}: $text');
  }
  return result;
}

/// One line of the activity report.
class AuditEntry {
  AuditEntry({required this.id, required this.at, required this.userId, required this.userName, required this.device, required this.action, required this.table, required this.rowId, required this.summary});
  final int id;
  final DateTime at;
  final String userId, userName, device, action, table, rowId, summary;

  String get actionLabel => switch (action) {
        'create' => 'ثبت',
        'edit' => 'ویرایش',
        'delete' => 'حذف',
        'login' => 'ورود',
        'logout' => 'خروج',
        'kick' => 'قطع نشست',
        'sync' => 'همگام‌سازی',
        _ => action,
      };

  Map<String, Object?> toJson() => {'id': id, 'at': at.millisecondsSinceEpoch, 'userId': userId, 'userName': userName, 'device': device, 'action': action, 'table': table, 'rowId': rowId, 'summary': summary};
  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
      id: (j['id'] as num).toInt(), at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt(), isUtc: true).toLocal(), userId: j['userId'] as String,
      userName: j['userName'] as String, device: j['device'] as String, action: j['action'] as String, table: j['table'] as String,
      rowId: j['rowId'] as String, summary: j['summary'] as String);
}

/// Reads the activity log, newest first. [fromIso]/[toIso] are ISO dates (inclusive).
Future<List<AuditEntry>> readAudit(DatabaseExecutor ex, {String? userId, String? action, String? table, String? fromIso, String? toIso, String? text, int limit = 300, int offset = 0}) async {
  final where = <String>[];
  final args = <Object?>[];
  if (userId != null && userId.isNotEmpty) {
    where.add('user_id=?');
    args.add(userId);
  }
  if (action != null && action.isNotEmpty) {
    where.add('action=?');
    args.add(action);
  }
  if (table != null && table.isNotEmpty) {
    where.add('tbl=?');
    args.add(table);
  }
  int ms(String iso, {bool end = false}) {
    final d = DateTime.parse(iso);
    final local = DateTime(d.year, d.month, d.day).add(end ? const Duration(days: 1) : Duration.zero);
    return local.toUtc().millisecondsSinceEpoch;
  }

  if (fromIso != null && fromIso.isNotEmpty) {
    where.add('at>=?');
    args.add(ms(fromIso));
  }
  if (toIso != null && toIso.isNotEmpty) {
    where.add('at<?');
    args.add(ms(toIso, end: true));
  }
  if (text != null && text.trim().isNotEmpty) {
    where.add("(summary LIKE ? OR user_name LIKE ?)");
    args..add('%${text.trim()}%')..add('%${text.trim()}%');
  }
  final rows = await ex.query('audit_log', where: where.isEmpty ? null : where.join(' AND '), whereArgs: args, orderBy: 'id DESC', limit: limit, offset: offset);
  return [
    for (final r in rows)
      AuditEntry(
        id: r['id'] as int, at: DateTime.fromMillisecondsSinceEpoch(r['at'] as int, isUtc: true).toLocal(), userId: r['user_id'] as String,
        userName: r['user_name'] as String, device: r['device'] as String, action: r['action'] as String, table: r['tbl'] as String,
        rowId: r['row_id'] as String, summary: r['summary'] as String)
  ];
}
