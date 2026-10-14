import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'access.dart';
import 'db_ops.dart';

/// A problem talking to the server.
class NetException implements Exception {
  NetException(this.message, {this.code = 'error', this.status = 0, this.extra = const {}});
  final String message, code;
  final int status;
  final Map<String, dynamic> extra;
  bool get offline => code == 'offline';
  @override
  String toString() => message;
}

/// The server ended our session: we were signed out by an administrator, the
/// same user signed in elsewhere, or we were away for too long.
class SessionEnded extends NetException {
  SessionEnded(this.reason) : super(_text(reason), code: 'session_ended', status: 401);
  final String reason;
  static String _text(String r) => switch (r) {
        'kicked' => 'مدیر نشست شما را قطع کرد.',
        'expired' => 'ارتباط شما با سرور مدتی قطع بود و نشست پایان یافت.',
        'replaced' => 'این کاربر از سیستم دیگری وارد شد.',
        'removed' => 'حساب کاربری شما حذف یا غیرفعال شد.',
        'logout' => 'از برنامه خارج شدید.',
        _ => 'نشست شما پایان یافته است.',
      };
}

/// One connection to the server: address, access code and the session token.
class RemoteChannel {
  RemoteChannel({required this.host, required this.port, required this.code, this.token = '', http.Client? client}) : _client = client ?? http.Client();
  final String host;
  final int port;
  final String code;
  String token;
  final http.Client _client;

  Uri _uri(String path) => Uri.parse('http://$host:$port/$path');

  /// Sends [body] to [path] and returns the decoded answer. Server errors become
  /// exceptions: [AccessDenied], [SessionEnded] or [NetException].
  Future<Map<String, dynamic>> post(String path, Map<String, Object?> body, {bool auth = true, Duration timeout = const Duration(seconds: 30)}) async {
    http.Response res;
    try {
      res = await _client
          .post(_uri(path), headers: {'content-type': 'application/json', apiCodeHeaderName: code}, body: jsonEncode({...body, if (auth) 'token': token}))
          .timeout(timeout);
    } on TimeoutException {
      throw NetException('سرور پاسخ نداد.', code: 'offline');
    } on SocketException {
      throw NetException('اتصال به سرور ($host:$port) برقرار نشد. آدرس و شبکه را بررسی کنید.', code: 'offline');
    } on http.ClientException {
      throw NetException('اتصال به سرور ($host:$port) برقرار نشد. آدرس و شبکه را بررسی کنید.', code: 'offline');
    }
    Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw NetException('پاسخ نامعتبر از سرور (${res.statusCode}).', status: res.statusCode);
    }
    if (res.statusCode == 200) return data;
    final code_ = (data['code'] ?? 'error') as String;
    final msg = (data['error'] ?? 'خطا (${res.statusCode})') as String;
    if (code_ == 'access_denied') throw AccessDenied(msg);
    if (code_ == 'session_ended') throw SessionEnded((data['reason'] ?? 'unknown') as String);
    throw NetException(msg, code: code_, status: res.statusCode, extra: data);
  }

  /// Runs one database call, optionally inside transaction [tx].
  Future<Object?> run(Op op, {String? tx}) async => (await post('api/db', {'op': op.toJson(), 'tx': ?tx}))['result'];

  void close() => _client.close();
}

const apiCodeHeaderName = 'x-pair-code';

/// A [Database] that lives on the server. The app's data code runs unchanged on
/// it: every call is sent to the server, which checks it against our role.
class RemoteDatabase extends OpExecutor implements Database {
  RemoteDatabase(this.channel);
  final RemoteChannel channel;

  @override
  Future<Object?> perform(Op op) => channel.run(op);

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) async {
    final begun = await channel.post('api/tx', {'action': 'begin'}, timeout: const Duration(seconds: 70));
    final id = begun['tx'] as String;
    final tx = opTransaction((op) => channel.run(op, tx: id));
    T result;
    try {
      result = await action(tx);
    } catch (_) {
      try {
        await channel.post('api/tx', {'action': 'end', 'tx': id, 'commit': false});
      } catch (_) {
        // The server rolls back an abandoned transaction by itself.
      }
      rethrow;
    }
    await channel.post('api/tx', {'action': 'end', 'tx': id, 'commit': true});
    return result;
  }

  @override
  String get path => 'remote://${channel.host}:${channel.port}';
  @override
  bool get isOpen => true;
  @override
  Future<void> close() async {}
}
