import 'package:dart_toolkit/dart_toolkit.dart';

/// Driving other programs, and deciding what a failure means. Runs against this repository,
/// so it needs `git` on the PATH and nothing else.
Future<void> main() async {
  Console.rule('One command at a time');

  // `quiet: true` keeps the child's output out of ours. `.text` is trimmed stdout, straight
  // off the future — no intermediate result variable.
  final branch = await run('git rev-parse --abbrev-ref HEAD', quiet: true).text;
  final commits = await run('git rev-list --count HEAD', quiet: true).text;
  Logger.info('branch $branch, $commits commits');

  // Arguments that contain spaces or quotes are read the way a POSIX shell reads them.
  final subject = await run("git log -1 --format='%s'", quiet: true).text;
  Logger.info('last commit: $subject');

  Console.rule('Pipelines');

  // `|` builds a pipeline; the exit code is the rightmost non-zero one, as `pipefail` gives.
  final dartFiles = await ('git ls-files' | r'grep \.dart$').run(quiet: true);
  Logger.info('tracked Dart files: ${dartFiles.lines.length}');

  // stdin is a string, so a pipeline can start from something already in hand.
  final longest = await ('sort -rn' | 'head -3').run(
    quiet: true,
    input: dartFiles.lines.map((f) => '${f.length} $f').join('\n'),
  );
  for (final line in longest.lines) {
    Logger.info('long path: $line');
  }

  Console.rule('Finding a program before trusting it');

  if (await which('git') case final git?) {
    // `args:` are passed through untouched — no splitting, no shell. This is where a value
    // that came from a user or a page belongs.
    Logger.ok('${await git.run(args: ['--version'], quiet: true).text} at $git');
  } else {
    await die('git is not on the PATH');
  }

  Console.rule('When a command fails');

  // A non-zero exit throws a ShellException by default.
  try {
    await run('git cat-file -e deadbeefdeadbeef', quiet: true);
  } on ShellException catch (e) {
    Logger.warn('threw, as asked: exit ${e.result.exitCode}');
  }

  // `throwOnError: false` hands the result back instead, for the caller who expects failure.
  final probe = await run('git cat-file -e deadbeefdeadbeef', quiet: true, throwOnError: false);
  Logger.info('did not throw: exit ${probe.exitCode}, ok=${probe.isOk}');

  // Or settle it, and pick the policy where the value is used rather than where it is made.
  final outcome = await Either.tryCatch(() => run('git status --porcelain', quiet: true).text);
  Logger.info(outcome.fold((e) => 'failed: $e', (text) => text.isEmpty ? 'tree is clean' : 'tree is dirty'));

  Console.rule('Environment');

  // Overrides live in memory; the process environment is never written to.
  Env.set('DEPLOY_ENV', 'staging');
  Logger.info('DEPLOY_ENV=${Env.get('DEPLOY_ENV')} (an override, not the real environment)');
  Logger.info('CI=${Env.isCI}, PATH has ${Env.require('PATH').split(':').length} entries');

  // A child inherits the process environment plus the overrides plus anything passed here.
  final echoed = await run('printenv DEPLOY_ENV', quiet: true).text;
  Logger.ok('the child saw DEPLOY_ENV=$echoed');
  Env.reset();
}
