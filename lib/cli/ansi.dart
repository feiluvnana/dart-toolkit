/// ANSI terminal styling extensions on [String].
extension AnsiString on String {
  String get red => '\x1B[31m$this\x1B[0m';
  String get green => '\x1B[32m$this\x1B[0m';
  String get yellow => '\x1B[33m$this\x1B[0m';
  String get blue => '\x1B[34m$this\x1B[0m';
  String get magenta => '\x1B[35m$this\x1B[0m';
  String get cyan => '\x1B[36m$this\x1B[0m';
  String get grey => '\x1B[90m$this\x1B[0m';
  String get bold => '\x1B[1m$this\x1B[0m';
  String get dim => '\x1B[2m$this\x1B[0m';
  String get italic => '\x1B[3m$this\x1B[0m';
  String get underline => '\x1B[4m$this\x1B[0m';
}
