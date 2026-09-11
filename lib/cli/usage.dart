// Rendering a usage block, wrapped to the terminal.
//
// `_usage` is the one implementation behind `Cli.usage`, `Cli.help`,
// `CliAccessor.usage` and `CliAccessor.help`. The four *parameter lists* are
// still written out four times, and Dart offers no way not to: a `Usage`
// value object would remove the repetition and turn
// `cli.usage(syntax: 'x')` into `cli.usage(const Usage(syntax: 'x'))` at
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
  String? desc,
  Map<String, _Decl> declarations = const {},
  Map<String, Command> children = const {},
  Map<String, String>? flags,
  Map<String, String>? options,
}) {
  final allflags = <String, String>{...?flags};
  final alloptions = <String, String>{...?options};
  final allcommands = <String, String>{};

  for (final entry in declarations.entries) {
    final name = entry.key;
    final decl = entry.value;
    final label = '${decl.alias != null ? '-${decl.alias}, ' : '    '}--$name';
    if (decl.flag) {
      final def = decl.def == true ? ' [default: true]' : '';
      allflags[label] = '${decl.desc}$def';
      continue;
    }
    // `required` is only worth printing when nothing else can supply a value.
    final required = decl.required && decl.def == null ? ' (required)' : '';
    final def = decl.def != null ? ' [default: ${decl.def}]' : '';
    final env = decl.env != null ? ' [env: ${decl.env}]' : '';
    final allowed = decl.allowed != null ? ' (${decl.allowed!.join('|')})' : '';
    alloptions['$label <value>'] = '${decl.desc}$allowed$required$env$def';
  }
  for (final child in children.values) {
    allcommands[child.name] = child.desc;
  }

  final buffer = StringBuffer();
  final width = ConsoleWriter().width.clamp(40, 100);
  if (desc != null && desc.isNotEmpty) buffer.writeln('$desc\n');
  if (syntax != null && syntax.isNotEmpty) buffer.writeln('Usage: $syntax\n');

  final labels = [...allcommands.keys, ...allflags.keys, ...alloptions.keys];
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

  section('Commands', allcommands);
  section('Flags', allflags);
  section('Options', alloptions);
  return buffer.toString().trimRight();
}

/// Splits [text] into lines of at most [width] columns, breaking on spaces.
///
/// Measured with `String.width` rather than by code units, the way every other
/// box this library draws is: a CJK ideograph is one code unit and two
/// columns, an emoji is two code units and two columns, and a `desc:` holding
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
