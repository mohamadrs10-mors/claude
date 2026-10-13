import 'dart:io';

import 'package:path/path.dart' as p;

import 'company_manager.dart';

class BackupFile {
  BackupFile(this.file, this.modified, this.size);
  final File file;
  final DateTime modified;
  final int size;
  String get name => p.basename(file.path);
}

/// Automatic daily backups of every company, kept next to the databases in
/// `backups/<company id>/`. A backup is the same JSON the manual backup makes,
/// so it can be restored from Settings.
class BackupService {
  BackupService(this.companies);
  final CompanyManager companies;

  bool get enabled => companies.prefs.get('auto_backup') != '0';
  Future<void> setEnabled(bool v) => companies.prefs.set('auto_backup', v ? '1' : '0');

  /// How many backups to keep per company.
  int get keep => (int.tryParse(companies.prefs.get('backup_keep') ?? '') ?? 14).clamp(1, 365);
  Future<void> setKeep(int n) => companies.prefs.set('backup_keep', '${n.clamp(1, 365)}');

  Directory dirFor(String companyId) => Directory(p.join(companies.dir.path, 'backups', companyId));

  static String _stamp(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}_${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  /// Writes a backup of one company now and removes the oldest ones beyond [keep].
  Future<File> backupNow(String companyId, {DateTime? now}) async {
    final repo = await companies.repoFor(companyId);
    if (repo == null) throw StateError('شرکت پیدا نشد.');
    final dir = dirFor(companyId);
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, 'backup-${_stamp(now ?? DateTime.now())}.json'));
    await f.writeAsString(await repo.exportJson(), flush: true);
    await _prune(companyId);
    return f;
  }

  Future<List<BackupFile>> list(String companyId) async {
    final dir = dirFor(companyId);
    if (!await dir.exists()) return [];
    final out = <BackupFile>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.json')) {
        final st = await e.stat();
        out.add(BackupFile(e, st.modified, st.size));
      }
    }
    out.sort((a, b) => b.name.compareTo(a.name)); // names start with the date: newest first
    return out;
  }

  Future<void> _prune(String companyId) async {
    final all = await list(companyId);
    for (final b in all.skip(keep)) {
      await b.file.delete();
    }
  }

  /// Backs up every company that has no backup from today yet. Returns how many
  /// were written. Does nothing when automatic backups are switched off.
  Future<int> runIfDue({DateTime? now}) async {
    if (!enabled) return 0;
    final today = now ?? DateTime.now();
    final prefix = 'backup-${_stamp(today).substring(0, 10)}';
    var written = 0;
    for (final c in List.of(companies.companies)) {
      final have = await list(c.id);
      if (have.any((b) => b.name.startsWith(prefix))) continue;
      try {
        await backupNow(c.id, now: today);
        written++;
      } catch (_) {
        // A failed backup must never stop the app; the next run tries again.
      }
    }
    return written;
  }
}
