import 'dart:io';
import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';

class ExcelEngine {
  static final ExcelEngine instance = ExcelEngine._init();
  ExcelEngine._init();

  // Mapping of (day, exercise, sub_category, circuit) -> row index (0-based)
  // Python rows were 1-indexed; we subtract 1 here for Dart's 0-based index.
  static final Map<String, int> _rowMapping = _buildRowMapping();

  static Map<String, int> _buildRowMapping() {
    final Map<String, int> mapping = {};

    // Tuesday (ВТ)
    for (int c = 1; c <= 3; c++) {
      mapping["tuesday|глубокие отжимания||$c"] = 5 + c - 2; // Row 5, 6, 7
      mapping["tuesday|отжимания уголком||$c"] = 8 + c - 2; // Row 8, 9, 10
      mapping["tuesday|алмазные отжимания||$c"] = 12 + c - 2; // Row 12, 13, 14
      mapping["tuesday|отжимания на возвы-ти||$c"] = 15 + c - 2; // Row 15, 16, 17
    }

    // Thursday (ЧТ)
    for (int c = 1; c <= 3; c++) {
      mapping["thursday|выпады|левая нога|$c"] = 19 + c - 2; // Row 19, 20, 21
      mapping["thursday|выпады|правая нога|$c"] = 22 + c - 2; // Row 22, 23, 24
      mapping["thursday|приседания обычные||$c"] = 25 + c - 2; // Row 25, 26, 27
    }

    for (int c = 1; c <= 2; c++) {
      mapping["thursday|подъемы на носках|левая нога|$c"] = 29 + c - 2; // Row 29, 30
      mapping["thursday|подъемы на носках|правая нога|$c"] = 31 + c - 2; // Row 31, 32
      mapping["thursday|пресс (поднятие ног)||$c"] = 33 + c - 2; // Row 33, 34
    }

    // Friday (СБ)
    mapping["friday|нега-ые подтягивания (сек)||\$1"] = 36 - 1; // Row 36
    mapping["friday|нега-ые подтягивания (сек)||\$2"] = 38 - 1; // Row 38
    mapping["friday|нега-ые подтягивания (сек)||\$3"] = 40 - 1; // Row 40
    mapping["friday|негативные подтягивания||\$1"] = 36 - 1;
    mapping["friday|негативные подтягивания||\$2"] = 38 - 1;
    mapping["friday|негативные подтягивания||\$3"] = 40 - 1;

    for (int c = 1; c <= 3; c++) {
      mapping["friday|тяга гантелей в наклоне|левая рука|$c"] = 42 + c - 2; // Row 42, 43, 44
      mapping["friday|тяга гантелей в наклоне|правая рука|$c"] = 45 + c - 2; // Row 45, 46, 47
      mapping["friday|подтягивания узким хватом||$c"] = 48 + c - 2; // Row 48, 49, 50
    }

    return mapping;
  }

  // Locates the local persistent Excel file on the smartphone
  Future<File> getLocalExcelFile() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = "${directory.path}/Новая таблица.xlsx";
    return File(path);
  }

  // Prepares the excel file: if not exists, copies it from assets or templates
  Future<void> ensureExcelExists(List<int> defaultTemplateBytes) async {
    final file = await getLocalExcelFile();
    if (!await file.exists()) {
      await file.create(recursive: true);
      await file.writeAsBytes(defaultTemplateBytes);
    }
  }

  // Updates the spreadsheet locally with workout results
  Future<File> saveWorkoutToExcel({
    required String day,
    required List<Map<String, dynamic>> results,
  }) async {
    final file = await getLocalExcelFile();
    if (!await file.exists()) {
      throw Exception("Excel file does not exist locally. Please import it first.");
    }

    final Uint8List bytes = await file.readAsBytes();
    final Excel excel = Excel.decodeBytes(bytes);

    // Get active table / sheet name
    final String sheetName = excel.tables.keys.first;
    final Sheet sheet = excel.tables[sheetName]!;

    final DateTime today = DateTime.now();
    // Monday of today's ISO week
    final DateTime todayMonday = today.subtract(Duration(days: today.weekday - 1));

    int targetColIdx = 5; // Start searching at column index 5 (which is 6th column, i.e., Col F)
    final String todayDateStr = "${today.day.toString().padLeft(2, '0')}.${today.month.toString().padLeft(2, '0')}";

    while (true) {
      // Fetch cell at Row 2 (0-indexed 3rd row)
      final Data? cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: targetColIdx, rowIndex: 2));
      final dynamic cellVal = cell?.value;

      if (cellVal == null) {
        // Write today's date as column header
        sheet.updateCell(
          CellIndex.indexByColumnRow(columnIndex: targetColIdx, rowIndex: 2),
          TextCellValue(todayDateStr),
        );
        break;
      } else {
        final String valStr = cellVal.toString().trim();
        final List<String> parts = valStr.split(RegExp(r'[,/;+\s]+'));
        bool sameWeek = false;

        for (var p in parts) {
          p = p.trim();
          if (p.isEmpty) continue;
          try {
            final List<String> dateParts = p.split('.');
            if (dateParts.length >= 2) {
              final int dayPart = int.parse(dateParts[0]);
              final int monthPart = int.parse(dateParts[1]);
              final DateTime parsedDate = DateTime(today.year, monthPart, dayPart);
              final DateTime parsedMonday = parsedDate.subtract(Duration(days: parsedDate.weekday - 1));

              if (DateTime(parsedMonday.year, parsedMonday.month, parsedMonday.day) == 
                  DateTime(todayMonday.year, todayMonday.month, todayMonday.day)) {
                sameWeek = true;
                break;
              }
            }
          } catch (_) {}
        }

        if (sameWeek) {
          if (!parts.contains(todayDateStr)) {
            final String newVal = "$valStr, $todayDateStr";
            sheet.updateCell(
              CellIndex.indexByColumnRow(columnIndex: targetColIdx, rowIndex: 2),
              TextCellValue(newVal),
            );
          }
          break;
        }
      }
      targetColIdx++;
    }

    int writtenCount = 0;

    for (var r in results) {
      final String ex = (r['exercise'] as String? ?? '').toLowerCase().trim();
      final String sub = (r['sub_category'] as String? ?? '').toLowerCase().trim();
      final int circuit = r['circuit'] as int? ?? 1;
      final int value = r['value'] as int? ?? 0;

      // Construct look up keys
      final String primaryKey = "$day|$ex|$sub|$circuit";
      final String fallbackKey = "$day|$ex||$circuit";

      int? targetRowIdx;
    if (_rowMapping.containsKey(primaryKey)) {
      targetRowIdx = _rowMapping[primaryKey];
    } else if (_rowMapping.containsKey(fallbackKey)) {
      targetRowIdx = _rowMapping[fallbackKey];
    }

    // Safety Fallback: Search by name if mapping fails or to verify
    if (targetRowIdx == null) {
      targetRowIdx = _findRowByExerciseName(sheet, ex, sub, circuit);
    }

    if (targetRowIdx != null) {
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: targetColIdx, rowIndex: targetRowIdx),
        IntCellValue(value),
      );
      writtenCount++;
    }
  }

  // Save and overwrite the file bytes
  final List<int>? fileOut = excel.encode();
  if (fileOut != null) {
    await file.writeAsBytes(fileOut, flush: true);
  }

  print("SUCCESSFUL EXCEL UPDATE: Saved $writtenCount cells in column ${targetColIdx + 1}");
  return file;
}

// Helper to find a row index by scanning the first few columns for the exercise name
int? _findRowByExerciseName(Sheet sheet, String exercise, String sub, int circuit) {
  // We search in the first 3 columns for a match
  // Row scanning limit to avoid performance issues
  for (int r = 0; r < 100; r++) {
    for (int c = 0; c < 3; c++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
      final val = cell.value?.toString().toLowerCase() ?? '';
      
      if (val.contains(exercise)) {
        // If there's a sub-category, check it too
        if (sub.isNotEmpty) {
          bool subFound = false;
          // Check same row or next few rows for sub-category
          for (int subR = r; subR < r + 5; subR++) {
            for (int subC = 0; subC < 3; subC++) {
              final subCell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: subC, rowIndex: subR));
              if (subCell.value?.toString().toLowerCase().contains(sub) == true) {
                // Now check for circuit match in that area
                // (This is a simplified heuristic)
                return subR; 
              }
            }
          }
        }
        return r;
      }
    }
  }
  return null;
}
}
