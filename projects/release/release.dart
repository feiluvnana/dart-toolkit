// Checks this package and publishes a GitHub release of its version.
//
//   dart run projects/release/release.dart [--publish]
//
// Takes the version and repo from pubspec.yaml and the notes from the matching
// "## <version>" section of CHANGELOG.md. Runs analyze and the tests, and makes
// sure git is clean and the tag is new. Without --publish it stops there. With
// it (needs GITHUB_TOKEN) it pushes the tag, creates the release and uploads a
// zip of the tag.
library;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:dart_toolkit/yaml.dart';

final publishFlag = Flag('publish', 'Tag, push and create the GitHub release.');
final tokenOpt = Opt<String?>('token', 'GitHub token.', env: 'GITHUB_TOKEN');

Future<void> main(List<String> args) => Command(
  'release',
  'Check the package and publish a GitHub release.',
  params: [publishFlag, tokenOpt],
  dotenv: '.env',
  handler: release,
).run(args);

Future<void> release(Context c) async {
  if (await Shell.which('git') == null) throw const UsageException('Install git first.');

  final pubspec = await Fs.file('pubspec.yaml').yaml();
  final version = pubspec.$('version').text() ?? (throw Exception('pubspec.yaml has no version'));
  final repoUrl = pubspec.$('repository').text() ?? '';
  final repo = Uri.parse(repoUrl).path.replaceAll(RegExp(r'^/|\.git$'), '');
  final tag = 'v$version';
  final notes = changelogSection(await Fs.file('CHANGELOG.md').text(), version);
  if (notes == null) throw Exception('CHANGELOG.md has no "## $version" section.');

  await Console.spin('dart analyze', Shell.run(['dart', 'analyze'], check: true, timeout: 10.minutes));
  await Console.spin('dart test', Shell.run(['dart', 'test'], check: true, timeout: 10.minutes));
  final status = await Shell.run(['git', 'status', '--porcelain']).text();
  if (status.trim().isNotEmpty) throw Exception('git has uncommitted changes: commit or stash them first.');
  final existing = await Shell.run(['git', 'tag', '-l', tag]).text();
  if (existing.trim().isNotEmpty) throw Exception('Tag $tag exists.');

  Console.log('all checks passed: $tag of $repo is ready to release');
  if (!c(publishFlag)) return Console.log('dry run, nothing was published (pass --publish to release)');

  final token = c(tokenOpt) ?? (throw const UsageException('--publish needs GITHUB_TOKEN.'));
  final headers = {'authorization': 'Bearer $token', 'accept': 'application/vnd.github+json'};
  final github = Http.client(headers: headers, check: true, timeout: 5.minutes);

  await Shell.run(['git', 'tag', tag], check: true);
  await Shell.run(['git', 'push', 'origin', tag], check: true, live: true);
  final info = await Console.spin(
    'creating the GitHub release',
    github
        .post('https://api.github.com/repos/$repo/releases', body: .json({'tag_name': tag, 'name': tag, 'body': notes}))
        .json(),
  );
  // upload_url ends in a URI template, e.g. ".../assets{?name,label}"
  final uploadUrl = info.$('upload_url').text()!.replaceFirst(RegExp(r'\{.*\}$'), '');

  await Fs.temp((dir) async {
    final zip = dir.file('dart_toolkit-$version.zip');
    await (Shell.run(['git', 'archive', '--format=zip', tag], check: true) > zip);
    final size = await zip.size();
    await github.post(
      uploadUrl,
      query: {'name': zip.name()},
      headers: {'content-type': 'application/zip', 'content-length': '$size'},
      body: .stream(zip | Console.bar(size, label: zip.name())),
    );
  });
  Console.log('released $tag: ${info.$('html_url').text()}');
}

String? changelogSection(String changelog, String version) {
  final lines = changelog.split('\n');
  final start = lines.indexWhere((l) => l.trim() == '## $version');
  if (start == -1) return null;
  var end = lines.indexWhere((l) => l.startsWith('## '), start + 1);
  if (end == -1) end = lines.length;
  return lines.sublist(start + 1, end).join('\n').trim();
}
