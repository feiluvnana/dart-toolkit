// Rendering a usage block, wrapped to the terminal.
//
// `_usage` is the one implementation behind `Cli.usage`, `Cli.help`,
// `CliParser.usage` and `CliParser.help`. The four *parameter lists* are
// still written out four times, and Dart offers no way not to: a `Usage`
// value object would remove the repetition and turn
// `parser.usage(syntax: 'x')` into a `Usage` value object at
// every call site, which is worse everywhere it is read. The repetition is
// the cheaper of the two, and it is named here so the next sweep does not
// rediscover it as a finding.

part of 'cli.dart';

// ============================================================================
// USAGE FORMATTING
// ============================================================================

// ============================================================================
// USAGE FORMATTING
// ============================================================================

/// Renders a usage block, wrapped to the terminal.
String _usage({
  String? syntax,
  String? description,
  Map<String, _Decl> declarations = const {},
  Map<String, Command> children = const {},
  Map<String, String>? flags,
  Map<String, String>? options,
}) {
  final allFlags = <String, String>{...?flags};
  final allOptions = <String, String>{...?options};
  final allCommands = <String, String>{};

  for (final entry in declarations.entries) {
    final name = entry.key;
    final decl = entry.value;
    final label = '${decl.abbr != null ? '-${decl.abbr}, ' : '    '}--$name';
    if (decl.flag) {
      final defaultsTo = decl.defaultsTo == true ? ' [default: true]' : '';
      allFlags[label] = '${decl.help}$defaultsTo';
      continue;
    }
    // `required` is only worth printing when nothing else can supply a value.
    final required = decl.required && decl.defaultsTo == null
        ? ' (required)'
        : '';
    final defaultsTo = decl.defaultsTo != null
        ? ' [default: ${decl.defaultsTo}]'
        : '';
    final env = decl.env != null ? ' [env: ${decl.env}]' : '';
    final allowed = decl.allowed != null ? ' (${decl.allowed!.join('|')})' : '';
    allOptions['$label <value>'] =
        '${decl.help}$allowed$required$env$defaultsTo';
  }
  for (final child in children.values) {
    allCommands[child.name] = child.help;
  }

  final buffer = StringBuffer();
  final width = ConsoleWriter().width.clamp(40, 100);
  if (description != null && description.isNotEmpty) {
    buffer.writeln('$description\n');
  }
  if (syntax != null && syntax.isNotEmpty) buffer.writeln('Usage: $syntax\n');

  final labels = [...allCommands.keys, ...allFlags.keys, ...allOptions.keys];
  final column = labels.isEmpty
      ? 24
      : labels
            .map((label) => label.width)
            .reduce((a, b) => a > b ? a : b)
            .clamp(12, 34);

  void section(String title, Map<String, String> entries) {
    if (entries.isEmpty) return;
    buffer.writeln('$title:');
    entries.forEach((label, text) {
      final lines = _wrap(text.trim(), width - column - 4);
      buffer.writeln('  ${label.padRight(column)}  ${lines.first}'.trimRight());
      for (final line in lines.skip(1)) {
        buffer.writeln('  ${' ' * column}  $line');
      }
    });
    buffer.writeln();
  }

  section('Commands', allCommands);
  section('Flags', allFlags);
  section('Options', allOptions);
  return buffer.toString().trimRight();
}

/// Splits [text] into lines of at most [width] columns, breaking on spaces.
///
/// Measured with `String.width` rather than by code units, the way every other
/// box this library draws is: a CJK ideograph is one code unit and two
/// columns, an emoji is two code units and two columns, and a `help:` holding
/// either wrapped past the edge of the terminal it was being wrapped for.
List<String> _wrap(String text, int width) {
  if (text.isEmpty) return const [''];
  if (width < 8) return [text];
  final lines = <String>[];
  var line = '';
  var columns = 0;
  for (final word in text.split(' ')) {
    final wordWidth = word.width;
    if (line.isEmpty) {
      line = word;
      columns = wordWidth;
    } else if (columns + 1 + wordWidth <= width) {
      line = '$line $word';
      columns += 1 + wordWidth;
    } else {
      lines.add(line);
      line = word;
      columns = wordWidth;
    }
  }
  if (line.isNotEmpty) lines.add(line);
  return lines;
}
