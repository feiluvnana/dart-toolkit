/// # Git Tool (`tool.git.*`)
///
/// Thin wrappers over the `git` executable for the queries scripts need:
/// current branch, HEAD hash, working-tree cleanliness. Anything not here is
/// [GitAccessor.run] away, which is public for exactly that reason.
library;

import 'dart:io';

import '../src/proc.dart';

// ============================================================================
// GIT TOOL (tool.git.*)
// ============================================================================

/// Entry point for git commands, reachable as `tool.git`.
///
/// Query methods return an empty string or status when the command fails, so
/// they are safe to call outside a repository. Mutating methods return
/// [SysResult] with the exit code and output; check [SysResult.ok] for success.
///
/// ```dart
/// if (await tool.git.dirty()) print('uncommitted changes');
/// ```
class GitAccessor {
  /// Creates the accessor. Prefer the shared `tool.git` instance.
  const GitAccessor();

  /// The exit code reported when `git` itself cannot be run.
  ///
  /// The shell convention for "command not found", so [SysResult.ok] is false
  /// and the query methods fall back to their empty answers.
  static const int missingExit = 127;

  /// Runs `git` with [args] in the working directory [cwd], returning the
  /// full result.
  ///
  /// A machine with no `git` on its `PATH` reports [missingExit] rather than
  /// throwing, so every method here keeps the contract of failing softly.
  Future<SysResult> run(List<String> args, [String? cwd]) async {
    try {
      return await Sys.run('git', args, cwd: cwd);
    } on ProcessException catch (error) {
      return SysResult(code: missingExit, out: '', err: error.message);
    }
  }

  /// The current branch name, or `''` outside a repository.
  ///
  /// A detached `HEAD` has no branch to name, so that reports `''` too rather
  /// than the literal string `HEAD`.
  Future<String> branch([String? cwd]) async {
    final name = await _text(['rev-parse', '--abbrev-ref', 'HEAD'], cwd);
    return name == 'HEAD' ? '' : name;
  }

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

  /// Fetches from [remote], optionally with tags and pruning.
  ///
  /// The query half of a pull: it updates the remote-tracking refs and leaves
  /// the working tree where it is, which is what a release script wants before
  /// it looks at [tag] or [hash].
  Future<SysResult> fetch({
    String? remote,
    bool tags = false,
    bool prune = false,
    String? cwd,
  }) => run([
    'fetch',
    if (tags) '--tags',
    if (prune) '--prune',
    if (remote != null) remote,
  ], cwd);

  /// Checks out [target] — a branch, a tag or a commit.
  ///
  /// Set [create] to make a new branch of that name, as `git checkout -b`.
  Future<SysResult> checkout(
    String target, {
    bool create = false,
    String? cwd,
  }) => run(['checkout', if (create) '-b', target], cwd);

  /// Clones [repo], optionally into [dest].
  Future<SysResult> clone(String repo, {String? dest, String? cwd}) =>
      run(['clone', repo, if (dest != null) dest], cwd);

  Future<String> _text(List<String> args, String? cwd) async {
    final res = await run(args, cwd);
    return res.ok ? res.out.trim() : '';
  }
}
