// The files of Instagram posts and stories. Import with `as media`.
library;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/json.dart';

// A file to fetch from [url] or to write [text] into, dated [at] (when posted).
final class Download {
  const Download(this.to, {this.url, this.text, this.at});
  final File to;
  final String? url, text;
  final DateTime? at;
}

// [posts] into posts/<month>/: <code>_<n>.jpg and <code>.mp4, with the
// caption beside them as <code>.txt. [order] numbers a carousel's items
// by id (default: their position), so an edited album keeps its file names.
List<Download> posts(List<Json> posts, Dir dir, {Map<String, List<String>> order = const {}}) => [
  for (final p in posts) ...post(p, dir.dir(time(p).format('yyyy-MM')), order[code(p)]),
];

String code(Json post) => Fs.sanitize(post.$('code|shortcode').text() ?? 'post');

// A post's item ids in order: its carousel's, or its own.
List<String> items(Json post) => [for (final item in children(post).isEmpty ? [post] : children(post)) item.$('pk|id').or('')];

List<Json> children(Json item) => [...item.$('carousel_media'), ...item.$('edge_sidecar_to_children.edges.*.node')];

List<Download> post(Json p, Dir dir, [List<String>? order]) {
  final out = files(p, code(p), dir, order).toList();
  final caption = p.$('caption.text|edge_media_to_caption.edges.0.node.text').text();
  return [
    ...out,
    if (caption != null && caption.trim().isNotEmpty && out.isNotEmpty)
      Download(dir.file('${code(p)}.txt'), text: caption, at: time(p)),
  ];
}

// Story items: <taken_at>_<id>.jpg/.mp4 in [dir], or its <month>/ when [monthly].
List<Download> stories(List<Json> items, Dir dir, {bool monthly = false}) => [
  for (final i in items)
    ...files(
      i,
      '${i.$('taken_at').or(0)}_${Fs.sanitize(i.$('id').or('item'))}',
      monthly ? dir.dir(time(i).format('yyyy-MM')) : dir,
    ),
];

// An item is a carousel of other items, a video, or an image.
Iterable<Download> files(Json item, String name, Dir dir, [List<String>? order]) sync* {
  final list = children(item);
  for (final (i, child) in list.indexed) {
    final at = order?.indexOf(child.$('pk|id').or('')) ?? -1;
    yield* files(child, '${name}_${(at < 0 ? i : at) + 1}', dir);
  }
  if (list.isNotEmpty) return;
  final video = largest(item.$('video_versions|video_resources')) ?? item.$('video_url').text();
  final image = largest(item.$('image_versions2.candidates')) ?? largest(item.$('display_resources')) ??
      item.$('display_url|display_uri').text();
  if (video != null) {
    yield Download(dir.file('$name.mp4'), url: video, at: time(item));
  } else if (image != null && !image.contains('/null.jpg')) {
    yield Download(dir.file('$name.jpg'), url: image, at: time(item));
  }
}

// When an item was posted.
DateTime time(Json item) => DateTime.fromMillisecondsSinceEpoch(item.$('taken_at|taken_at_timestamp').or(0) * 1000);

// The API uses url/width, the data embedded in pages uses src/config_width.
String? largest(Json versions) => versions.max((v) => v.$('width|config_width').or(0)).$('url|src').text();
