/// Personality settings (dials: warmth, formality, humor, etc).
class Personality {
  final Map<String, double> _values = {};

  List<String> get dials => _values.keys.toList();

  double get(String dial) => _values[dial] ?? 0.5;

  void set(String dial, double value) {
    _values[dial] = value.clamp(0.0, 1.0);
  }
}