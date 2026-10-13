import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show DatabaseFactory;

import 'db.dart';
import 'device_prefs.dart';
import 'repo.dart';

class CompanyInfo {
  CompanyInfo(this.id, this.name, this.file, this.createdAt);
  final String id, file, createdAt;
  String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'file': file, 'createdAt': createdAt};
  factory CompanyInfo.fromJson(Map<String, dynamic> j) =>
      CompanyInfo(j['id'] as String, j['name'] as String, j['file'] as String, (j['createdAt'] ?? '') as String);
}

/// Keeps several companies (مجموعه‌ها) in one app. Every company has its own
/// database file, so their data can never mix; one of them is "active" and is
/// what the screens show. The registry of companies lives in `companies.json`.
class CompanyManager extends ChangeNotifier {
  CompanyManager._(this.dir, this.prefs, this._factory);

  final Directory dir;
  final DevicePrefs prefs;
  final DatabaseFactory? _factory;

  final List<CompanyInfo> companies = [];
  String activeId = '';
  final Map<String, Repo> _open = {};

  File get _registry => File(p.join(dir.path, 'companies.json'));

  CompanyInfo get activeInfo => companies.firstWhere((c) => c.id == activeId);
  Repo get active => _open[activeId]!;

  /// Opens the registry, creating the first company on a fresh install or
  /// adopting the single database of an older version.
  static Future<CompanyManager> open({Directory? dir, DevicePrefs? prefs, DatabaseFactory? factory}) async {
    final d = dir ?? await getApplicationDocumentsDirectory();
    await d.create(recursive: true);
    final m = CompanyManager._(d, prefs ?? await DevicePrefs.open(d), factory);
    if (await m._registry.exists()) {
      final j = jsonDecode(await m._registry.readAsString()) as Map<String, dynamic>;
      m.companies.addAll([for (final c in j['companies'] as List) CompanyInfo.fromJson(Map<String, dynamic>.from(c as Map))]);
      m.activeId = (j['active'] ?? '') as String;
    }
    if (m.companies.isEmpty) {
      final legacy = File(p.join(d.path, 'accounting.db'));
      if (await legacy.exists()) {
        await m._adoptLegacy();
      } else {
        await m.create('شرکت من', seed: true, activate: true);
      }
    }
    if (!m.companies.any((c) => c.id == m.activeId)) m.activeId = m.companies.first.id;
    await m._openRepo(m.activeInfo);
    await m._save();
    return m;
  }

  /// A test helper: one ready-made company per entry of [repos].
  @visibleForTesting
  static CompanyManager forRepos(Map<String, Repo> repos, DevicePrefs prefs) {
    final m = CompanyManager._(Directory.systemTemp, prefs, null);
    for (final e in repos.entries) {
      m.companies.add(CompanyInfo(e.key, e.key, '', ''));
      m._open[e.key] = e.value;
    }
    m.activeId = repos.keys.first;
    return m;
  }

  // ---- legacy -------------------------------------------------------------

  /// Versions before 1.5 had a single `accounting.db`: it becomes the first
  /// company, and the device-wide settings stored inside it move to [prefs].
  Future<void> _adoptLegacy() async {
    final info = CompanyInfo(AppDb.newId(), 'شرکت من', 'accounting.db', DateTime.now().toIso8601String());
    final store = await AppDb.open(path: p.join(dir.path, info.file), factory: _factory);
    for (final k in ['theme_mode', 'theme_seed', 'font_scale', 'compact', 'print_paper', 'print_landscape', 'print_margin', 'print_font', 'print_roll', 'pair_code']) {
      final v = await store.getMeta(k);
      if (v != null && prefs.get(k) == null) await prefs.set(k, v);
    }
    final rows = await store.db.query('settings', where: "id='business_name' AND deleted=0");
    if (rows.isNotEmpty && (rows.first['value'] as String).isNotEmpty) info.name = rows.first['value'] as String;
    await store.close();
    companies.add(info);
    activeId = info.id;
  }

  // ---- opening ------------------------------------------------------------

  Future<Repo> _openRepo(CompanyInfo info) async {
    final existing = _open[info.id];
    if (existing != null) return existing;
    final store = await AppDb.open(path: p.join(dir.path, info.file), factory: _factory);
    final r = Repo(store, prefs: prefs, companyId: info.id);
    await r.init();
    _open[info.id] = r;
    return r;
  }

  /// The repository of any company on this device (opened on demand), or null.
  Future<Repo?> repoFor(String id) async {
    final i = companies.where((c) => c.id == id).firstOrNull;
    if (i == null) return null;
    return _openRepo(i);
  }

  Future<void> _save() => _registry.writeAsString(jsonEncode({
        'version': 1,
        'active': activeId,
        'companies': [for (final c in companies) c.toJson()],
      }), flush: true);

  // ---- changes ------------------------------------------------------------

  /// Creates a company. With [seed] it starts with a cash account and the usual
  /// income and expense categories. [id] is used when the company is copied
  /// from another device so both sides share one identity.
  Future<CompanyInfo> create(String name, {bool seed = true, bool activate = false, String? id}) async {
    final cid = id ?? AppDb.newId();
    if (companies.any((c) => c.id == cid)) throw StateError('این شرکت قبلاً اضافه شده است.');
    final info = CompanyInfo(cid, name.trim().isEmpty ? 'شرکت جدید' : name.trim(), 'company_$cid.db', DateTime.now().toIso8601String());
    companies.add(info);
    final r = await _openRepo(info);
    if (seed) await _seed(r);
    if (activate || activeId.isEmpty) activeId = cid;
    await _save();
    notifyListeners();
    return info;
  }

  static Future<void> _seed(Repo r) async {
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    for (final n in ['فروش کالا', 'سایر درآمدها']) {
      await r.saveCategory(name: n, kind: 'income');
    }
    for (final n in ['اجاره', 'حقوق و دستمزد', 'حمل و نقل', 'آب، برق، گاز و تلفن', 'تبلیغات', 'تعمیرات', 'سایر هزینه‌ها']) {
      await r.saveCategory(name: n, kind: 'expense');
    }
  }

  Future<void> switchTo(String id) async {
    if (id == activeId || !companies.any((c) => c.id == id)) return;
    await _openRepo(companies.firstWhere((c) => c.id == id));
    activeId = id;
    await _save();
    notifyListeners();
  }

  Future<void> rename(String id, String name) async {
    final c = companies.firstWhere((c) => c.id == id);
    if (name.trim().isEmpty) return;
    c.name = name.trim();
    await _save();
    notifyListeners();
  }

  /// Permanently removes a company and its data from this device.
  Future<void> delete(String id) async {
    if (companies.length <= 1) throw StateError('حداقل یک شرکت باید باقی بماند.');
    final info = companies.firstWhere((c) => c.id == id);
    final r = _open.remove(id);
    await r?.store.close();
    companies.remove(info);
    if (activeId == id) {
      activeId = companies.first.id;
      await _openRepo(companies.first);
    }
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final f = File(p.join(dir.path, info.file + suffix));
      if (await f.exists()) await f.delete();
    }
    await _save();
    notifyListeners();
  }

  /// Makes a local company the same company as one on another device, so the
  /// two can be synchronised. Returns false if [newId] is already used here.
  Future<bool> adoptId(String oldId, String newId) async {
    if (oldId == newId) return true;
    if (companies.any((c) => c.id == newId)) return false;
    final i = companies.indexWhere((c) => c.id == oldId);
    if (i < 0) return false;
    final old = companies[i];
    final renamed = CompanyInfo(newId, old.name, old.file, old.createdAt);
    companies[i] = renamed;
    final r = _open.remove(oldId);
    if (r != null) {
      r.companyId = newId;
      _open[newId] = r;
    }
    if (activeId == oldId) activeId = newId;
    await _save();
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    for (final r in _open.values) {
      r.store.close();
    }
    super.dispose();
  }
}
