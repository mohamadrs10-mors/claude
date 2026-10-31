/// An integer in Persian words ("۱٬۲۵۰٬۰۰۰" -> «یک میلیون و دویست و پنجاه هزار»),
/// for amounts written out in full on printouts.
String persianWords(int n) {
  if (n == 0) return 'صفر';
  if (n < 0) return 'منفی ${persianWords(-n)}';
  const ones = ['', 'یک', 'دو', 'سه', 'چهار', 'پنج', 'شش', 'هفت', 'هشت', 'نه', 'ده', 'یازده', 'دوازده', 'سیزده', 'چهارده', 'پانزده', 'شانزده', 'هفده', 'هجده', 'نوزده'];
  const tens = ['', '', 'بیست', 'سی', 'چهل', 'پنجاه', 'شصت', 'هفتاد', 'هشتاد', 'نود'];
  const hundreds = ['', 'صد', 'دویست', 'سیصد', 'چهارصد', 'پانصد', 'ششصد', 'هفتصد', 'هشتصد', 'نهصد'];
  const scales = ['', 'هزار', 'میلیون', 'میلیارد', 'تریلیون', 'کوادریلیون'];

  String below1000(int x) {
    final parts = <String>[];
    if (x >= 100) parts.add(hundreds[x ~/ 100]);
    final r = x % 100;
    if (r >= 20) {
      parts.add(tens[r ~/ 10]);
      if (r % 10 > 0) parts.add(ones[r % 10]);
    } else if (r > 0) {
      parts.add(ones[r]);
    }
    return parts.join(' و ');
  }

  final groups = <String>[];
  var i = 0;
  var rest = n;
  while (rest > 0) {
    final g = rest % 1000;
    if (g > 0) {
      if (i >= scales.length) return n.toString(); // beyond what is spelled out
      groups.insert(0, i == 0 ? below1000(g) : '${below1000(g)} ${scales[i]}');
    }
    rest ~/= 1000;
    i++;
  }
  return groups.join(' و ');
}
