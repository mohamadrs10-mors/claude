// Makes an owner master phrase for PIN recovery.
//
//   dart run tool/make_master_key.dart
//
// Keep the PHRASE offline (password manager, paper). Put only the HASH into the
// build:  flutter build windows --dart-define=MASTER_KEY_HASH=<hash>
// For the GitHub build, add the hash as a repository secret named MASTER_KEY_HASH.
// A build without the hash has no master recovery at all.
import 'dart:io';

import 'package:simple_accounting/data/recovery.dart';

void main() {
  final phrase = Recovery.newKey(groups: 6);
  stdout.writeln('Master phrase (keep it secret, do NOT commit it):');
  stdout.writeln('  $phrase');
  stdout.writeln('');
  stdout.writeln('Hash to put in the build (safe to store as a CI secret):');
  stdout.writeln('  ${Recovery.masterHash(phrase)}');
}
