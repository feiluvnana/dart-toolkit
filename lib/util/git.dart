import '../system/sys.dart';

// ============================================================================
// GIT AUTOMATION SUBSYSTEM (git.* / Git)
// ============================================================================

/// Top-level Git version control automation accessor.
///
/// Provides strictly 1-word methods for repository inspection and actions:
/// ```dart
/// final branch = await git.branch();
/// final sha = await git.hash();
/// if (await git.dirty()) {
///   await git.add();
///   await git.commit('Auto-update');
///   await git.push();
/// }
/// Git automation manager providing branch, status, commit, and sync operations.
class GitAccessor {
  /// Creates a [GitAccessor].
  const GitAccessor();

  /// Runs an arbitrary git command with [args] (1-word).
  Future<SysResult> run(List<String> args, [String? cwd]) {
    return Sys.run('git', args, cwd: cwd);
  }

  /// Gets the current active branch name (1-word).
  Future<String> branch([String? cwd]) async {
    final res = await run(['rev-parse', '--abbrev-ref', 'HEAD'], cwd);
    return res.ok ? res.output.trim() : '';
  }

  /// Gets the commit SHA hash of the current HEAD (1-word).
  Future<String> hash([bool short = true, String? cwd]) async {
    final args = short
        ? ['rev-parse', '--short', 'HEAD']
        : ['rev-parse', 'HEAD'];
    final res = await run(args, cwd);
    return res.ok ? res.output.trim() : '';
  }

  /// Checks whether the working tree contains uncommitted modifications (1-word).
  Future<bool> dirty([String? cwd]) async {
    final res = await run(['status', '--porcelain'], cwd);
    return res.ok && res.output.trim().isNotEmpty;
  }

  /// Retrieves the short porcelain status output of the working directory (1-word).
  Future<String> status([String? cwd]) async {
    final res = await run(['status', '--short'], cwd);
    return res.ok ? res.output.trim() : '';
  }

  /// Retrieves the current tag or creates a new tag if [name] is provided (1-word).
  Future<String> tag([String? name, String? cwd]) async {
    if (name != null && name.isNotEmpty) {
      final res = await run(['tag', name], cwd);
      return res.ok ? name : '';
    }
    final res = await run(['describe', '--tags', '--exact-match'], cwd);
    if (res.ok) return res.output.trim();
    final latest = await run(['describe', '--tags', '--abbrev=0'], cwd);
    return latest.ok ? latest.output.trim() : '';
  }

  /// Stages files matching [pattern] (default is `'.'`) (1-word).
  Future<bool> add([String pattern = '.', String? cwd]) async {
    final res = await run(['add', pattern], cwd);
    return res.ok;
  }

  /// Creates a commit with the specified [msg] (1-word).
  Future<bool> commit(String msg, {bool all = false, String? cwd}) async {
    final args = <String>['commit'];
    if (all) args.add('-a');
    args.addAll(['-m', msg]);
    final res = await run(args, cwd);
    return res.ok;
  }

  /// Pushes commits to the remote repository (1-word).
  Future<bool> push([String? remote, String? branch, String? cwd]) async {
    final args = <String>['push'];
    if (remote != null) args.add(remote);
    if (branch != null) args.add(branch);
    final res = await run(args, cwd);
    return res.ok;
  }

  /// Pulls commits from the remote repository (1-word).
  Future<bool> pull([String? remote, String? branch, String? cwd]) async {
    final args = <String>['pull'];
    if (remote != null) args.add(remote);
    if (branch != null) args.add(branch);
    final res = await run(args, cwd);
    return res.ok;
  }

  /// Clones a remote [repo] to an optional [dest] directory (1-word).
  Future<bool> clone(String repo, [String? dest, String? cwd]) async {
    final args = <String>['clone', repo];
    if (dest != null) args.add(dest);
    final res = await run(args, cwd);
    return res.ok;
  }
}
