import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../data/db.dart';
import '../data/repo.dart';

const defaultSyncPort = 8765;
const _codeHeader = 'x-pair-code';

class SyncResult {
  SyncResult(this.sent, this.received);
  final int sent, received;
}

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Runs a small HTTP server so the other device can reach us, and can itself
/// connect to the other device's server. Both directions use the same
/// `POST /sync` exchange, so it does not matter which side starts it.
///
/// Protocol: the caller sends the rows it changed since the last sync and the
/// highest sequence number it has already seen from us. We reply with our own
/// rows after that number. Conflicts are resolved per row, last write wins.
class SyncService {
  SyncService(this.repo);

  final Repo repo;
  AppDb get _db => repo.store;

  HttpServer? _server;
  // Separate locks: if both devices sync to each other at the same moment the
  // incoming request must not wait for our own outgoing one (deadlock).
  Future<void> _serverLock = Future.value();
  Future<void> _clientLock = Future.value();

  bool get serverRunning => _server != null;
  int? get port => _server?.port;

  // ---- settings -----------------------------------------------------------

  Future<String> pairCode() async {
    var c = await _db.getMeta('pair_code');
    if (c == null) {
      c = (100000 + Random.secure().nextInt(900000)).toString();
      await _db.setMeta('pair_code', c);
    }
    return c;
  }

  Future<void> setPairCode(String code) => _db.setMeta('pair_code', code.trim());

  // ---- server -------------------------------------------------------------

  Future<void> startServer({int port = defaultSyncPort}) async {
    if (_server != null) return;
    _server = await shelf_io.serve(_handle, InternetAddress.anyIPv4, port);
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<Response> _handle(Request req) async {
    try {
      if (req.method == 'GET' && req.url.path == 'ping') {
        return _json({'app': 'simple_accounting', 'deviceId': _db.deviceId});
      }
      if (req.method == 'POST' && req.url.path == 'sync') {
        if (req.headers[_codeHeader] != await pairCode()) {
          return _json({'error': 'کد اتصال اشتباه است.'}, 401);
        }
        final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
        final reply = await _exclusive(true, () async {
          final since = (body['since'] as num?)?.toInt() ?? 0;
          // Collect our rows first so the rows we are about to receive are not
          // echoed straight back.
          final before = await _db.currentSeq();
          final out = await _db.changesSince(since);
          final applied = await _db.applyRemote(body['changes'] as Map<String, dynamic>? ?? {});
          return {
            'deviceId': _db.deviceId,
            'seq': await _seqAfterApply(before, applied),
            'changes': out,
            'applied': applied,
          };
        });
        repo.changed();
        return _json(reply);
      }
      return Response.notFound('not found');
    } catch (e) {
      return _json({'error': '$e'}, 500);
    }
  }

  Response _json(Object o, [int status = 200]) => Response(status,
      body: jsonEncode(o), headers: {'content-type': 'application/json; charset=utf-8'});

  // ---- client -------------------------------------------------------------

  /// Exchanges changes with the device at [host]:[port].
  Future<SyncResult> syncWith(String host, {int port = defaultSyncPort}) {
    return _exclusive(false, () async {
      final key = '$host:$port';
      final lastSent = int.parse(await _db.getMeta('sent_$key') ?? '0');
      final peerSeen = int.parse(await _db.getMeta('seen_$key') ?? '0');
      final snapshot = await _db.currentSeq();
      final changes = await _db.changesSince(lastSent);
      final sent = changes.values.fold<int>(0, (a, b) => a + b.length);

      http.Response res;
      try {
        res = await http
            .post(Uri.parse('http://$host:$port/sync'),
                headers: {'content-type': 'application/json', _codeHeader: await pairCode()},
                body: jsonEncode({'deviceId': _db.deviceId, 'since': peerSeen, 'changes': changes}))
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        throw SyncException('پاسخی از دستگاه مقابل دریافت نشد.');
      } on SocketException {
        throw SyncException('اتصال به $key برقرار نشد. آدرس و شبکه را بررسی کنید.');
      } on http.ClientException {
        throw SyncException('اتصال به $key برقرار نشد. آدرس و شبکه را بررسی کنید.');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        throw SyncException(data['error']?.toString() ?? 'خطای همگام‌سازی (${res.statusCode})');
      }
      final received = await _db.applyRemote(data['changes'] as Map<String, dynamic>);
      await _db.setMeta('sent_$key', '${await _seqAfterApply(snapshot, received)}');
      await _db.setMeta('seen_$key', '${data['seq']}');
      await _db.setMeta('last_sync', DateTime.now().toIso8601String());
      repo.changed();
      return SyncResult(sent, received);
    });
  }

  /// Sequence number to remember after applying [applied] remote rows on top of
  /// [before]. Skips over the rows that just arrived (so they are not echoed
  /// back), unless a local write sneaked in meanwhile; then it stays at
  /// [before] and the harmless echo is dropped by last-write-wins instead.
  Future<int> _seqAfterApply(int before, int applied) async {
    final now = await _db.currentSeq();
    return now - before == applied ? now : before;
  }

  /// Serialises sync operations so two exchanges never interleave.
  Future<T> _exclusive<T>(bool server, Future<T> Function() job) {
    final done = Completer<T>();
    final prev = server ? _serverLock : _clientLock;
    final next = done.future.then((_) {}, onError: (_) {});
    if (server) {
      _serverLock = next;
    } else {
      _clientLock = next;
    }
    prev.then((_) async {
      try {
        done.complete(await job());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  static Future<List<String>> localAddresses() async {
    final out = <String>[];
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (!a.isLoopback) out.add(a.address);
      }
    }
    return out;
  }
}
