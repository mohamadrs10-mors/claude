import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../data/company_manager.dart';
import '../data/db.dart';
import '../data/repo.dart';
import '../data/sessions.dart';
import 'net_api.dart';

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
///
/// Several companies can live on one device, so every request names the
/// company it is about; the server looks it up by id.
class SyncService {
  SyncService(this.companies, {SessionManager? sessions}) : sessions = sessions ?? SessionManager() {
    api = NetApi(
      companies: companies,
      sessions: this.sessions,
      pairCode: pairCode,
      enabled: () => companies.prefs.get('net_mode') == 'server',
    );
  }

  final CompanyManager companies;

  /// Who is signed in on this server (network clients and the local user).
  final SessionManager sessions;

  /// The live network API for clients; only answers while this device is set up as a server.
  late final NetApi api;

  HttpServer? _server;
  // Separate locks: if both devices sync to each other at the same moment the
  // incoming request must not wait for our own outgoing one (deadlock).
  Future<void> _serverLock = Future.value();
  Future<void> _clientLock = Future.value();

  bool get serverRunning => _server != null;
  int? get port => _server?.port;

  // ---- settings -----------------------------------------------------------

  /// The pairing code of this device (the same for every company on it).
  Future<String> pairCode() async {
    var c = companies.prefs.get('pair_code');
    if (c == null || c.isEmpty) {
      c = (100000 + Random.secure().nextInt(900000)).toString();
      await companies.prefs.set('pair_code', c);
    }
    return c;
  }

  Future<void> setPairCode(String code) => companies.prefs.set('pair_code', code.trim());

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
      final net = await api.handle(req);
      if (net != null) return net;
      if (req.method == 'GET' && req.url.path == 'ping') {
        return _json({'app': 'simple_accounting'});
      }
      final isCompanies = req.method == 'GET' && req.url.path == 'companies';
      final isSync = req.method == 'POST' && req.url.path == 'sync';
      if (isCompanies || isSync) {
        if (req.headers[_codeHeader] != await pairCode()) {
          return _json({'error': 'کد اتصال اشتباه است.'}, 401);
        }
      }
      if (isCompanies) {
        return _json({'companies': [for (final c in companies.companies) {'id': c.id, 'name': c.name}]});
      }
      if (isSync) {
        final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
        final repo = await companies.repoFor((body['companyId'] ?? '') as String);
        if (repo == null) {
          return _json({'error': 'این شرکت روی دستگاه مقابل وجود ندارد.', 'code': 'no_company'}, 404);
        }
        final db = repo.store;
        final reply = await _exclusive(true, () async {
          final since = (body['since'] as num?)?.toInt() ?? 0;
          // Collect our rows first so the rows we are about to receive are not
          // echoed straight back.
          final before = await db.currentSeq();
          final out = await db.changesSince(since);
          final arrived = <String>{};
          final applied = await db.applyRemote(body['changes'] as Map<String, dynamic>? ?? {}, arrived: arrived);
          // This device coordinates the exchange: documents numbered twice
          // (offline on both sides) get new numbers here, and the renumbered
          // rows go back in the same reply.
          final afterApply = await db.currentSeq();
          final renumbered = await db.renumberDuplicates(arrived);
          if (renumbered > 0) {
            final extra = await db.changesSince(afterApply);
            for (final e in extra.entries) {
              final list = [...(out[e.key] ?? const <Map<String, Object?>>[])];
              for (final row in e.value) {
                list.removeWhere((o) => o['id'] == row['id']);
                list.add(row);
              }
              out[e.key] = list;
            }
          }
          return {
            'deviceId': db.deviceId,
            'seq': await _seqAfterApply(db, before, applied + renumbered),
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

  /// The companies the device at [host]:[port] offers: (id, name).
  Future<List<(String, String)>> fetchCompanies(String host, {int port = defaultSyncPort}) async {
    try {
      final res = await http
          .get(Uri.parse('http://$host:$port/companies'), headers: {_codeHeader: await pairCode()})
          .timeout(const Duration(seconds: 15));
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (res.statusCode != 200) throw SyncException(data['error']?.toString() ?? 'خطا (${res.statusCode})');
      return [for (final c in data['companies'] as List) ((c as Map)['id'] as String, c['name'] as String)];
    } on TimeoutException {
      throw SyncException('پاسخی از دستگاه مقابل دریافت نشد.');
    } on SocketException {
      throw SyncException('اتصال به $host:$port برقرار نشد. آدرس و شبکه را بررسی کنید.');
    } on http.ClientException {
      throw SyncException('اتصال به $host:$port برقرار نشد. آدرس و شبکه را بررسی کنید.');
    }
  }

  /// Exchanges the changes of [repo]'s company with the device at [host]:[port].
  Future<SyncResult> syncWith(Repo repo, String host, {int port = defaultSyncPort}) {
    final db = repo.store;
    return _exclusive(false, () async {
      final key = '$host:$port';
      final lastSent = int.parse(await db.getMeta('sent_$key') ?? '0');
      final peerSeen = int.parse(await db.getMeta('seen_$key') ?? '0');
      final snapshot = await db.currentSeq();
      final changes = await db.changesSince(lastSent);
      final sent = changes.values.fold<int>(0, (a, b) => a + b.length);

      http.Response res;
      try {
        res = await http
            .post(Uri.parse('http://$host:$port/sync'),
                headers: {'content-type': 'application/json', _codeHeader: await pairCode()},
                body: jsonEncode({'companyId': repo.companyId, 'deviceId': db.deviceId, 'since': peerSeen, 'changes': changes}))
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
      final received = await db.applyRemote(data['changes'] as Map<String, dynamic>);
      await db.setMeta('sent_$key', '${await _seqAfterApply(db, snapshot, received)}');
      await db.setMeta('seen_$key', '${data['seq']}');
      await db.setMeta('last_sync', DateTime.now().toIso8601String());
      repo.changed();
      return SyncResult(sent, received);
    });
  }

  /// Sequence number to remember after applying [applied] remote rows on top of
  /// [before]. Skips over the rows that just arrived (so they are not echoed
  /// back), unless a local write sneaked in meanwhile; then it stays at
  /// [before] and the harmless echo is dropped by last-write-wins instead.
  Future<int> _seqAfterApply(AppDb db, int before, int applied) async {
    final now = await db.currentSeq();
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
