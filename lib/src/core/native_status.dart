/// Where the three native seams report, so a used seam's failure is still
/// visible without importing it (importing a seam compiles its FFI).
///
/// A seam registers on first use. [Native] does not consult these: it loads
/// the engine itself and checks the other libraries by path, so a fresh
/// script with a missing file is not vacuously ok.
library;

/// What one native seam says about its library.
final class NativeCheck {
  /// Whether the library loads right now.
  final bool Function() loads;

  /// Why it does not load, or `null` when it does.
  final String? Function() reason;

  /// Forgets the cached open so the next call looks again (tests only).
  final void Function() reset;

  const NativeCheck(this.loads, this.reason, this.reset);
}

abstract final class NativeStatus {
  static final Map<String, NativeCheck> _checks = {};

  /// Registers [name]'s check (first registration wins).
  static void register(String name, NativeCheck check) => _checks.putIfAbsent(name, () => check);

  /// Every registered check, in registration order.
  static Iterable<MapEntry<String, NativeCheck>> get checks => _checks.entries;
}

/// Test seams for the native libraries.
abstract final class NativeReset {
  /// Forgets every cached native open so the next call looks again.
  static void all() {
    for (final check in NativeStatus.checks) {
      check.value.reset();
    }
  }
}
