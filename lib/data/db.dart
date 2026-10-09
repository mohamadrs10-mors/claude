import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

/// Tables that take part in synchronisation. Every one of them carries the
/// common columns: id, updated_at, deleted, device_id and the local-only seq.
const syncTables = [
  'accounts',
  'parties',
  'categories',
  'products',
  'cheques',
  'settings',
  'invoices',
  'invoice_items',
  'transactions',
];

const _schemaVersion = 2;

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

/// Upgrade 1 -> 2: products, cheques, settings, VAT and product link.
const _migrate1to2 = [
  "ALTER TABLE invoices ADD COLUMN tax_percent INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE invoice_items ADD COLUMN product_id TEXT",
  ..._v2Tables,
  'CREATE INDEX idx_products_seq ON products(seq)',
  'CREATE INDEX idx_cheques_seq ON cheques(seq)',
  'CREATE INDEX idx_settings_seq ON settings(seq)',
];

final _schema = [
  '''CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)''',
  '''CREATE TABLE accounts (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    name TEXT NOT NULL, kind TEXT NOT NULL, opening INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE parties (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    name TEXT NOT NULL, phone TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE categories (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    name TEXT NOT NULL, kind TEXT NOT NULL)''',
  '''CREATE TABLE invoices (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    number INTEGER NOT NULL, kind TEXT NOT NULL, date TEXT NOT NULL, party_id TEXT NOT NULL,
    discount INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '',
    tax_percent INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE invoice_items (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    invoice_id TEXT NOT NULL, title TEXT NOT NULL, qty REAL NOT NULL,
    unit_price INTEGER NOT NULL, position INTEGER NOT NULL DEFAULT 0, product_id TEXT)''',
  ..._v2Tables,
  '''CREATE TABLE transactions (
    id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL, seq INTEGER NOT NULL,
    date TEXT NOT NULL, kind TEXT NOT NULL, amount INTEGER NOT NULL, account_id TEXT NOT NULL,
    party_id TEXT, category_id TEXT, invoice_id TEXT, description TEXT NOT NULL DEFAULT '')''',
  'CREATE INDEX idx_tx_date ON transactions(date)',
  'CREATE INDEX idx_tx_party ON transactions(party_id)',
  'CREATE INDEX idx_items_inv ON invoice_items(invoice_id)',
  for (final t in syncTables) 'CREATE INDEX idx_${t}_seq ON $t(seq)',
];

/// Thin wrapper around the SQLite database that stamps every write with the
/// metadata needed for sync (updated_at, device_id and a local change counter).
class AppDb {
  AppDb._(this.db, this.deviceId);

  final Database db;
  final String deviceId;

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
    return AppDb._(db, rows.first['value'] as String);
  }

  Future<void> close() => db.close();

  Future<String?> getMeta(String key) async {
    final r = await db.query('meta', where: 'key=?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) => db.insert(
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
      final rows = await db.query(t, where: 'seq>?', whereArgs: [seq]);
      out[t] = [
        for (final r in rows) {...r}..remove('seq'),
      ];
    }
    return out;
  }

  /// Applies rows received from a peer using last-write-wins. Returns the
  /// number of rows that actually changed the local database.
  Future<int> applyRemote(Map<String, dynamic> data) async {
    var applied = 0;
    await db.transaction((tx) async {
      for (final t in syncTables) {
        final list = (data[t] as List?) ?? const [];
        for (final raw in list) {
          final row = Map<String, Object?>.from(raw as Map)..remove('seq');
          final cur = await tx.query(t,
              columns: ['updated_at', 'device_id'],
              where: 'id=?',
              whereArgs: [row['id']]);
          if (cur.isNotEmpty) {
            final cu = cur.first['updated_at'] as int;
            final cd = cur.first['device_id'] as String;
            final ru = row['updated_at'] as int;
            final rd = row['device_id'] as String;
            final remoteWins = ru > cu || (ru == cu && rd.compareTo(cd) > 0);
            if (!remoteWins) continue;
          }
          row['seq'] = await _nextSeq(tx);
          await tx.insert(t, row, conflictAlgorithm: ConflictAlgorithm.replace);
          applied++;
        }
      }
    });
    return applied;
  }
}

/// Picks the right SQLite implementation for the platform.
void initDatabaseFactory() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
