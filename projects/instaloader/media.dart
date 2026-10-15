import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/json.dart';

enum Section { photos, reels, stories, highlights }

typedef Download = ({String url, File to});

// The files of each post (a carousel has several), posts without any left out.
List<List<Download>> postFiles(List<Json> posts, Dir dir, Section section) => [
  for (final post in posts) [...mediaFiles(post, dir, Fs.sanitize(post.$('code|shortcode').text() ?? 'post'), section)],
].where((files) => files.isNotEmpty).toList();

List<List<Download>> storyFiles(List<Json> items, Dir dir, Section section) => [
  for (final item in items)
    [...mediaFiles(item, dir, '${item.$('taken_at').or(0)}_${Fs.sanitize(item.$('id').text() ?? 'item')}', section)],
].where((files) => files.isNotEmpty).toList();

int fileCount(List<List<Download>> posts) => posts.fold(0, (n, files) => n + files.length);

// An item is a carousel of other items, a video, or an image.
Iterable<Download> mediaFiles(Json item, Dir dir, String name, Section section) sync* {
  final children = [...item.$('carousel_media'), ...item.$('edge_sidecar_to_children.edges.*.node')];
  if (children.isNotEmpty) {
    for (final (i, child) in children.indexed) {
      yield* mediaFiles(child, dir, '${name}_${i + 1}', section);
    }
    return;
  }

  final video = largest(item.$('video_versions|video_resources')) ?? item.$('video_url').text();
  if (video != null) {
    if (section != Section.photos) yield (url: video, to: dir.file('$name.mp4'));
    return;
  }

  final image =
      largest(item.$('image_versions2.candidates')) ??
      largest(item.$('display_resources')) ??
      item.$('display_url|display_uri').text();
  if (image != null && section != Section.reels) yield (url: image, to: dir.file('$name.jpg'));
}

// The API uses url/width, the data embedded in pages uses src/config_width.
String? largest(Json versions) => versions.max((v) => v.$('width|config_width').or(0)).$('url|src').text();
