import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/access.dart';
import '../data/device_prefs.dart';
import '../data/remote_db.dart';
import '../data/repo.dart';

/// What the mobile device may change on its own: the invoices it makes and the
/// customers they are for. Everything else it only looks at.
const mobileEditAreas = {'invoices', 'parties'};
const mobileTables = ['invoices', 'invoice_items', 'parties'];

/// One thing the server did not accept from this device.
class MobileRejection {
  MobileRejection(this.label, this.reason);
  final String label, reason;
}

class MobileSyncResult {
  MobileSyncResult({required this.sent, required this.received, required this.renumbered, required this.rejected});
  final int sent, received, renumbered;
  final List<MobileRejection> rejected;
}

/// Who this mobile device works as, as the server last told it.
class MobileProfile {
  MobileProfile({required this.userId, required this.username, required this.display, required this.roleName, required this.companyName, required this.perms});
  final String userId, username, display, roleName, companyName;
  final Set<String> perms;

  /// The permissions here: the user's role, but changes only to invoices and customers.
  Access get access => Access(perms, who: display.isEmpty ? username : display, userId: userId, device: 'موبایل').onlyEditing(mobileEditAreas);

  String toJson() => jsonEncode({'userId': userId, 'username': username, 'display': display, 'roleName': roleName, 'companyName': companyName, 'perms': perms.toList()});
  factory MobileProfile.fromJson(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return MobileProfile(
        userId: j['userId'] as String, username: j['username'] as String, display: j['display'] as String, roleName: j['roleName'] as String,
        companyName: j['companyName'] as String, perms: {for (final p in j['perms'] as List) '$p'});
  }
}

/// The offline mobile mode: a full copy of one company is kept on the device and
/// works without a network; when connected, [sync] sends the invoices made
/// meanwhile to the server and brings back the server's changes.
class MobileController extends ChangeNotifier {
  MobileController(this.prefs);
  final DevicePrefs prefs;

  /// Kept for this run only, so the password is asked once per start.
  String _password = '';

  bool get configured => (prefs.get('mobile_company') ?? '').isNotEmpty;
  String get host => prefs.get('mobile_host') ?? '';
  int get port => int.tryParse(prefs.get('mobile_port') ?? '') ?? 8765;
  String get code => prefs.get('mobile_code') ?? '';
  String get companyId => prefs.get('mobile_company') ?? '';
  String get username => prefs.get('mobile_user') ?? '';
  DateTime? get lastSync => DateTime.tryParse(prefs.get('mobile_last_sync') ?? '');
  bool get hasPassword => _password.isNotEmpty;
  MobileProfile? get profile {
    final s = prefs.get('mobile_profile');
    if (s == null || s.isEmpty) return null;
    try {
      return MobileProfile.fromJson(s);
    } catch (_) {
      return null;
    }
  }

  void setPassword(String p) => _password = p;

  Future<void> save({required String host, required int port, required String code, required String companyId, required String username}) async {
    await prefs.set('mobile_host', host);
    await prefs.set('mobile_port', '$port');
    await prefs.set('mobile_code', code);
    await prefs.set('mobile_company', companyId);
    await prefs.set('mobile_user', username);
    notifyListeners();
  }

  /// Forgets the server (the local copy of the data stays).
  Future<void> disconnect() async {
    for (final k in ['mobile_host', 'mobile_port', 'mobile_code', 'mobile_company', 'mobile_user', 'mobile_profile', 'mobile_last_sync']) {
      await prefs.set(k, '');
    }
    _password = '';
    notifyListeners();
  }

  /// How many invoices and customers wait to be sent.
  Future<int> pending(Repo repo) async {
    final sent = int.parse(await repo.store.getMeta('m_sent') ?? '0');
    var n = 0;
    for (final t in const ['invoices', 'parties']) {
      n += (await repo.store.raw.rawQuery('SELECT COUNT(*) AS n FROM $t WHERE seq>?', [sent])).first['n'] as int;
    }
    return n;
  }

  /// Exchanges data with the server. Throws [NetException] (offline, wrong
  /// password, ...) with a message for the user.
  Future<MobileSyncResult> sync(Repo repo, {String? password, String? usernameOverride}) async {
    final pw = password ?? _password;
    final user = usernameOverride ?? username;
    final db = repo.store;
    final lastSent = int.parse(await db.getMeta('m_sent') ?? '0');
    final seen = int.parse(await db.getMeta('m_seen') ?? '0');
    final snapshot = await db.currentSeq();
    final all = await db.changesSince(lastSent);
    final changes = {for (final t in mobileTables) t: all[t] ?? const <Map<String, Object?>>[]};
    final sent = changes.values.fold<int>(0, (a, b) => a + b.length);

    final ch = RemoteChannel(host: host, port: port, code: code);
    final Map<String, dynamic> r;
    try {
      r = await ch.post(
        'api/mobile/sync',
        {
          'companyId': companyId,
          'username': user,
          'password': pw,
          'deviceId': prefs.deviceUid,
          'deviceName': 'موبایل ${prefs.deviceUid.substring(0, 4)}',
          'since': seen,
          'changes': changes,
        },
        auth: false,
        timeout: const Duration(seconds: 60),
      );
    } finally {
      ch.close();
    }
    _password = pw;
    final received = await db.applyRemote(Map<String, dynamic>.from(r['changes'] as Map));
    // Skip the rows that just arrived (they are not ours to send back).
    final now = await db.currentSeq();
    await db.setMeta('m_sent', '${now - snapshot == received ? now : snapshot}');
    await db.setMeta('m_seen', '${r['seq']}');
    await prefs.set('mobile_last_sync', DateTime.now().toIso8601String());
    final u = Map<String, dynamic>.from(r['user'] as Map);
    final access = Access.fromJson(Map<String, dynamic>.from(r['access'] as Map));
    await prefs.set(
        'mobile_profile',
        MobileProfile(
                userId: u['id'] as String, username: u['username'] as String, display: u['display'] as String, roleName: u['roleName'] as String,
                companyName: r['companyName'] as String, perms: access.perms)
            .toJson());
    repo.changed();
    notifyListeners();
    return MobileSyncResult(
      sent: sent,
      received: received,
      renumbered: (r['renumbered'] as num?)?.toInt() ?? 0,
      rejected: [for (final x in r['rejected'] as List) MobileRejection('${(x as Map)['label']}', '${x['reason']}')],
    );
  }
}

/// Re-exported for the setup screen: the companies a server offers.
Future<List<(String, String)>> serverCompanies(String host, int port, String code) async {
  final ch = RemoteChannel(host: host, port: port, code: code);
  try {
    final r = await ch.post('api/info', {}, auth: false, timeout: const Duration(seconds: 12));
    return [for (final c in r['companies'] as List) ((c as Map)['id'] as String, c['name'] as String)];
  } finally {
    ch.close();
  }
}
