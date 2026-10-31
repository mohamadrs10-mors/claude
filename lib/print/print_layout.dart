import 'dart:convert';

import '../data/device_prefs.dart';

/// One thing a printout can show or leave out.
class PrintElement {
  const PrintElement(this.key, this.label, [this.def = true]);
  final String key, label;

  /// Whether it is shown unless the user switched it off.
  final bool def;
}

/// A kind of printout and the parts of it the user can switch on and off.
class PrintKind {
  const PrintKind(this.id, this.label, this.elements);
  final String id, label;
  final List<PrintElement> elements;
}

const _logo = PrintElement('logo', 'لوگو');
const _pageNo = PrintElement('pageno', 'شمارهٔ صفحه (پایین برگه)');
const _address = PrintElement('address', 'نشانی فروشگاه زیر نام');
const _phone = PrintElement('phone', 'تلفن فروشگاه');
const _partyPhone = PrintElement('party_phone', 'تلفن (و نشانی) مشتری');
const _rowNo = PrintElement('rownum', 'ستون ردیف');
const _note = PrintElement('note', 'توضیحات');
const _signatures = PrintElement('signatures', 'کادر امضا');
const _summary = PrintElement('summary', 'کادرهای خلاصه بالای جدول');
const _date = PrintElement('date', 'تاریخ گزارش در زیر عنوان');

/// Every printout whose look can be set, with its parts.
const printKinds = <PrintKind>[
  PrintKind('invoice', 'فاکتور (A4 / A5)', [
    _logo, _address, _phone, PrintElement('taxid', 'شناسهٔ اقتصادی'), _partyPhone, _rowNo,
    PrintElement('warehouse', 'نام انبار'), PrintElement('due', 'تاریخ سررسید'), _note, _signatures,
    PrintElement('footer', 'متن پایین فاکتور (از تنظیمات کسب‌وکار)'), PrintElement('qr', 'کد QR', false), _pageNo,
  ]),
  PrintKind('roll', 'رسید حرارتی', [_logo, _phone, PrintElement('party', 'نام مشتری'), PrintElement('footer', 'متن پایین')]),
  PrintKind('order', 'سفارش', [
    _logo, _address, _partyPhone, PrintElement('delivery', 'تاریخ تحویل'), _summary, _rowNo,
    PrintElement('words', 'مبلغ به حروف'), PrintElement('cheques', 'جدول چک‌های پیش‌دریافت'), _note, _signatures, _pageNo,
  ]),
  PrintKind('draft', 'پیش‌نویس سفارش', [
    _logo, _address, _partyPhone, PrintElement('delivery', 'تاریخ تحویل'), _summary, _rowNo,
    PrintElement('words', 'مبلغ به حروف'), _note, _signatures, PrintElement('closing', 'جملهٔ پایانی (اعتبار قیمت‌ها)'), _pageNo,
  ]),
  PrintKind('delivery', 'رسید تحویل', [
    _logo, _address, _partyPhone, _rowNo, PrintElement('count', 'تعداد اقلام'), _note, _signatures,
    PrintElement('footer', 'متن پایین (از تنظیمات کسب‌وکار)'), _pageNo,
  ]),
  PrintKind('statement', 'صورت‌حساب و معین اشخاص', [_logo, _summary, _date, PrintElement('footnote', 'توضیح پایین'), _pageNo]),
  PrintKind('report', 'گزارش‌ها، فیش حقوقی و فهرست‌ها', [_logo, _summary, _date, PrintElement('footnote', 'توضیح پایین'), _pageNo]),
];

/// Which parts of each printout are shown, and the page margins of each one.
/// Kept per device like the other print settings (a PC and a phone usually
/// print on different paper); nothing here is synced.
class PrintLayout {
  const PrintLayout([this._data = const {}]);
  final Map<String, Map<String, Object?>> _data;

  static PrintKind? kind(String id) => printKinds.where((k) => k.id == id).firstOrNull;

  /// What the user chose for a part, or null when left at its default.
  bool? explicit(String kindId, String key) {
    final v = (_data[kindId]?['show'] as Map?)?[key];
    return v is bool ? v : null;
  }

  bool shows(String kindId, String key) => explicit(kindId, key) ?? (kind(kindId)?.elements.where((e) => e.key == key).firstOrNull?.def ?? true);

  /// Margins in mm as top, right, bottom, left; null entries use the page margin from Settings.
  List<double?>? margins(String kindId) {
    final m = _data[kindId]?['margin'];
    if (m is! List || m.length != 4) return null;
    return [for (final v in m) v is num ? v.toDouble().clamp(0, 60).toDouble() : null];
  }

  PrintLayout _with(String kindId, void Function(Map<String, Object?>) f) {
    final copy = {for (final e in _data.entries) e.key: Map<String, Object?>.from(e.value)};
    final k = copy.putIfAbsent(kindId, () => {});
    f(k);
    if ((k['show'] as Map?)?.isEmpty ?? false) k.remove('show');
    if (k.isEmpty) copy.remove(kindId);
    return PrintLayout(copy);
  }

  PrintLayout withShow(String kindId, String key, bool value) => _with(kindId, (k) {
        final show = Map<String, Object?>.from((k['show'] as Map?) ?? {});
        show[key] = value; // always remembered, so it also wins over older synced settings
        k['show'] = show;
      });

  PrintLayout withMargins(String kindId, List<double?> m) => _with(kindId, (k) {
        if (m.every((v) => v == null)) {
          k.remove('margin');
        } else {
          k['margin'] = m;
        }
      });

  PrintLayout reset(String kindId) => _with(kindId, (k) => k.clear());

  bool isCustom(String kindId) => _data.containsKey(kindId);

  static PrintLayout fromPrefs(DevicePrefs prefs) {
    try {
      final j = jsonDecode(prefs.get('print_layout') ?? '{}') as Map;
      return PrintLayout({for (final e in j.entries) '${e.key}': Map<String, Object?>.from(e.value as Map)});
    } catch (_) {
      return const PrintLayout(); // a damaged value just resets the layout
    }
  }

  Future<void> save(DevicePrefs prefs) => prefs.set('print_layout', jsonEncode(_data));
}
