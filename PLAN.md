# Plan: what is left after the native library

The native library, `crypto` and the archive formats are in. What remains is distribution and
the last dependency.

| step | what | why |
|---|---|---|
| 1 | **Cross-compile the five targets.** `cargo install cargo-zigbuild`, install zig, then `make native RUST_TARGET=x86_64-unknown-linux-gnu TARGET=linux_x64` and the same for `aarch64-unknown-linux-gnu`, `x86_64-apple-darwin`, `x86_64-pc-windows-msvc` (or `-gnu`). unrar's C++ needs `zig c++`; liblzma and libzstd build from their vendored sources. | Today only `macos_arm64` is built, so every other platform gets `UnsupportedError` from `crypto` beyond digests and from every archive call. |
| 2 | **Ship the binaries.** They are `.gitignore`d and `.pubignore` lets them into the package; `make release` must build all five before `dart pub publish`. Record their SHA-256 in the changelog. | Reproducibility without CI. |
| 3 | **Build hooks.** `hook/build.dart` with `package:hooks` and `package:code_assets` registering the prebuilt for the target, so `dart compile exe` bundles it. Keep the `Native` loader's path search as the fallback. | `dart run` works today; a compiled executable only finds the library next to itself. |
| 4 | **Drop `package:crypto`.** SHA-2 and MD5 in Dart (about 250 lines) so the fallback digests need no package and `path` is the only dependency. | The convention says nothing third-party at runtime. |
| 5 | **Progress from native.** A caller-owned struct the archive functions update (bytes done, entry name) and the Dart side polls into `TaskProgress`, so `Console.multiProgress` renders an extraction. | Long extractions are silent today. |
| 6 | **Rust tests.** `cargo test` with the same vectors the Dart tests use, and the zip-slip check (`inside()`) as a unit test. | The traversal guard lost its Dart test when the Dart zip went. |
