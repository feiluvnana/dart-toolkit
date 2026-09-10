# Git (`tool.git.*`)

Thin wrappers over the `git` executable for the queries scripts actually need.
Query methods return an empty string or a safe default when the command fails,
so they are safe to call outside a repository. Mutating methods return a
`SysResult`; check `.ok`.

```dart
if (await tool.git.dirty()) {
  system.console.logger.warn('uncommitted changes');
}
```

---

Query methods return an empty string when the command fails, so they are safe to call outside a repository.

```dart
await tool.git.branch();          // 'master'
await tool.git.hash();            // '9e8261c'
await tool.git.hash(full: true);  // full 40-character sha
await tool.git.dirty();           // uncommitted changes?
await tool.git.status();          // short-format output, '' when clean
await tool.git.tag();             // tag on HEAD, else nearest reachable tag
```

Mutating methods return a `SysResult` containing the process exit code and output:

```dart
final addRes = await tool.git.add('lib/');
if (!addRes.ok) print('Add failed: ${addRes.err}');

final commitRes = await tool.git.commit('feat: add crawler', all: true);
final tagRes = await tool.git.mark('v1.0.0');                         // creates a tag
await tool.git.push(remote: 'origin', branch: 'master');
await tool.git.pull();
await tool.git.fetch(remote: 'origin', tags: true, prune: true);
await tool.git.checkout('release/1.2');
await tool.git.checkout('release/1.3', create: true);                 // -b
await tool.git.clone('https://github.com/user/repo.git', dest: 'vendor/repo');
```

`fetch` is the query half of a pull: it updates the remote-tracking refs and
leaves the working tree alone, which is what a release script wants before it
reads `tag` or `hash`.

Every method takes an optional `cwd` to run against another checkout.

For anything not wrapped — `log`, `diff`, `remote`, `stash` — `run` gives you
the full `SysResult`. That is deliberate: each of those returns structured
output that would need a type of its own, and `run` covers them without
doubling the size of this tool:

```dart
final res = await tool.git.run(['log', '--oneline', '-5']);
if (res.ok) print(res.out);
```

### Release guard

```dart
if (await tool.git.dirty()) {
  system.console.logger.error('Commit your changes before releasing.');
  return;
}
await tool.git.mark('v$pubspecVersion');
await tool.git.push(remote: 'origin');
```

---

## See Also

- [`tool.zip.*`](zip.md) — the other wrapped tool
- [`system.*`](system.md) — the subprocess runner behind these calls
- [`util.*`](util.md) — time, sizes, text, hashing, randomness
