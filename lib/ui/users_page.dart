import 'package:flutter/material.dart';

import '../data/access.dart';
import '../data/remote_db.dart';
import '../data/repo.dart';
import '../data/user_admin.dart';
import '../util/format.dart';
import 'activity_tab.dart';
import 'common.dart';

String _msg(Object e) => e is StateError ? e.message : (e is NetException ? e.message : '$e');

/// Users, roles and who is signed in where, for one company. Switching users on
/// is only offered on the server itself ([onEnable]).
class UsersPage extends StatefulWidget {
  const UsersPage({super.key, required this.admin, this.onEnable, this.onDisable, this.currentUserId, this.repo});

  /// For printing the activity report.
  final Repo? repo;
  final UserAdmin admin;

  /// Creates the first user (the administrator) and signs them in; null on a network client.
  final Future<void> Function(String username, String password, String fullName)? onEnable;

  /// Switches users off again (server only).
  final Future<void> Function()? onDisable;
  final String? currentUserId;

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _Data {
  _Data(this.enabled, this.users, this.roles, this.sessions);
  final bool enabled;
  final List<UserInfo> users;
  final List<Role> roles;
  final List<SessionInfo> sessions;
}

class _UsersPageState extends State<UsersPage> with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 4, vsync: this);
  late Future<_Data> future = _load();

  UserAdmin get admin => widget.admin;

  Future<_Data> _load() async {
    final enabled = await admin.enabled();
    if (!enabled) return _Data(false, [], [], []);
    return _Data(true, await admin.users(), await admin.roles(), await admin.sessions());
  }

  void _reload() {
    setState(() {
      future = _load();
    });
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    try {
      await job();
    } catch (e) {
      if (mounted) toast(context, _msg(e));
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Data>(
        future: future,
        builder: (c, snap) {
          if (snap.hasError) return Center(child: Text('خطا: ${_msg(snap.error!)}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final d = snap.data!;
          if (!d.enabled) return _enableCard(c);
          return Constrained(
            child: Column(children: [
              TabBar(controller: tabs, tabs: const [Tab(text: 'کاربران'), Tab(text: 'نقش‌ها و دسترسی'), Tab(text: 'نشست‌های فعال'), Tab(text: 'گزارش فعالیت')]),
              Expanded(child: TabBarView(controller: tabs, children: [_usersTab(c, d), _rolesTab(c, d), _sessionsTab(c, d), ActivityTab(admin: admin, users: d.users, repo: widget.repo)])),
            ]),
          );
        },
      );

  // ---- switching on -------------------------------------------------------

  Widget _enableCard(BuildContext c) {
    final user = TextEditingController();
    final name = TextEditingController();
    final pass = TextEditingController();
    return Constrained(
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Section(
          title: 'فعال‌سازی کاربران',
          child: widget.onEnable == null
              ? const Text('کاربران برای این شرکت هنوز فعال نشده‌اند. در برنامهٔ سرور از همین بخش فعال کنید.')
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    'با فعال‌سازی، ورود با نام کاربری و رمز عبور لازم می‌شود و می‌توانید برای هر نفر نقش و سطح دسترسی تعیین کنید. '
                    'همچنین سیستم‌های دیگر شبکه فقط با کاربر معتبر می‌توانند به این شرکت وصل شوند. '
                    'کاربر اول «مدیر کل» است؛ نام کاربری و رمز او را جایی امن نگه دارید.',
                    style: Theme.of(c).textTheme.bodySmall,
                  ),
                  gap(),
                  TextField(controller: user, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'نام کاربری مدیر (انگلیسی)')),
                  gap(),
                  TextField(controller: name, decoration: const InputDecoration(labelText: 'نام کامل (اختیاری)')),
                  gap(),
                  TextField(controller: pass, obscureText: true, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'رمز عبور (حداقل ۴ نویسه)')),
                  gap(16),
                  FilledButton.icon(
                    icon: const Icon(Icons.verified_user_outlined),
                    label: const Text('فعال‌سازی'),
                    onPressed: () => _run(() => widget.onEnable!(user.text, pass.text, name.text)),
                  ),
                ]),
        ),
      ]),
    );
  }

  // ---- users --------------------------------------------------------------

  Widget _usersTab(BuildContext c, _Data d) => Scaffold(
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
          Card(
            child: Column(children: [
              for (var i = 0; i < d.users.length; i++) ...[
                if (i > 0) const Divider(),
                ListTile(
                  leading: CircleAvatar(child: Text(d.users[i].display.characters.first)),
                  title: Text(d.users[i].display, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${d.users[i].username} • ${d.users[i].roleName}${d.users[i].online ? ' • آنلاین در «${d.users[i].device}»' : ''}'),
                  trailing: d.users[i].active ? (d.users[i].online ? StatusChip('آنلاین', Colors.green.shade700) : null) : StatusChip('غیرفعال', Colors.grey),
                  onTap: () => _editUser(c, d, d.users[i]),
                ),
              ],
            ]),
          ),
          if (widget.onDisable != null) ...[
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                icon: const Icon(Icons.no_accounts_outlined),
                label: const Text('غیرفعال کردن کاربران (بازگشت به حالت بدون ورود)'),
                onPressed: () async {
                  if (!await confirm(c, 'همهٔ کاربران حذف شوند و ورود با رمز لازم نباشد؟ سیستم‌های شبکه هم دیگر نمی‌توانند وصل شوند.')) return;
                  await _run(widget.onDisable!);
                },
              ),
            ),
          ],
        ]),
        floatingActionButton: FloatingActionButton.extended(onPressed: () => _editUser(c, d, null), icon: const Icon(Icons.person_add_alt), label: const Text('کاربر جدید')),
      );

  Future<void> _editUser(BuildContext c, _Data d, UserInfo? u) async {
    final username = TextEditingController(text: u?.username);
    final full = TextEditingController(text: u?.fullName);
    final pass = TextEditingController();
    var role = u?.roleId ?? (d.roles.any((r) => r.id == 'seller') ? 'seller' : d.roles.first.id);
    var active = u?.active ?? true;
    await showDialog<void>(
      context: c,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: Text(u == null ? 'کاربر جدید' : 'ویرایش کاربر'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: username, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'نام کاربری (انگلیسی)')),
                gap(),
                TextField(controller: full, decoration: const InputDecoration(labelText: 'نام کامل')),
                gap(),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'نقش (سطح دسترسی)'),
                  items: [for (final r in d.roles) DropdownMenuItem(value: r.id, child: Text(r.name))],
                  onChanged: (v) => set(() => role = v ?? role),
                ),
                gap(),
                TextField(
                  controller: pass,
                  obscureText: true,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(labelText: u == null ? 'رمز عبور' : 'رمز عبور جدید (خالی = بدون تغییر)'),
                ),
                if (u != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('کاربر فعال است'), value: active, onChanged: (v) => set(() => active = v)),
              ]),
            ),
          ),
          actions: [
            if (u != null && u.online)
              TextButton(
                onPressed: () async {
                  Navigator.pop(dc);
                  await _run(() => admin.kick(u.id));
                },
                child: const Text('قطع نشست'),
              ),
            if (u != null && u.id != widget.currentUserId)
              TextButton(
                onPressed: () async {
                  if (!await confirm(dc, 'این کاربر حذف شود؟')) return;
                  if (dc.mounted) Navigator.pop(dc);
                  await _run(() => admin.deleteUser(u.id));
                },
                child: const Text('حذف'),
              ),
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () async {
                Navigator.pop(dc);
                await _run(() async {
                  await admin.saveUser(id: u?.id, username: username.text, fullName: full.text, roleId: role, password: pass.text.isEmpty ? null : pass.text, active: active);
                });
              },
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
  }

  // ---- roles --------------------------------------------------------------

  Widget _rolesTab(BuildContext c, _Data d) => Scaffold(
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
          Text('هر نقش مشخص می‌کند چه بخش‌هایی دیده و چه کارهایی انجام شود. ثبت و ویرایش بدون «مشاهدهٔ» همان بخش کارایی ندارد.', style: Theme.of(c).textTheme.bodySmall),
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              for (var i = 0; i < d.roles.length; i++) ...[
                if (i > 0) const Divider(),
                ListTile(
                  leading: Icon(d.roles[i].id == 'admin' ? Icons.admin_panel_settings_outlined : Icons.badge_outlined),
                  title: Text(d.roles[i].name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${faDigits('${d.roles[i].perms.length}')} دسترسی • ${faDigits('${d.users.where((u) => u.roleId == d.roles[i].id).length}')} کاربر'),
                  onTap: () => _editRole(c, d.roles[i]),
                ),
              ],
            ]),
          ),
        ]),
        floatingActionButton: FloatingActionButton.extended(onPressed: () => _editRole(c, null), icon: const Icon(Icons.add), label: const Text('نقش جدید')),
      );

  Future<void> _editRole(BuildContext c, Role? r) async {
    final name = TextEditingController(text: r?.name);
    final perms = {...?r?.perms};
    final locked = r?.id == 'admin';
    Widget box(StateSetter set, String perm) => Checkbox(
          value: locked || perms.contains(perm),
          onChanged: locked ? null : (v) => set(() => v == true ? perms.add(perm) : perms.remove(perm)),
        );
    await showDialog<void>(
      context: c,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: Text(r == null ? 'نقش جدید' : 'ویرایش نقش'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(controller: name, enabled: !locked, decoration: const InputDecoration(labelText: 'نام نقش')),
                if (locked) Padding(padding: const EdgeInsets.only(top: 8), child: Text('مدیر کل همیشه به همه‌چیز دسترسی دارد.', style: Theme.of(dc).textTheme.bodySmall)),
                const SizedBox(height: 12),
                Row(children: [
                  const Expanded(child: Text('بخش', style: TextStyle(fontWeight: FontWeight.w700))),
                  const SizedBox(width: 56, child: Text('مشاهده', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700))),
                  const SizedBox(width: 56, child: Text('ثبت/ویرایش', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11))),
                ]),
                const Divider(height: 8),
                for (final (area, title) in permAreas)
                  Row(children: [
                    Expanded(child: Text(title)),
                    SizedBox(width: 56, child: Center(child: box(set, permView(area)))),
                    SizedBox(width: 56, child: allPermissions.contains(permEdit(area)) ? Center(child: box(set, permEdit(area))) : const SizedBox()),
                  ]),
                const Divider(height: 16),
                CheckboxListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(permLabel(permSettings)), value: locked || perms.contains(permSettings), onChanged: locked ? null : (v) => set(() => v == true ? perms.add(permSettings) : perms.remove(permSettings))),
                CheckboxListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(permLabel(permUsers)), value: locked || perms.contains(permUsers), onChanged: locked ? null : (v) => set(() => v == true ? perms.add(permUsers) : perms.remove(permUsers))),
              ]),
            ),
          ),
          actions: [
            if (r != null && !locked)
              TextButton(
                onPressed: () async {
                  if (!await confirm(dc, 'این نقش حذف شود؟')) return;
                  if (dc.mounted) Navigator.pop(dc);
                  await _run(() => admin.deleteRole(r.id));
                },
                child: const Text('حذف'),
              ),
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            if (!locked)
              FilledButton(
                onPressed: () async {
                  Navigator.pop(dc);
                  await _run(() async {
                    await admin.saveRole(id: r?.id, name: name.text, perms: perms);
                  });
                },
                child: const Text('ذخیره'),
              ),
          ],
        ),
      ),
    );
  }

  // ---- sessions -----------------------------------------------------------

  Widget _sessionsTab(BuildContext c, _Data d) => ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
        Text('هر کاربر هم‌زمان فقط در یک سیستم می‌تواند وارد باشد. اگر سیستمی قطع شود، بعد از حدود یک دقیقه کاربرش آزاد می‌شود؛ با «قطع نشست» همان لحظه آزاد می‌شود.', style: Theme.of(c).textTheme.bodySmall),
        const SizedBox(height: 8),
        if (d.sessions.isEmpty)
          emptyState('الان کسی وارد نیست.')
        else
          Card(
            child: Column(children: [
              for (var i = 0; i < d.sessions.length; i++) ...[
                if (i > 0) const Divider(),
                ListTile(
                  leading: Icon(d.sessions[i].local ? Icons.dns_outlined : Icons.computer_outlined),
                  title: Text(d.sessions[i].username, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${d.sessions[i].deviceName} • از ${jalaliText(isoOf(d.sessions[i].since))}'),
                  trailing: TextButton(onPressed: () => _run(() => admin.kick(d.sessions[i].userId)), child: const Text('قطع نشست')),
                ),
              ],
            ]),
          ),
        const SizedBox(height: 8),
        Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh), label: const Text('به‌روزرسانی'))),
      ]);
}
