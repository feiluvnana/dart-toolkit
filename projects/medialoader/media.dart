// The files of posts and stories. Import with `as media`.
library;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/json.dart';

// A file to fetch from [url], or to write [text] into.
typedef Download = ({File to, String? url, String? text});

// posts/<month>/<code>_<n>.jpg and posts/<month>/<code>.mp4, with the caption
// beside them as <code>.txt. [order] numbers a
// carousel's items by id (default: their position), so an edited album keeps
// its file names.
List<Download> posts(
  List<Json> posts, {
  Dir? postsDir,
  Dir? photos,
  Dir? reels,
  Map<String, List<String>> order = const {},
}) {
  final pDir = postsDir ?? photos;
  final rDir = postsDir ?? reels;
  return [
    for (final p in posts) ...post(p, code(p), pDir?.dir(month(p)), rDir?.dir(month(p)), order[code(p)]),
  ];
}

String code(Json post) => Fs.sanitize(post.$('code|shortcode').text() ?? 'post');

// A post's item ids in order: its carousel's, or its own.
List<String> items(Json post) => [
  for (final item in children(post).isEmpty ? [post] : children(post)) item.$('pk|id').text() ?? '',
];

List<Json> children(Json item) => [...item.$('carousel_media'), ...item.$('edge_sidecar_to_children.edges.*.node')];

List<Download> post(Json p, String name, Dir? photos, Dir? reels, [List<String>? order]) {
  final out = files(p, name, photos, reels, order).toList();
  final caption = p.$('caption.text').text() ?? p.$('edge_media_to_caption.edges.*.node.text').firstOrNull?.text();
  return [
    ...out,
    if (caption != null && caption.trim().isNotEmpty)
      for (final dir in {for (final f in out) f.to.parent().path()})
        (to: Fs.dir(dir).file('$name.txt'), url: null, text: caption),
  ];
}

// stories/<month>/<taken_at>_<id>.jpg when [monthly], else straight into [dir].
List<Download> stories(List<Json> items, Dir dir, {bool monthly = false}) => [
  for (final i in items)
    if (monthly ? dir.dir(month(i)) : dir case final d)
      ...files(i, '${i.$('taken_at').or(0)}_${Fs.sanitize(i.$('id').text() ?? 'item')}', d, d),
];

// An item is a carousel of other items, a video, or an image.
Iterable<Download> files(Json item, String name, Dir? photos, Dir? reels, [List<String>? order]) sync* {
  final list = children(item);
  for (final (i, child) in list.indexed) {
    final at = order?.indexOf(child.$('pk|id').text() ?? '') ?? -1;
    yield* files(child, '${name}_${(at < 0 ? i : at) + 1}', photos, reels);
  }
  if (list.isNotEmpty) return;
  final video = largest(item.$('video_versions|video_resources')) ?? item.$('video_url').text();
  final image = video != null
      ? null
      : largest(item.$('image_versions2.candidates')) ??
            largest(item.$('display_resources')) ??
            item.$('display_url|display_uri').text();
  if (video != null && reels != null) yield (to: reels.file('$name.mp4'), url: video, text: null);
  if (image != null && !image.contains('/null.jpg') && photos != null) yield (to: photos.file('$name.jpg'), url: image, text: null);
}

// "2024-05", the local month an item was posted.
String month(Json item) =>
    DateTime.fromMillisecondsSinceEpoch(item.$('taken_at|taken_at_timestamp').or(0) * 1000).format('yyyy-MM');

// "2024-05-01", the local day an item was posted.
String day(Json item) =>
    DateTime.fromMillisecondsSinceEpoch(item.$('taken_at|taken_at_timestamp').or(0) * 1000).format('yyyy-MM-dd');

// The API uses url/width, the data embedded in pages uses src/config_width.
String? largest(Json versions) => versions.max((v) => v.$('width|config_width').or(0)).$('url|src').text();
