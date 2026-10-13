import 'package:pdf/pdf.dart';

import '../data/device_prefs.dart';

/// Page set-up shared by every printout. Stored per device (a PC and a phone
/// usually have different printers), so it is not synced.
class PrintSettings {
  const PrintSettings({
    this.paper = 'a4',
    this.landscape = false,
    this.marginMm = 12,
    this.fontScale = 1.0,
    this.rollWidthMm = 80,
  });

  /// `a4` or `a5`.
  final String paper;
  final bool landscape;

  /// Margin on all four sides, in millimetres.
  final double marginMm;

  /// Multiplier for every font size in the printout.
  final double fontScale;

  /// Width of the thermal receipt roll: 58 or 80 mm.
  final int rollWidthMm;

  static const papers = {'a4': 'A4', 'a5': 'A5'};

  PdfPageFormat get format => forPaper(paper, landscape);

  static PdfPageFormat forPaper(String paper, bool landscape) {
    final base = paper == 'a5' ? PdfPageFormat.a5 : PdfPageFormat.a4;
    return landscape ? base.landscape : base;
  }

  PrintSettings copyWith({String? paper, bool? landscape, double? marginMm, double? fontScale, int? rollWidthMm}) =>
      PrintSettings(
        paper: paper ?? this.paper,
        landscape: landscape ?? this.landscape,
        marginMm: marginMm ?? this.marginMm,
        fontScale: fontScale ?? this.fontScale,
        rollWidthMm: rollWidthMm ?? this.rollWidthMm,
      );

  static Future<PrintSettings> load(DevicePrefs prefs) async => PrintSettings.fromPrefs(prefs);

  factory PrintSettings.fromPrefs(DevicePrefs prefs) => PrintSettings(
        paper: prefs.get('print_paper') == 'a5' ? 'a5' : 'a4',
        landscape: prefs.get('print_landscape') == '1',
        marginMm: (double.tryParse(prefs.get('print_margin') ?? '') ?? 12).clamp(0, 40).toDouble(),
        fontScale: (double.tryParse(prefs.get('print_font') ?? '') ?? 1.0).clamp(0.6, 1.6).toDouble(),
        rollWidthMm: prefs.get('print_roll') == '58' ? 58 : 80,
      );

  Future<void> save(DevicePrefs prefs) async {
    await prefs.set('print_paper', paper);
    await prefs.set('print_landscape', landscape ? '1' : '0');
    await prefs.set('print_margin', '$marginMm');
    await prefs.set('print_font', '$fontScale');
    await prefs.set('print_roll', '$rollWidthMm');
  }
}
