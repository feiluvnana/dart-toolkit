/// # Git Domain (`git.*`)
///
/// Thin wrappers over the `git` executable for the queries scripts need:
/// current branch, HEAD hash, working-tree cleanliness.
library;

import '../src/proc.dart';

// ============================================================================
// GIT DOMAIN (git.*)
// ============================================================================

/// The `git` domain: repository queries and commands.
const GitAccessor git = GitAccessor();

/// Entry point for git commands, reachable as [git].
///
/// Query methods return an empty string or status when the command fails, so
/// they are safe to call outside a repository. Mutating methods return
/// [SysResult] with the exit code and output; check [SysResult.ok] for success.
///
/// ```dart
/// if (await git.dirty()) print('uncommitted changes');
/// ```
class GitAccessor {
  /// Creates the accessor. Prefer the shared [git] instance.
  const GitAccessor();

  /// Runs `git` with [args] in the working directory [cwd], returning the
  /// full result.
  Future<SysResult> run(List<String> args, [String? cwd]) =>
      Sys.run('git', args, cwd: cwd);

  /// The current branch name, or `''` outside a repository.
  Future<String> branch([String? cwd]) =>
      _text(['rev-parse', '--abbrev-ref', 'HEAD'], cwd);

  /// The HEAD commit hash, abbreviated unless [full] is set.
  Future<String> hash({bool full = false, String? cwd}) =>
      _text(['rev-parse', if (!full) '--short', 'HEAD'], cwd);

  /// Whether the working tree has uncommitted changes.
  Future<bool> dirty([String? cwd]) async =>
      (await _text(['status', '--porcelain'], cwd)).isNotEmpty;

  /// The short-format status output, or `''` when clean.
  Future<String> status([String? cwd]) => _text(['status', '--short'], cwd);

  /// The tag on HEAD, falling back to the most recent reachable tag.
  Future<String> tag([String? cwd]) async {
    final exact = await _text(['describe', '--tags', '--exact-match'], cwd);
    if (exact.isNotEmpty) return exact;
    return _text(['describe', '--tags', '--abbrev=0'], cwd);
  }

  /// Creates tag [name] on HEAD. Returns the full result.
  Future<SysResult> mark(String name, [String? cwd]) => run(['tag', name], cwd);

  /// Stages [pattern]. Returns the full result.
  Future<SysResult> add([String pattern = '.', String? cwd]) =>
      run(['add', pattern], cwd);

  /// Commits with [msg], optionally staging tracked changes with [all].
  Future<SysResult> commit(String msg, {bool all = false, String? cwd}) =>
      run(['commit', if (all) '-a', '-m', msg], cwd);

  /// Pushes to [remote] and [branch] when given.
  Future<SysResult> push({String? remote, String? branch, String? cwd}) => run([
    'push',
    if (remote != null) remote,
    if (branch != null) branch,
  ], cwd);

  /// Pulls from [remote] and [branch] when given.
  Future<SysResult> pull({String? remote, String? branch, String? cwd}) => run([
    'pull',
    if (remote != null) remote,
    if (branch != null) branch,
  ], cwd);

  /// Clones [repo], optionally into [dest].
  Future<SysResult> clone(String repo, {String? dest, String? cwd}) =>
      run(['clone', repo, if (dest != null) dest], cwd);

  Future<String> _text(List<String> args, String? cwd) async {
    final res = await run(args, cwd);
    return res.ok ? res.out.trim() : '';
  }
}
