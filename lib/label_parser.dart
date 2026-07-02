// ═══════════════════════════════════════════════════════════════════════
// NUTRITION-LABEL PARSER — pure. Reads OCR text off a US Nutrition Facts
// panel and pulls the per-serving numbers + serving grams. Tolerant of OCR
// noise and missing fields; whatever it can't find comes back null so the
// Add screen leaves it blank for the user. Lifted from BodyComp's parser.
//
// US labels are PER SERVING, so the caller converts to per-100 g using the
// serving grams before storing (pantry macros are per-100 g).
// ═══════════════════════════════════════════════════════════════════════

class LabelParse {
  final double? servingGrams;
  final double? calories;
  final double? protein;
  final double? fat;
  final double? carbs;

  const LabelParse({
    this.servingGrams,
    this.calories,
    this.protein,
    this.fat,
    this.carbs,
  });

  /// True if we found at least the calories — enough to be worth pre-filling.
  bool get hasAnything =>
      calories != null || protein != null || fat != null || carbs != null;

  /// Convert the per-serving reading to per-100 g values, when the serving
  /// weight is known. Returns null values that were null to begin with.
  ({double? proteinG, double? calories, double? carbsG, double? fatG})?
      toPer100g() {
    final double? g = servingGrams;
    if (g == null || g <= 0) {
      return null;
    }
    double? per100(double? v) => v == null ? null : v / g * 100;
    return (
      proteinG: per100(protein),
      calories: per100(calories),
      carbsG: per100(carbs),
      fatG: per100(fat),
    );
  }
}

LabelParse parseNutritionLabel(String ocrText) {
  final String t = ocrText.toLowerCase().replaceAll(RegExp(r'[ \t]+'), ' ');

  double? num1(RegExp re) {
    final Match? m = re.firstMatch(t);
    if (m == null) {
      return null;
    }
    return double.tryParse(m.group(1)!);
  }

  // "Calories 230" — explicitly NOT "calories from fat".
  final double? calories =
      num1(RegExp(r'calories(?!\s*from)\s*[:\-]?\s*(\d{1,4})'));

  final double? fat =
      num1(RegExp(r'(?:total\s*)?fat\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g'));
  final double? carbs = num1(
      RegExp(r'(?:total\s*)?carbo?hydrate?s?\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g'));
  final double? protein =
      num1(RegExp(r'protein\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g'));

  // Serving grams: prefer the grams in parentheses next to "serving size".
  double? servingGrams;
  final Match? sg =
      RegExp(r'serving size[^\n]*?\((\d+(?:\.\d+)?)\s*g\)').firstMatch(t);
  if (sg != null) {
    servingGrams = double.tryParse(sg.group(1)!);
  } else {
    final Match? sg2 =
        RegExp(r'serving size\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g\b').firstMatch(t);
    if (sg2 != null) {
      servingGrams = double.tryParse(sg2.group(1)!);
    }
  }

  return LabelParse(
    servingGrams: servingGrams,
    calories: calories,
    protein: protein,
    fat: fat,
    carbs: carbs,
  );
}
