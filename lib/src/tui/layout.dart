/// Geometry for layout: rectangles and flex splitting. Pure data; the native
/// crate never lays out (Dart is the single source of truth).
library;

/// A cell rectangle: origin ([x], [y]), size ([w] × [h]).
final class Rect {
  final int x, y, w, h;
  const Rect(this.x, this.y, this.w, this.h);

  /// Whether ([px], [py]) lies inside.
  bool contains(int px, int py) => px >= x && py >= y && px < x + w && py < y + h;

  /// Inset by [pad] on every side (clamped at zero size).
  Rect inset(int pad) {
    final w2 = w - pad * 2;
    final h2 = h - pad * 2;
    return Rect(x + pad, y + pad, w2 < 0 ? 0 : w2, h2 < 0 ? 0 : h2);
  }

  @override
  bool operator ==(Object other) => other is Rect && other.x == x && other.y == y && other.w == w && other.h == h;

  @override
  int get hashCode => Object.hash(x, y, w, h);

  @override
  String toString() => 'Rect($x,$y ${w}x$h)';
}

/// Splits [total] cells among [flexes] proportionally (largest remainder, so
/// the parts always sum to [total]). A zero total answers zeros.
List<int> flexSplit(int total, List<int> flexes) {
  if (total <= 0 || flexes.isEmpty) return List<int>.filled(flexes.length, 0);
  final sum = flexes.fold(0, (a, b) => a + (b < 0 ? 0 : b));
  if (sum <= 0) return List<int>.filled(flexes.length, 0);
  final sizes = List<int>.filled(flexes.length, 0);
  final remainders = List<double>.filled(flexes.length, 0);
  var assigned = 0;
  for (var i = 0; i < flexes.length; i++) {
    final exact = total * (flexes[i] < 0 ? 0 : flexes[i]) / sum;
    sizes[i] = exact.floor();
    remainders[i] = exact - sizes[i];
    assigned += sizes[i];
  }
  var left = total - assigned;
  while (left > 0) {
    var best = 0;
    for (var i = 1; i < remainders.length; i++) {
      if (remainders[i] > remainders[best]) best = i;
    }
    sizes[best]++;
    remainders[best] = -1;
    left--;
  }
  return sizes;
}
