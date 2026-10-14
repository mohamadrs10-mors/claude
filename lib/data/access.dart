// Who may do what. A role is a set of permission keys; the current user's
// [Access] is checked by the screens (to hide what they may not use) and,
// more importantly, by the database layer, which refuses writes to tables the
// role may not change, on the server for network clients and on this device
// for local users.

/// Thrown when a user tries something their role does not allow.
class AccessDenied implements Exception {
  AccessDenied([this.message = 'شما اجازهٔ این کار را ندارید.']);
  final String message;
  @override
  String toString() => message;
}

/// The sections of the app: key, title. Each has a `.view` and (except the
/// dashboard and the reports) an `.edit` permission.
const permAreas = <(String, String)>[
  ('dashboard', 'داشبورد'),
  ('transactions', 'تراکنش‌ها'),
  ('invoices', 'فاکتورها'),
  ('orders', 'سفارش و پیش‌دریافت'),
  ('deliveries', 'رسید تحویل'),
  ('products', 'کالاها و انبار'),
  ('pricing', 'قیمت‌گذاری'),
  ('parties', 'اشخاص'),
  ('cheques', 'چک‌ها'),
  ('accounts', 'حساب‌ها'),
  ('reports', 'گزارش‌ها'),
];

/// Areas that can only be looked at.
const _viewOnlyAreas = {'dashboard', 'reports'};

const permSettings = 'settings.manage';
const permUsers = 'users.manage';

String permView(String area) => '$area.view';
String permEdit(String area) => '$area.edit';

/// Every permission key, in display order.
List<String> get allPermissions => [
      for (final (a, _) in permAreas) ...[permView(a), if (!_viewOnlyAreas.contains(a)) permEdit(a)],
      permSettings,
      permUsers,
    ];

/// Title of a permission for the roles screen.
String permLabel(String key) {
  if (key == permSettings) return 'تنظیمات شرکت، پشتیبان و اکسل';
  if (key == permUsers) return 'مدیریت کاربران و نقش‌ها';
  final area = key.split('.').first;
  final title = permAreas.firstWhere((a) => a.$1 == area, orElse: () => (area, area)).$2;
  return key.endsWith('.edit') ? '$title: ثبت و ویرایش و حذف' : '$title: مشاهده';
}

/// A named set of permissions.
class Role {
  Role(this.id, this.name, this.perms, {this.builtin = false});
  final String id, name;
  final Set<String> perms;

  /// Ready-made roles can be changed but the "admin" one always keeps everything.
  final bool builtin;
}

/// The roles every company starts with once users are switched on.
List<Role> presetRoles() {
  final all = allPermissions.toSet();
  final view = {for (final (a, _) in permAreas) permView(a)};
  return [
    Role('admin', 'مدیر کل', all, builtin: true),
    Role('accountant', 'حسابدار', {...all}..removeAll([permUsers, permSettings]), builtin: true),
    Role('seller', 'فروشنده / صندوقدار', {
      'dashboard.view', 'invoices.view', 'invoices.edit', 'orders.view', 'orders.edit', 'deliveries.view', 'deliveries.edit',
      'parties.view', 'parties.edit', 'products.view', 'transactions.view', 'transactions.edit', 'cheques.view', 'accounts.view',
    }, builtin: true),
    Role('storekeeper', 'انباردار', {
      'dashboard.view', 'products.view', 'products.edit', 'deliveries.view', 'deliveries.edit', 'invoices.view', 'orders.view', 'parties.view',
    }, builtin: true),
    Role('viewer', 'فقط مشاهده', view, builtin: true),
  ];
}

/// What the signed-in user may do. [unrestricted] is used when users are not
/// switched on for the company: everything is allowed.
class Access {
  Access(this.perms) : unrestricted = false;
  const Access.unrestricted()
      : perms = const {},
        unrestricted = true;

  final Set<String> perms;
  final bool unrestricted;

  bool can(String perm) => unrestricted || perms.contains(perm);
  bool canView(String area) => can(permView(area));
  bool canEdit(String area) => can(permEdit(area));

  /// Whether the user may change anything at all.
  bool get canEditAnything => unrestricted || perms.any((p) => p.endsWith('.edit') || p == permSettings);

  /// Whether a write to database table [table] is allowed.
  bool canWriteTable(String table) {
    if (unrestricted) return true;
    final needed = _tableWriters[table.toLowerCase()];
    if (needed == null) return false; // unknown and the account tables: never
    if (needed.isEmpty) return canEditAnything;
    return needed.any(perms.contains);
  }

  Map<String, Object?> toJson() => {'perms': perms.toList()..sort(), 'unrestricted': unrestricted};
  factory Access.fromJson(Map<String, dynamic> j) =>
      j['unrestricted'] == true ? const Access.unrestricted() : Access({for (final p in (j['perms'] as List)) '$p'});
}

/// Which permissions allow writing to a table (an empty list: any edit right).
/// Tables that are missing here, like the users and roles, cannot be written
/// through the guarded database at all.
const _tableWriters = <String, List<String>>{
  'accounts': ['accounts.edit'],
  'categories': ['accounts.edit', permSettings],
  'parties': ['parties.edit'],
  'products': ['products.edit', permSettings],
  'product_groups': ['products.edit', permSettings],
  'costings': ['pricing.edit', 'products.edit'],
  'formulas': ['pricing.edit'],
  'cheques': ['cheques.edit', 'orders.edit'],
  'invoices': ['invoices.edit'],
  'invoice_items': ['invoices.edit'],
  'transactions': ['transactions.edit', 'orders.edit', 'cheques.edit'],
  'orders': ['orders.edit'],
  'order_items': ['orders.edit'],
  'deliveries': ['deliveries.edit'],
  'delivery_items': ['deliveries.edit'],
  'settings': [],
  'meta': [],
};

/// Tables nobody reads or writes through the guarded database (passwords!).
const protectedTables = {'users', 'roles'};
