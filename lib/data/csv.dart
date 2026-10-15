import '../util/format.dart';
import 'repo.dart';

/// Minimal CSV for Excel: quotes, commas, semicolons or tabs, line breaks inside
/// quoted cells. Files are written as UTF-8 with a BOM so Excel shows Persian.
class Csv {
  static const bom = '﻿';

  static String encode(List<List<String>> rows) {
    String cell(String s) => RegExp(r'[",\n\r;]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
    return bom + rows.map((r) => r.map(cell).join(',')).join('\r\n');
  }

  /// Rows of cells; the delimiter (`,` `;` or tab) is guessed from the first line.
  static List<List<String>> decode(String text) {
    var t = text.startsWith(bom) ? text.substring(1) : text;
    if (t.trim().isEmpty) return [];
    final first = t.split(RegExp(r'\r?\n')).first;
    final delim = [',', ';', '\t'].reduce((a, b) => b.allMatches(first).length > a.allMatches(first).length ? b : a);
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    var any = false;
    void endCell() {
      row.add(cell.toString().trim());
      cell.clear();
      any = true;
    }

    void endRow() {
      if (any || cell.isNotEmpty) endCell();
      if (row.any((c) => c.isNotEmpty)) rows.add(row);
      row = [];
      any = false;
    }

    for (var i = 0; i < t.length; i++) {
      final c = t[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < t.length && t[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(c);
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == delim) {
        endCell();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < t.length && t[i + 1] == '\n') i++;
        endRow();
      } else {
        cell.write(c);
      }
    }
    endRow();
    return rows;
  }

  /// A number from a spreadsheet cell: Persian or Latin digits, with or without
  /// thousands separators ("1,250,000", "۱.۲۵۰.۰۰۰", "12.5").
  static double number(String s) {
    var t = enDigits(s).replaceAll(RegExp(r'[\s٬,]'), '').replaceAll('٫', '.');
    if (RegExp(r'^-?\d{1,3}(\.\d{3})+$').hasMatch(t)) t = t.replaceAll('.', ''); // dots as thousands
    return double.tryParse(t) ?? 0;
  }
}

/// Header names accepted when importing (Persian or English), lower-cased.
const _productCols = {
  'name': ['نام', 'نام کالا', 'name', 'product'],
  'code': ['کد', 'کد کالا', 'بارکد', 'code', 'barcode', 'sku'],
  'unit': ['واحد', 'unit'],
  'sale': ['قیمت فروش', 'فروش', 'sale', 'sale_price', 'price'],
  'buy': ['قیمت خرید', 'خرید', 'buy', 'buy_price', 'cost'],
  'opening': ['موجودی اولیه', 'موجودی', 'opening', 'stock', 'qty'],
  'min': ['حداقل موجودی', 'حداقل', 'min', 'min_stock'],
  'note': ['توضیحات', 'یادداشت', 'note', 'description'],
  'group': ['گروه', 'گروه کالا', 'گروه کالایی', 'group', 'category'],
  'usd_sale': ['قیمت ارزی فروش', 'قیمت دلاری فروش', 'فروش دلار', 'usd_sale', 'sale_usd'],
  'usd_buy': ['قیمت ارزی خرید', 'قیمت دلاری خرید', 'خرید دلار', 'usd_buy', 'buy_usd'],
  'rate': ['نرخ دلار', 'نرخ ارز', 'قیمت دلار', 'usd_rate', 'rate', 'dollar'],
  'pct_sale': ['درصد تغییر قیمت فروش', 'درصد تغییر فروش', 'درصد فروش', 'sale_percent', 'sale_pct'],
  'pct_buy': ['درصد تغییر قیمت خرید', 'درصد تغییر خرید', 'درصد خرید', 'buy_percent', 'buy_pct'],
  'pct': ['درصد تغییر قیمت', 'درصد تغییر', 'درصد افزایش', 'percent', 'pct'],
};
const _partyCols = {
  'name': ['نام', 'نام شخص', 'name'],
  'phone': ['تلفن', 'موبایل', 'شماره تلفن', 'phone', 'mobile', 'tel'],
  'opening': ['مانده اول دوره', 'مانده', 'opening', 'balance'],
  'note': ['یادداشت', 'توضیحات', 'note'],
};

class ImportResult {
  ImportResult(this.added, this.updated, this.skipped);
  final int added, updated, skipped;
}

Map<String, int> _columns(List<String> header, Map<String, List<String>> names) {
  final out = <String, int>{};
  for (var i = 0; i < header.length; i++) {
    final h = header[i].trim().toLowerCase();
    for (final e in names.entries) {
      if (!out.containsKey(e.key) && e.value.contains(h)) out[e.key] = i;
    }
  }
  return out;
}

extension CsvRepo on Repo {
  /// Rows (with a header) of a table for spreadsheet export.
  Future<List<List<String>>> exportRows(String what) async {
    String n(num v) => v == v.roundToDouble() ? '${v.round()}' : '$v';
    switch (what) {
      case 'products':
        final groups = {for (final g in await productGroups()) g.id: g.name};
        return [
          ['نام', 'کد', 'واحد', 'قیمت فروش', 'قیمت خرید', 'موجودی اولیه', 'موجودی فعلی', 'حداقل موجودی', 'قیمت ارزی فروش', 'قیمت ارزی خرید', 'توضیحات', 'گروه'],
          for (final p in await products())
            [p.name, p.code, p.unit, '${p.salePrice}', '${p.buyPrice}', n(p.openingStock), n(p.stock), n(p.minStock), n(p.usdSale), n(p.usdBuy), p.note, groups[p.groupId] ?? ''],
        ];
      case 'parties':
        return [
          ['نام', 'تلفن', 'مانده اول دوره', 'مانده فعلی', 'یادداشت'],
          for (final p in await parties()) [p.name, p.phone, '${p.opening}', '${p.balance}', p.note],
        ];
      case 'transactions':
        final accs = {for (final a in await accounts()) a.id: a.name};
        final ps = {for (final p in await parties()) p.id: p.name};
        final cs = {for (final c in await categories()) c.id: c.name};
        return [
          ['تاریخ', 'نوع', 'مبلغ', 'حساب', 'شخص', 'دسته‌بندی', 'توضیحات'],
          for (final t in await transactions())
            [jalaliText(t.date), txKindLabel(t.kind), '${t.amount}', t.kind == 'transfer' ? '${accs[t.accountId] ?? ''} ← ${accs[t.toAccountId] ?? ''}' : (accs[t.accountId] ?? ''), ps[t.partyId] ?? '', cs[t.categoryId] ?? '', t.description],
        ];
      case 'invoices':
        final ps = {for (final p in await parties()) p.id: p.name};
        return [
          ['شماره', 'نوع', 'تاریخ', 'شخص', 'جمع اقلام', 'تخفیف', 'مالیات', 'مبلغ نهایی', 'پرداخت‌شده', 'مانده'],
          for (final i in await invoices()) ['${i.number}', i.info.label, jalaliText(i.date), ps[i.partyId] ?? '', '${i.subtotal}', '${i.discount}', '${i.tax}', '${i.total}', '${i.paid}', '${i.remaining}'],
        ];
    }
    throw ArgumentError(what);
  }

  /// Adds new products and updates the ones that match by code (or by name when
  /// there is no code). Rows without a name are skipped.
  Future<ImportResult> importProducts(List<List<String>> rows) async {
    if (rows.length < 2) return ImportResult(0, 0, 0);
    final col = _columns(rows.first, _productCols);
    if (!col.containsKey('name')) throw const FormatException('ستون «نام» در فایل پیدا نشد.');
    String cell(List<String> r, String k) => col.containsKey(k) && col[k]! < r.length ? r[col[k]!] : '';
    final existing = await products();
    var added = 0, updated = 0, skipped = 0;
    // A dollar rate in the file becomes the company's rate; it is used for the
    // dollar prices of this file and, afterwards, for every dollar-priced product.
    var rate = usdRate;
    var rateFromFile = false;
    if (col.containsKey('rate')) {
      for (final r in rows.skip(1)) {
        final v = Csv.number(cell(r, 'rate'));
        if (v > 0) {
          rate = v;
          rateFromFile = true;
          break;
        }
      }
    }
    final touched = <String>{};
    for (final r in rows.skip(1)) {
      final name = cell(r, 'name');
      if (name.isEmpty) {
        skipped++;
        continue;
      }
      final code = enDigits(cell(r, 'code'));
      final match = existing.where((p) => (code.isNotEmpty && p.code == code) || (code.isEmpty && p.name == name)).firstOrNull;
      var sale = col.containsKey('sale') ? Csv.number(cell(r, 'sale')).round() : (match?.salePrice ?? 0);
      var buy = col.containsKey('buy') ? Csv.number(cell(r, 'buy')).round() : (match?.buyPrice ?? 0);
      var usdSale = col.containsKey('usd_sale') ? Csv.number(cell(r, 'usd_sale')) : (match?.usdSale ?? 0);
      var usdBuy = col.containsKey('usd_buy') ? Csv.number(cell(r, 'usd_buy')) : (match?.usdBuy ?? 0);
      // A dollar price in the file decides the price in the current currency.
      if (rate > 0) {
        if (col.containsKey('usd_sale') && usdSale > 0) sale = Repo.fromUsd(usdSale, rate);
        if (col.containsKey('usd_buy') && usdBuy > 0) buy = Repo.fromUsd(usdBuy, rate);
      }
      // Percent changes: one for both prices, or one for each.
      final both = Csv.number(cell(r, 'pct'));
      final pSale = col.containsKey('pct_sale') && cell(r, 'pct_sale').isNotEmpty ? Csv.number(cell(r, 'pct_sale')) : both;
      final pBuy = col.containsKey('pct_buy') && cell(r, 'pct_buy').isNotEmpty ? Csv.number(cell(r, 'pct_buy')) : both;
      if (pSale != 0) {
        sale = Repo.changeByPercent(sale, pSale);
        usdSale *= 1 + pSale / 100;
      }
      if (pBuy != 0) {
        buy = Repo.changeByPercent(buy, pBuy);
        usdBuy *= 1 + pBuy / 100;
      }
      final id = await saveProduct(
        id: match?.id,
        name: name,
        code: code.isEmpty ? (match?.code ?? '') : code,
        unit: cell(r, 'unit').isEmpty ? (match?.unit ?? 'عدد') : cell(r, 'unit'),
        salePrice: sale,
        buyPrice: buy,
        openingStock: col.containsKey('opening') ? Csv.number(cell(r, 'opening')) : (match?.openingStock ?? 0),
        minStock: col.containsKey('min') ? Csv.number(cell(r, 'min')) : (match?.minStock ?? 0),
        note: col.containsKey('note') ? cell(r, 'note') : (match?.note ?? ''),
        // A group column creates the groups that do not exist yet; without one, groups are left alone.
        groupId: cell(r, 'group').isEmpty ? null : await groupIdByName(cell(r, 'group')),
        usdSale: usdSale,
        usdBuy: usdBuy,
      );
      touched.add(id);
      match == null ? added++ : updated++;
    }
    // Only a rate in the file (no dollar columns): reprice the dollar products that were not in the file too.
    if (rateFromFile) await applyUsdRate(rate);
    return ImportResult(added, updated, skipped);
  }

  /// Adds new people and updates those with the same name.
  Future<ImportResult> importParties(List<List<String>> rows) async {
    if (rows.length < 2) return ImportResult(0, 0, 0);
    final col = _columns(rows.first, _partyCols);
    if (!col.containsKey('name')) throw const FormatException('ستون «نام» در فایل پیدا نشد.');
    String cell(List<String> r, String k) => col.containsKey(k) && col[k]! < r.length ? r[col[k]!] : '';
    final existing = await parties();
    var added = 0, updated = 0, skipped = 0;
    for (final r in rows.skip(1)) {
      final name = cell(r, 'name');
      if (name.isEmpty) {
        skipped++;
        continue;
      }
      final match = existing.where((p) => p.name == name).firstOrNull;
      await saveParty(
        id: match?.id,
        name: name,
        phone: col.containsKey('phone') ? enDigits(cell(r, 'phone')) : (match?.phone ?? ''),
        note: col.containsKey('note') ? cell(r, 'note') : (match?.note ?? ''),
        opening: col.containsKey('opening') ? Csv.number(cell(r, 'opening')).round() : (match?.opening ?? 0),
      );
      match == null ? added++ : updated++;
    }
    return ImportResult(added, updated, skipped);
  }
}
