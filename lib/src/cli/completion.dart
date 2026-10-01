part of '../../cli.dart';

/// The completion script for [root] in [shell]: what `app --completion bash` prints.
///
/// Built from the declared tree; zsh reuses the bash script through `bashcompinit`.
String _completion(CliCommand root, String? shell) => switch (shell) {
  'bash' => _bash(root),
  'zsh' => 'autoload -U +X bashcompinit && bashcompinit\n${_bash(root)}',
  'fish' => _fish(root),
  _ => throw UsageException('--completion takes bash, zsh or fish${shell == null ? '' : ', not "$shell"'}.'),
};

/// Every command under [root], root first, each with its path of names.
Iterable<(String, CliCommand)> _tree(CliCommand root, [String? path]) sync* {
  final here = path ?? root.name;
  yield (here, root);
  for (final sub in root._subcommands.values) {
    yield* _tree(sub, '$here ${sub.name}');
  }
}

/// The options [command] answers to, nearer first, each with the spellings that reach it.
Iterable<(CliOption<Object?>, List<String>)> _reachable(CliCommand command) sync* {
  for (final option in command._chain.expand((c) => c._options)) {
    if (command._findOption(option.name) != option) continue;
    yield (option, ['--${option.name}', if (option._abbr case final a? when command._findAbbr(a) == option) '-$a']);
  }
}

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
  out
    ..writeln('    esac')
    ..writeln('  done')
    ..writeln('  case "\$path:\$prev" in');
  for (final (path, command) in tree) {
    for (final (option, spellings) in _reachable(command)) {
      if (!option._takesValue) continue;
      final when = spellings.map((s) => '"$path:$s"').join('|');
      final choices = option._choices?.map(_label);
      // No choices means any value: an empty reply, so `-o default` offers file names.
      out.writeln(
        choices == null
            ? '    $when) return ;;'
            : '    $when) COMPREPLY=(\$(compgen -W ${_bashWords(choices)} -- "\$cur" | sed \'s/ /\\\\ /g\')); return ;;',
      );
    }
  }
  out
    ..writeln('  esac')
    ..writeln('  case "\$path" in');
  for (final (path, command) in tree) {
    final words = [
      ...command._subcommands.keys,
      for (final (_, spellings) in _reachable(command)) ...spellings,
      '--help',
    ];
    out.writeln('    "$path") COMPREPLY=(\$(compgen -W ${_bashWords(words)} -- "\$cur")) ;;');
  }
  return (out
        ..writeln('  esac')
        ..writeln('}')
        ..writeln('complete -o default -F $fn ${root.name}'))
      .toString();
}

String _fish(CliCommand root) {
  String quote(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
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
  out
    ..writeln('    end')
    ..writeln('  end')
    ..writeln('  echo \$path')
    ..writeln('end');
  for (final (path, command) in tree) {
    final at = quote('test ($fn) = ${quote(path)}');
    for (final sub in command._subcommands.values) {
      out.writeln('complete -c ${root.name} -f -n $at -a ${quote(sub.name)} -d ${quote(sub.description)}');
    }
    out.writeln('complete -c ${root.name} -n $at -l help -d ${quote('Print this help message')}');
    for (final (option, spellings) in _reachable(command)) {
      final hasAbbr = spellings.any((s) => s.startsWith('-') && !s.startsWith('--'));
      final parts = [
        'complete -c ${root.name} -n $at -l ${option.name}',
        if (hasAbbr) '-s ${option._abbr}',
        if (option.description.isNotEmpty) '-d ${quote(option.description)}',
        // fish reads `-a` as a list of words, so a space inside one choice is escaped.
        if (option._takesValue)
          option._choices == null
              ? '-r'
              : '-xa ${quote(option._choices!.map((c) => _label(c).replaceAll(' ', r'\ ')).join(' '))}',
      ];
      out.writeln(parts.join(' '));
    }
  }
  return out.toString();
}
