import 'package:flutter/foundation.dart';

import 'device_prefs.dart';

/// How this system takes part in a network: on its own (the default), as the
/// server whose data the others use, or as a client that works on a server's
/// data. Kept in the device preferences.
class NetMode extends ChangeNotifier {
  NetMode(this.prefs);
  final DevicePrefs prefs;

  static const standalone = 'standalone', server = 'server', client = 'client', mobile = 'mobile';

  String get mode => prefs.get('net_mode') ?? standalone;
  bool get isClient => mode == client;
  bool get isServer => mode == server;
  bool get isMobile => mode == mobile;

  Future<void> setMode(String m) async {
    await prefs.set('net_mode', m);
    notifyListeners();
  }

  // What the client remembers about its server.
  String get host => prefs.get('client_host') ?? '';
  int get port => int.tryParse(prefs.get('client_port') ?? '') ?? 8765;
  String get code => prefs.get('client_code') ?? '';
  String get lastCompany => prefs.get('client_company') ?? '';
  String get lastUser => prefs.get('client_user') ?? '';

  Future<void> remember({String? host, int? port, String? code, String? company, String? user}) async {
    if (host != null) await prefs.set('client_host', host);
    if (port != null) await prefs.set('client_port', '$port');
    if (code != null) await prefs.set('client_code', code);
    if (company != null) await prefs.set('client_company', company);
    if (user != null) await prefs.set('client_user', user);
  }
}
