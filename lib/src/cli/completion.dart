part of '../../cli.dart';

/// The completion script for [root] in [shell]: what `app --completion bash` prints.
///
/// Built from the declared tree.
String _completion(CliCommand root, String? shell) => switch (shell) {
  'bash' => _bash(root),
  'zsh' => _zsh(root),
  'fish' => _fish(root),
  'powershell' => _powershell(root),
  _ => throw UsageException(
    '--completion takes bash, zsh, fish or powershell${shell == null ? '' : ', not "$shell"'}.',
  ),
};

/// Every command under [root], root first, each with its path of names.
Iterable<(String, CliCommand)> _tree(CliCommand root, [String? path]) sync* {
  final here = path ?? root.name;
  yield (here, root);
  for (final sub in root._subcommands.values) {
    yield* _tree(sub, '$here ${sub.name}');
  }
}

/// Each alias's path under [root] and the path of the command it names: `app rm` → `app remove`.
Iterable<(String, String)> _aliasPaths(CliCommand root) sync* {
  for (final (path, command) in _tree(root)) {
    for (final sub in command._subcommands.values) {
      for (final alias in sub.aliases) {
        yield ('$path $alias', '$path ${sub.name}');
      }
    }
  }
}

/// The options [command] answers to, nearer first, each with the spellings that reach it.
Iterable<(CliValue<Object?>, List<String>)> _reachable(CliCommand command) sync* {
  for (final option in command._chain.expand((c) => c._options)) {
    if (command._findOption(option.name) != option) continue;
    yield (
      option,
      [
        '--${option.name}',
        if (!option._takesValue && option._or == true) '--no-${option.name}',
        if (option._short case final a? when command._findShort(a) == option) '-$a',
      ],
    );
  }
}

/// What [command] answers to beside its options, as spellings and help: the built-ins it has
/// not given to a declared name (`--completion` is offered on its own).
Iterable<(List<String>, String)> _builtIns(CliCommand command) sync* {
  for (final (long, short, help) in command._builtIns) {
    if (long == 'completion' || command._findOption(long) != null) continue;
    yield ([if (short != null && command._findShort(short) == null) '-$short', '--$long'], help);
  }
}

/// Whether [command] answers `--completion`: the root of a [Cli] that has not taken the name.
bool _completes(CliCommand command) =>
    command._parent == null && command is Cli && command._findOption('completion') == null;

/// The values [command]'s arguments are restricted to, each once.
Iterable<String> _argChoices(CliCommand command) => {for (final arg in command._args) ...?arg._choices?.map(_label)};

/// [words] as one `compgen -W` list, each kept whole: newline-separated (the script sets
/// `IFS` to a newline, so `'dry run'` is one word) in ANSI-C quotes, so `'` and `$` stay literal.
String _bashWords(Iterable<String> words) =>
    "\$'${words.map((w) => w.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', ' ')).join(r'\n')}'";

final _nonWordChar = RegExp(r'\W');

String _bash(CliCommand root) {
  final fn = '_${root.name.replaceAll(_nonWordChar, '_')}_completion';
  final tree = _tree(root).toList();
  final out = StringBuffer()
    ..writeln('$fn() {')
    ..writeln('  local cur="\${COMP_WORDS[COMP_CWORD]}" prev="\${COMP_WORDS[COMP_CWORD-1]}" path="${root.name}" i')
    ..writeln(
      '  if [[ "\$cur" == *=* ]]; then prev="\${cur%%=*}" cur="\${cur#*=}"; elif [[ "\$prev" == "=" ]]; then prev="\${COMP_WORDS[COMP_CWORD-2]}"; fi',
    )
    // A reply with a space in it is one word: escaped as it goes on the command line.
    ..writeln(r"  local IFS=$'\n'")
    ..writeln('  for ((i = 1; i < COMP_CWORD; i++)); do')
    ..writeln('    case "\$path \${COMP_WORDS[i]}" in');
  final nested = [for (final (path, _) in tree.skip(1)) '"$path"'];
  if (nested.isNotEmpty) out.writeln('      ${nested.join('|')}) path="\$path \${COMP_WORDS[i]}" ;;');
  for (final (alias, target) in _aliasPaths(root)) {
    out.writeln('      "$alias") path="$target" ;;');
  }
  out
    ..writeln('    esac')
    ..writeln('  done')
    ..writeln('  case "\$path:\$prev" in');
  if (_completes(root)) {
    out.writeln(
      '    "${root.name}:--completion") COMPREPLY=(\$(compgen -W "bash zsh fish powershell" -- "\$cur")); return ;;',
    );
  }
  for (final (path, command) in tree) {
    for (final (option, spellings) in _reachable(command)) {
      if (!option._takesValue) continue;
      final when = spellings.map((s) => '"$path:$s"').join('|');
      final choices = option._choices?.map(_label);
      out.writeln(switch (choices) {
        null when _noFiles(option) => '    $when) compopt +o default 2>/dev/null; return ;;',
        // Any value: an empty reply, so `-o default` offers file names.
        null => '    $when) return ;;',
        _ => '    $when) COMPREPLY=(\$(compgen -W ${_bashWords(choices)} -- "\$cur" | sed \'s/ /\\\\ /g\')); return ;;',
      });
    }
  }
  out
    ..writeln('  esac')
    ..writeln('  case "\$path" in');
  for (final (path, command) in tree) {
    final words = [
      ...command._named.keys,
      ..._argChoices(command),
      for (final (_, spellings) in _reachable(command)) ...spellings,
      for (final (spellings, _) in _builtIns(command)) ...spellings,
      if (_completes(command)) '--completion',
    ];
    out.writeln('    "$path") COMPREPLY=(\$(compgen -W ${_bashWords(words)} -- "\$cur" | sed \'s/ /\\\\ /g\')) ;;');
  }
  return (out
        ..writeln('  esac')
        ..writeln('}')
        ..writeln('complete -o default -F $fn ${root.name}'))
      .toString();
}

/// [text] in zsh single quotes.
String _zshQuote(String text) => "'${text.replaceAll("'", r"'\''")}'";

/// [text] inside an `_arguments` spec's `[help]` or `:message:`.
String _zshHelp(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAll('[', r'\[')
    .replaceAll(']', r'\]')
    .replaceAll(':', r'\:')
    .replaceAll('\n', ' ');

/// [text] as one word of an `_arguments` `(a b c)` or `((a\:help))` list.
String _zshWord(String text) => _zshHelp(text).replaceAll(' ', r'\ ').replaceAll('(', r'\(').replaceAll(')', r'\)');

/// How zsh completes a value read by [value]: one of its choices, nothing for a number, else a file.
String _zshAction(CliValue<Object?> value) => switch (value._choices) {
  final choices? => '(${choices.map((c) => _zshWord(_label(c))).join(' ')})',
  null when _noFiles(value) => ' ',
  null => '_files',
};

/// The `_arguments` specs of [command]: every spelling of every option it answers to, its
/// built-ins, and its positionals — a subcommand, or each argument in order.
List<String> _zshSpecs(CliCommand command) {
  final specs = <String>[];
  void option(List<String> spellings, String help, {String? value, bool many = false}) {
    // `-n+` and `--top=` take the value attached or as the next word.
    final forms = [for (final s in spellings) value == null ? s : '$s${s.startsWith('--') ? '=' : '+'}'];
    final tail = '[${_zshHelp(help)}]${value ?? ''}';
    final group = many || spellings.length < 2 ? (many ? "'*'" : '') : _zshQuote('(${spellings.join(' ')})');
    specs.add(
      forms.length == 1 ? '$group${_zshQuote('${forms.single}$tail')}' : "$group{${forms.join(',')}}${_zshQuote(tail)}",
    );
  }

  for (final (o, spellings) in _reachable(command)) {
    final names = [
      for (final s in spellings)
        if (!s.startsWith('--no-')) s,
    ];
    final value = o._takesValue ? ':${_zshHelp(o.name)}:${_zshAction(o)}' : null;
    option(names, o.help, value: value, many: o._isMany);
    if (spellings.contains('--no-${o.name}')) option(['--no-${o.name}'], o.help);
  }
  for (final (spellings, help) in _builtIns(command)) {
    option(spellings, help);
  }
  if (_completes(command)) {
    option(['--completion'], 'Print a completion script', value: ':shell:(bash zsh fish powershell)');
  }
  if (command._subcommands.isNotEmpty) {
    final items = [
      for (final MapEntry(key: name, value: sub) in command._named.entries) '${_zshWord(name)}\\:${_zshWord(sub.help)}',
    ];
    specs.add(_zshQuote('1:command:((${items.join(' ')}))'));
  } else if (command._args.isEmpty) {
    specs.add(_zshQuote('*:file:_files'));
  } else {
    for (final (i, arg) in command._args.indexed) {
      specs.add(_zshQuote('${arg._variadic ? '*' : i + 1}:${_zshHelp(arg.name)}:${_zshAction(arg)}'));
    }
  }
  return specs;
}

/// Walks the words to the command they name, as the bash script does, then hands `_arguments`
/// that command's specs with the words from its name on.
String _zsh(CliCommand root) {
  final fn = '_${root.name.replaceAll(_nonWordChar, '_')}';
  final tree = _tree(root).toList();
  final out = StringBuffer()
    ..writeln('#compdef ${root.name}')
    ..writeln('$fn() {')
    // `path` is zsh's own: the array tied to PATH.
    ..writeln('  local cmd_path=${_zshQuote(root.name)} first=1 i');
  if (tree.length > 1) {
    out
      ..writeln('  for ((i = 2; i < CURRENT; i++)); do')
      ..writeln('    case "\$cmd_path \${words[i]}" in')
      ..writeln('      ${[for (final (path, _) in tree.skip(1)) _zshQuote(path)].join('|')})')
      ..writeln('        cmd_path="\$cmd_path \${words[i]}" first=\$i ;;');
    for (final (alias, target) in _aliasPaths(root)) {
      out.writeln('      ${_zshQuote(alias)}) cmd_path=${_zshQuote(target)} first=\$i ;;');
    }
    out
      ..writeln('    esac')
      ..writeln('  done')
      ..writeln('  words=("\${(@)words[first,-1]}")')
      ..writeln('  (( CURRENT -= first - 1 ))');
  }
  out.writeln('  case \$cmd_path in');
  for (final (path, command) in tree) {
    out
      ..writeln('    ${_zshQuote(path)})')
      ..writeln('      _arguments -s -S : \\')
      ..writeln(_zshSpecs(command).map((s) => '        $s').join(' \\\n'))
      ..writeln('      ;;');
  }
  return (out
        ..writeln('  esac')
        ..writeln('}')
        ..writeln('compdef $fn ${root.name}'))
      .toString();
}

String _fish(CliCommand root) {
  String quote(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
  // fish reads `-a` as a list of words, so a space inside one is escaped.
  String words(Iterable<String> all) => quote(all.map((w) => w.replaceAll(' ', r'\ ')).join(' '));
  final fn = '__${root.name.replaceAll(_nonWordChar, '_')}_path';
  final tree = _tree(root).toList();
  final out = StringBuffer()
    ..writeln('function $fn')
    ..writeln('  set -l path ${root.name}')
    ..writeln('  for w in (commandline -opc)[2..-1]')
    ..writeln('    switch "\$path \$w"');
  final nested = [for (final (path, _) in tree.skip(1)) quote(path)];
  if (nested.isNotEmpty) {
    out
      ..writeln('      case ${nested.join(' ')}')
      ..writeln('        set path "\$path \$w"');
  }
  for (final (alias, target) in _aliasPaths(root)) {
    out
      ..writeln('      case ${quote(alias)}')
      ..writeln('        set path ${quote(target)}');
  }
  out
    ..writeln('    end')
    ..writeln('  end')
    ..writeln('  echo \$path')
    ..writeln('end');
  for (final (path, command) in tree) {
    final at = quote('test ($fn) = ${quote(path)}');
    final complete = 'complete -c ${root.name} -n $at';
    for (final MapEntry(key: name, value: sub) in command._named.entries) {
      out.writeln('$complete -f -a ${quote(name)} -d ${quote(sub.help)}');
    }
    if (_argChoices(command) case final choices when choices.isNotEmpty) {
      out.writeln('$complete -f -a ${words(choices)}');
    }
    for (final (spellings, help) in _builtIns(command)) {
      out.writeln(
        '$complete -l ${spellings.last.substring(2)} -d ${quote(help)}${spellings.length > 1 ? ' -s h' : ''}',
      );
    }
    if (_completes(command)) {
      out.writeln("$complete -l completion -d ${quote('Print a completion script')} -xa 'bash zsh fish powershell'");
    }
    for (final (option, spellings) in _reachable(command)) {
      final hasShort = spellings.any((s) => !s.startsWith('--'));
      final parts = [
        '$complete -l ${option.name}',
        if (hasShort) '-s ${option._short}',
        if (option.help.isNotEmpty) '-d ${quote(option.help)}',
        if (option._takesValue)
          switch (option._choices) {
            final choices? => '-xa ${words(choices.map(_label))}',
            null when _noFiles(option) => '-x',
            null => '-r',
          },
      ];
      out.writeln(parts.join(' '));
      if (spellings.contains('--no-${option.name}')) {
        out.writeln('$complete -l no-${option.name}${option.help.isEmpty ? '' : ' -d ${quote(option.help)}'}');
      }
    }
  }
  return out.toString();
}

/// [text] as a PowerShell single-quoted literal.
String _psQuote(String text) => "'${text.replaceAll("'", "''")}'";

/// A native argument completer: `app --completion powershell | Out-String | Invoke-Expression`.
/// Walks the typed words to the command they name, as the bash script does; a value is completed
/// from its choices, anything else from the command's words. No reply lets PowerShell offer paths.
String _powershell(CliCommand root) {
  final tree = _tree(root).toList();
  String list(Iterable<String> words) => '@(${words.map(_psQuote).join(', ')})';
  final out = StringBuffer()
    ..writeln('Register-ArgumentCompleter -Native -CommandName ${_psQuote(root.name)} -ScriptBlock {')
    ..writeln(r'  param($wordToComplete, $commandAst, $cursorPosition)')
    ..writeln(r'  $words = @($commandAst.CommandElements | ForEach-Object { $_.Extent.Text })')
    ..writeln(r"  $done = if ($wordToComplete -eq '') { $words.Count } else { $words.Count - 1 }")
    ..writeln('  \$path = ${_psQuote(root.name)}; \$prev = \'\'; \$cur = \$wordToComplete; \$lead = \'\'')
    ..writeln(r"  if ($cur -match '^(--[^=]+)=(.*)$') { $prev = $Matches[1]; $cur = $Matches[2]; $lead = $prev + '=' }")
    ..writeln(r'  for ($i = 1; $i -lt $done; $i++) {')
    ..writeln(r'    $next = "$path $($words[$i])"')
    ..writeln(r'    switch -exact ($next) {');
  for (final (path, _) in tree.skip(1)) {
    out.writeln('      ${_psQuote(path)} { \$path = \$next }');
  }
  for (final (alias, target) in _aliasPaths(root)) {
    out.writeln('      ${_psQuote(alias)} { \$path = ${_psQuote(target)} }');
  }
  out
    ..writeln('    }')
    ..writeln(r"    if ($lead -eq '') { $prev = $words[$i] }")
    ..writeln('  }')
    ..writeln(r'  $candidates = switch -exact ("${path}:$prev") {');
  if (_completes(root)) {
    out.writeln("    ${_psQuote('${root.name}:--completion')} { ${list(['bash', 'zsh', 'fish', 'powershell'])} }");
  }
  for (final (path, command) in tree) {
    for (final (option, spellings) in _reachable(command)) {
      if (!option._takesValue) continue;
      final choices = option._choices?.map(_label);
      for (final spelling in spellings) {
        // Any value but a choice: nothing, so PowerShell offers paths (or nothing, for a number).
        out.writeln('    ${_psQuote('$path:$spelling')} { ${choices == null ? '@()' : list(choices)} }');
      }
    }
  }
  out.writeln(r'    default { switch -exact ($path) {');
  for (final (path, command) in tree) {
    final words = [
      ...command._named.keys,
      ..._argChoices(command),
      for (final (_, spellings) in _reachable(command)) ...spellings,
      for (final (spellings, _) in _builtIns(command)) ...spellings,
      if (_completes(command)) '--completion',
    ];
    out.writeln('      ${_psQuote(path)} { ${list(words)} }');
  }
  return (out
        ..writeln('    } }')
        ..writeln('  }')
        ..writeln(r'''  $candidates | Where-Object { $_ -like "$cur*" } | ForEach-Object {''')
        ..writeln(r'''    $text = if ($_ -match '\s') { "'" + ($_ -replace "'", "''") + "'" } else { $_ }''')
        ..writeln(r"    [System.Management.Automation.CompletionResult]::new($lead + $text, $_, 'ParameterValue', $_)")
        ..writeln('  }')
        ..writeln('}'))
      .toString();
}

/// Whether a value is never a file name: a number, a duration, a date, a URL, a secret.
bool _noFiles(CliValue<Object?> value) =>
    const {'<int>', '<number>', '<duration>', '<date>', '<url>', '<secret>', '<bool>'}.contains(value._hint);
