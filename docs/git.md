# `git` — repository automation

Thin wrappers over the `git` executable for the queries scripts actually need.
Query methods return an empty string or a safe default when the command fails,
so they are safe to call outside a repository. Mutating methods return a
`SysResult`; check `.ok`.

```dart
if (await git.dirty()) {
  system.console.logger.warn('uncommitted changes');
}
```

---

Query methods return an empty string when the command fails, so they are safe to call outside a repository.

```dart
await git.branch();          // 'master'
await git.hash();            // '9e8261c'
await git.hash(full: true);  // full 40-character sha
await git.dirty();           // uncommitted changes?
await git.status();          // short-format output, '' when clean
await git.tag();             // tag on HEAD, else nearest reachable tag
```

Mutating methods return a `SysResult` containing the process exit code and output:

```dart
final addRes = await git.add('lib/');
if (!addRes.ok) print('Add failed: ${addRes.err}');

final commitRes = await git.commit('feat: add crawler', all: true);
final tagRes = await git.mark('v1.0.0');                         // creates a tag
await git.push(remote: 'origin', branch: 'master');
await git.pull();
await git.clone('https://github.com/user/repo.git', dest: 'vendor/repo');
```

Every method takes an optional `cwd` to run against another checkout.

For anything not wrapped, `run` gives you the full `SysResult`:

```dart
final res = await git.run(['log', '--oneline', '-5']);
if (res.ok) print(res.out);
```

### Release guard

```dart
if (await git.dirty()) {
  system.console.logger.error('Commit your changes before releasing.');
  return;
}
await git.mark('v$pubspecVersion');
await git.push(remote: 'origin');
```

---

## See Also

- [`system.*`](system.md) — the subprocess runner behind these calls
- [`util.*`](util.md) — time, sizes, text, hashing, randomness
