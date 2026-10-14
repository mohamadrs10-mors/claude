import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'access.dart';

/// One database call written down as data, so it can be checked against the
/// user's [Access], sent over the network and run on the other side.
class Op {
  Op(this.kind, {this.table, this.sql, this.args, this.values, this.where, this.columns, this.groupBy, this.having, this.orderBy, this.limit, this.offset, this.distinct, this.conflict});

  /// query, rawQuery, insert, update, delete, rawInsert, rawUpdate, rawDelete or execute.
  final String kind;
  final String? table, sql, where, groupBy, having, orderBy, conflict;
  final List<Object?>? args;
  final Map<String, Object?>? values;
  final List<String>? columns;
  final int? limit, offset;
  final bool? distinct;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'table': ?table,
        'sql': ?sql,
        'args': ?args,
        'values': ?values,
        'where': ?where,
        'columns': ?columns,
        'groupBy': ?groupBy,
        'having': ?having,
        'orderBy': ?orderBy,
        'limit': ?limit,
        'offset': ?offset,
        'distinct': ?distinct,
        'conflict': ?conflict,
      };

  factory Op.fromJson(Map<String, dynamic> j) => Op(
        j['kind'] as String,
        table: j['table'] as String?,
        sql: j['sql'] as String?,
        args: (j['args'] as List?)?.cast<Object?>(),
        values: (j['values'] as Map?)?.cast<String, Object?>(),
        where: j['where'] as String?,
        columns: (j['columns'] as List?)?.cast<String>(),
        groupBy: j['groupBy'] as String?,
        having: j['having'] as String?,
        orderBy: j['orderBy'] as String?,
        limit: (j['limit'] as num?)?.toInt(),
        offset: (j['offset'] as num?)?.toInt(),
        distinct: j['distinct'] as bool?,
        conflict: j['conflict'] as String?,
      );

  static const _writes = {'insert', 'update', 'delete', 'rawInsert', 'rawUpdate', 'rawDelete', 'execute'};
  bool get isWrite => _writes.contains(kind);
}

final _writeSql = RegExp(r'^\s*(?:INSERT(?:\s+OR\s+\w+)?\s+INTO|REPLACE\s+INTO|UPDATE(?:\s+OR\s+\w+)?|DELETE\s+FROM)\s+[`"\[]?(\w+)', caseSensitive: false);
final _protectedWord = RegExp(r'\b(users|roles|sqlite_master|sqlite_schema|sqlite_temp_master)\b|\bpragma\b|\battach\b', caseSensitive: false);

/// Throws [AccessDenied] unless [access] allows [op]. Reads are open (the
/// screens hide what a role should not see) except for the account tables;
/// writes need the right to change the table, and schema changes are never
/// allowed through here.
void checkOp(Access access, Op op) {
  final text = [op.table, op.sql, op.where, op.groupBy, op.having, op.orderBy, ...?op.columns].whereType<String>().join(' ');
  if (_protectedWord.hasMatch(text)) throw AccessDenied('این بخش از اطلاعات در دسترس نیست.');
  if (!op.isWrite || access.unrestricted) return;
  String? table;
  switch (op.kind) {
    case 'insert':
    case 'update':
    case 'delete':
      table = op.table;
    default:
      table = _writeSql.firstMatch(op.sql ?? '')?.group(1);
  }
  if (table == null) throw AccessDenied('این دستور پایگاه‌داده مجاز نیست.');
  if (!access.canWriteTable(table)) throw AccessDenied();
}

ConflictAlgorithm? _conflict(String? name) => name == null ? null : ConflictAlgorithm.values.firstWhere((c) => c.name == name, orElse: () => ConflictAlgorithm.abort);

/// Runs [op] on [ex] and returns its result (rows or a count).
Future<Object?> runOp(DatabaseExecutor ex, Op op) async {
  switch (op.kind) {
    case 'query':
      return ex.query(op.table!, distinct: op.distinct, columns: op.columns, where: op.where, whereArgs: op.args, groupBy: op.groupBy, having: op.having, orderBy: op.orderBy, limit: op.limit, offset: op.offset);
    case 'rawQuery':
      return ex.rawQuery(op.sql!, op.args);
    case 'insert':
      return ex.insert(op.table!, op.values!, conflictAlgorithm: _conflict(op.conflict));
    case 'update':
      return ex.update(op.table!, op.values!, where: op.where, whereArgs: op.args, conflictAlgorithm: _conflict(op.conflict));
    case 'delete':
      return ex.delete(op.table!, where: op.where, whereArgs: op.args);
    case 'rawInsert':
      return ex.rawInsert(op.sql!, op.args);
    case 'rawUpdate':
      return ex.rawUpdate(op.sql!, op.args);
    case 'rawDelete':
      return ex.rawDelete(op.sql!, op.args);
    case 'execute':
      await ex.execute(op.sql!, op.args);
      return null;
  }
  throw ArgumentError('unknown operation ${op.kind}');
}

/// A database whose every call goes through [perform] as an [Op]. The parts of
/// the sqflite interface the app does not use throw [UnsupportedError].
abstract class OpExecutor implements DatabaseExecutor {
  Future<Object?> perform(Op op);

  List<Map<String, Object?>> _rows(Object? r) => [for (final x in (r as List)) Map<String, Object?>.from(x as Map)];

  @override
  Future<List<Map<String, Object?>>> query(String table, {bool? distinct, List<String>? columns, String? where, List<Object?>? whereArgs, String? groupBy, String? having, String? orderBy, int? limit, int? offset}) async =>
      _rows(await perform(Op('query', table: table, distinct: distinct, columns: columns, where: where, args: whereArgs, groupBy: groupBy, having: having, orderBy: orderBy, limit: limit, offset: offset)));

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async => _rows(await perform(Op('rawQuery', sql: sql, args: arguments)));

  @override
  Future<int> insert(String table, Map<String, Object?> values, {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) async =>
      (await perform(Op('insert', table: table, values: values, conflict: conflictAlgorithm?.name)) as num).toInt();

  @override
  Future<int> update(String table, Map<String, Object?> values, {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) async =>
      (await perform(Op('update', table: table, values: values, where: where, args: whereArgs, conflict: conflictAlgorithm?.name)) as num).toInt();

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) async =>
      (await perform(Op('delete', table: table, where: where, args: whereArgs)) as num).toInt();

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async => (await perform(Op('rawInsert', sql: sql, args: arguments)) as num).toInt();

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async => (await perform(Op('rawUpdate', sql: sql, args: arguments)) as num).toInt();

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async => (await perform(Op('rawDelete', sql: sql, args: arguments)) as num).toInt();

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    await perform(Op('execute', sql: sql, args: arguments));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName} is not supported here');
}

class _OpTransaction extends OpExecutor implements Transaction {
  _OpTransaction(this._perform);
  final Future<Object?> Function(Op) _perform;
  @override
  Future<Object?> perform(Op op) => _perform(op);
}

/// A [Database] that forwards to a real one after checking each call against
/// [access]. Used on this device while a user with a limited role is signed in.
class GuardedDatabase extends OpExecutor implements Database {
  GuardedDatabase(this.real, this.access);
  final Database real;
  final Access access;

  @override
  Future<Object?> perform(Op op) {
    checkOp(access, op);
    return runOp(real, op);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) =>
      real.transaction((tx) => action(_OpTransaction((op) {
            checkOp(access, op);
            return runOp(tx, op);
          })));

  @override
  String get path => real.path;
  @override
  bool get isOpen => real.isOpen;
  @override
  Future<void> close() async {}
}

/// Builds the transaction object for a database that talks through [perform]
/// with a transaction id (the network client).
Transaction opTransaction(Future<Object?> Function(Op) perform) => _OpTransaction(perform);
