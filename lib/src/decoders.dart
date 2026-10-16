/// The private handshake behind charset-aware streamed text: a reader whose
/// bytes are not plain UTF-8 (an http response naming a `charset`)
/// registers here how its bytes stream as text, instead of growing a public
/// method; `reader.rows()` reads through it. Not exported.
library;

final decoders = Expando<Stream<String> Function(Stream<List<int>> bytes)>();
