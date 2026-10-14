import 'db.dart';
import 'device_prefs.dart';
import 'remote_db.dart';
import 'repo.dart';

/// A [Repo] whose data lives on the server behind [channel].
Future<Repo> openRemoteRepo(RemoteChannel channel, DevicePrefs prefs, String companyId) async {
  final store = await AppDb.wrap(RemoteDatabase(channel));
  final repo = Repo(store, prefs: prefs, companyId: companyId);
  await repo.init();
  return repo;
}
