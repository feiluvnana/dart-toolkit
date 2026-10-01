part of '../../cli.dart';

/// The completion script for [root] in [shell]: what `app --completion bash` prints.
///
/// Everything it needs is already declared — commands, options, short forms, choices — so a
/// program gets completion for nothing. zsh reuses the bash script through `bashcompinit`,
/// which is one script to keep right instead of two.
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

/// What a command answers to: its own options and its ancestors', nearer ones first, each
/// with the spellings that still reach it there.
Iterable<(CliOption<Object?>, List<String>)> _reachable(CliCommand command) sync* {
  for (final option in command._chain.expand((c) => c._options)) {
    if (command._findOption(option.name) != option) continue;
    yield (option, ['--${option.name}', if (option.abbr case final a? when command._findAbbr(a) == option) '-$a']);
  }
}

/// [words] as one bash word list for `compgen -W`, each kept whole.
///
/// `compgen -W` splits its list on `IFS`, so a choice with a space in it — `'dry run'` —
/// was offered as two. The list is newline-separated and read with `IFS` set to a newline,
/// and ANSI-C quoting (`$'…'`) keeps a quote or a `$` in a choice from being expanded.
String _bashWords(Iterable<String> words) =>
    "\$'${words.map((w) => w.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', ' ')).join(r'\n')}'";

final _nonWordChar = RegExp(r'\W');

String _bash(CliCommand root) {
  final fn = '_${root.name.replaceAll(_nonWordChar, '_')}_completion';
  final tree = _tree(root).toList();
  final out = StringBuffer()
    ..writeln('$fn() {')
    ..writeln('  local cur="\${COMP_WORDS[COMP_CWORD]}" prev="\${COMP_WORDS[COMP_CWORD-1]}" path="${root.name}" i')
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
    // Declared once, offered under every command below it.
    final under = quote('string match -qr ${quote('^${RegExp.escape(path)}( |\$)')} -- ($fn)');
    for (final option in command._options) {
      final parts = [
        'complete -c ${root.name} -n $under -l ${option.name}',
        if (option.abbr case final a?) '-s $a',
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
