import 'package:flutter/services.dart';

import '../util/format.dart';

/// Live thousands separators for money fields: typing 1250000 shows
/// ۱.۲۵۰.۰۰۰ (the separator is chosen in Settings). Digits are shown in
/// Persian and the cursor stays next to the digit being edited.
///
/// * [decimal]  also accepts a decimal mark (`٫`, `/`, or `.` when the
///   separator is `,`) for foreign-currency amounts and exchange rates.
/// * [negative] allows a leading minus (opening balances).
class ThousandsFormatter extends TextInputFormatter {
  ThousandsFormatter({this.decimal = false, this.negative = false});

  final bool decimal;
  final bool negative;

  bool _isMark(String c) => c == '٫' || c == '/' || (thousandsSep != '.' && c == '.');

  /// Formats [text] as it would appear after typing it.
  String format(String text) => formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length))).text;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = enDigits(newValue.text);
    final cursor = newValue.selection.baseOffset < 0 ? raw.length : newValue.selection.baseOffset.clamp(0, raw.length);
    final intPart = StringBuffer();
    final frac = StringBuffer();
    var neg = false, hasMark = false;
    var counted = 0; // kept characters (digits, mark, minus) before the cursor
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      var kept = false;
      if (RegExp(r'\d').hasMatch(c)) {
        (hasMark ? frac : intPart).write(c);
        kept = true;
      } else if (c == '-' && negative && !neg && intPart.isEmpty && !hasMark) {
        neg = true;
        kept = true;
      } else if (decimal && !hasMark && _isMark(c)) {
        hasMark = true;
        kept = true;
      }
      if (kept && i < cursor) counted++;
    }
    var digits = intPart.toString().replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final stripped = intPart.length - digits.length;
    // Dropping leading zeros moves the cursor too.
    if (stripped > 0) counted = (counted - stripped).clamp(0, 1 << 30);
    final out = StringBuffer();
    if (neg) out.write('-');
    out.write(digits.isEmpty ? '' : groupDigits(digits));
    if (hasMark) out.write('٫$frac');
    final text = faDigits(out.toString());

    // Put the cursor after the same number of kept characters.
    var pos = 0, seen = 0;
    while (pos < text.length && seen < counted) {
      final c = text[pos];
      if (c != thousandsSep) seen++;
      pos++;
    }
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: pos));
  }
}
