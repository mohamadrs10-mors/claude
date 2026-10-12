import 'package:pdf/pdf.dart';

import '../data/db.dart';

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

  static Future<PrintSettings> load(AppDb db) async {
    final paper = await db.getMeta('print_paper');
    return PrintSettings(
      paper: paper == 'a5' ? 'a5' : 'a4',
      landscape: (await db.getMeta('print_landscape')) == '1',
      marginMm: (double.tryParse(await db.getMeta('print_margin') ?? '') ?? 12).clamp(0, 40).toDouble(),
      fontScale: (double.tryParse(await db.getMeta('print_font') ?? '') ?? 1.0).clamp(0.6, 1.6).toDouble(),
      rollWidthMm: (await db.getMeta('print_roll')) == '58' ? 58 : 80,
    );
  }

  Future<void> save(AppDb db) async {
    await db.setMeta('print_paper', paper);
    await db.setMeta('print_landscape', landscape ? '1' : '0');
    await db.setMeta('print_margin', '$marginMm');
    await db.setMeta('print_font', '$fontScale');
    await db.setMeta('print_roll', '$rollWidthMm');
  }
}
