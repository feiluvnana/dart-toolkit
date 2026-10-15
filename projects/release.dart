// release: check this package and publish a GitHub release of its version.
//
//   dart run projects/release.dart [--publish]
//
// Reads the version and repository from pubspec.yaml and the notes from CHANGELOG.md
// (`## <version>`), runs `dart analyze` and `dart test` (10 min cap each), and checks that git
// is clean and the tag is new. Without --publish it stops there and prints the plan. With it
// (and GITHUB_TOKEN, in the environment or .env) it tags, pushes the tag, creates the release
// and uploads `git archive` of the tag with a progress bar.
library;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:dart_toolkit/yaml.dart';

final _publish = Flag('publish', 'Tag, push and create the GitHub release.');
final _token = Opt<String?>('token', 'GitHub token.', env: 'GITHUB_TOKEN');

Future<void> main(List<String> args) => Command(
  'release',
  'Check the package and publish a GitHub release.',
  params: [_publish, _token],
  dotenv: '.env',
  handler: _run,
).run(args);

Future<void> _run(Context c) async {
  if (await Shell.which('git') == null) throw const UsageException('Install git first.');
  final pubspec = await Fs.file('pubspec.yaml').yaml();
  final version = pubspec.$('version').text() ?? (throw Exception('pubspec.yaml has no version'));
  final repo = Uri.parse(pubspec.$('repository').text() ?? '').path.replaceAll(RegExp(r'^/|\.git$'), '');
  final tag = 'v$version';
  final notes = _section(await Fs.file('CHANGELOG.md').text(), version);
  if (notes == null) throw Exception('CHANGELOG.md has no "## $version" section.');
  for (final check in [
    ['dart', 'analyze'],
    ['dart', 'test'],
  ]) {
    await Console.spin(check.join(' '), Shell.run(check, check: true, timeout: 10.minutes));
  }
  if ((await Shell.run(['git', 'status', '--porcelain']).text()).trim().isNotEmpty) {
    throw Exception('git has uncommitted changes: commit or stash them first.');
  }
  if ((await Shell.run(['git', 'tag', '-l', tag]).text()).trim().isNotEmpty) throw Exception('Tag $tag exists.');
  Console.log('ready: $repo $tag (${notes.split('\n').length} lines of notes)');
  if (!c(_publish)) return Console.log('dry run: pass --publish to tag and release');

  final token = c(_token) ?? (throw const UsageException('--publish needs GITHUB_TOKEN.'));
  final auth = {'authorization': 'Bearer $token', 'accept': 'application/vnd.github+json'};
  await Shell.run(['git', 'tag', tag], check: true);
  await Shell.run(['git', 'push', 'origin', tag], check: true, live: true);
  final release = await Http.client(
    base: 'https://api.github.com/repos/$repo/',
    headers: auth,
    check: true,
  ).post('releases', body: .json({'tag_name': tag, 'name': tag, 'body': notes})).json();
  final upload = release.$('upload_url').text()!.replaceFirst(RegExp(r'\{.*\}$'), '');
  await Fs.temp((dir) async {
    final zip = dir.file('dart_toolkit-$version.zip');
    await (Shell.run(['git', 'archive', '--format=zip', tag], check: true) > zip);
    final size = await zip.size();
    await Http.client(headers: auth, check: true, timeout: 5.minutes).post(
      upload,
      query: {'name': zip.name()},
      headers: {'content-type': 'application/zip', 'content-length': '$size'},
      body: .stream(zip | Console.bar(size, label: zip.name())),
    );
  });
  Console.log('released ${release.$('html_url').text()}');
}

/// The text under `## <version>` up to the next `## ` heading.
String? _section(String changelog, String version) {
  final m = RegExp(
    '^## ${RegExp.escape(version)}\\s*\$(.*?)(?=^## |(?![\\s\\S]))',
    multiLine: true,
    dotAll: true,
  ).firstMatch(changelog);
  return m?[1]?.trim();
}
