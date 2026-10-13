// Removes the PIN lock of one company (or all) from this device, from the file
// system, when the PIN and the recovery key are both lost. Your accounting data
// is not touched: the PIN is only a gate in front of the app, not encryption.
//
//   dart run tool/reset_lock.dart <path to prefs.json> [company id]
//
// prefs.json lives next to the databases (companies.json, company_*.db):
//   Windows : C:\Users\<you>\Documents\prefs.json
//   Linux   : ~/Documents/prefs.json
// Close the app first. A copy is saved as prefs.json.bak.
import 'dart:convert';
import 'dart:io';

import 'package:simple_accounting/data/recovery.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/reset_lock.dart <path to prefs.json> [company id]');
    exit(64);
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('File not found: ${file.path}');
    exit(66);
  }
  final prefs = Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map);
  file.copySync('${file.path}.bak');
  final n = Recovery.stripLocks(prefs, companyId: args.length > 1 ? args[1] : null);
  file.writeAsStringSync(jsonEncode(prefs));
  stdout.writeln(n == 0 ? 'No PIN lock was set.' : 'Removed $n lock entr${n == 1 ? 'y' : 'ies'}. The app will open without a PIN.');
}
