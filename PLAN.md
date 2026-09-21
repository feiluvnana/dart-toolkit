# Plan: what is left after the native library

The native library, the digests and the archive formats are in and `path` is the only dependency.
What remains is distribution.

| step | what | why |
|---|---|---|
| 1 | **Cross-compile the five targets.** `cargo install cargo-zigbuild`, install zig, then `make native RUST_TARGET=x86_64-unknown-linux-gnu TARGET=linux_x64` and the same for `aarch64-unknown-linux-gnu`, `x86_64-apple-darwin`, `x86_64-pc-windows-msvc` (or `-gnu`). unrar's C++ needs `zig c++`; liblzma and libzstd build from their vendored sources. If that
fight is not worth it, drop `xz`, `zstd`, `bzip2` and `rar` first — nothing outside
`test/archive_test.dart` uses them — and four of the five targets need only Rust. | Today only `macos_arm64` is built, so every other platform gets `UnsupportedError` from every digest and every archive call. |
| 2 | **Ship the binaries.** They are `.gitignore`d and `.pubignore` lets them into the package; `make release` must build all five before `dart pub publish`. Record their SHA-256 in the changelog. | Reproducibility without CI. |
| 3 | **Build hooks.** `hook/build.dart` with `package:hooks` and `package:code_assets` registering the prebuilt for the target, so `dart compile exe` bundles it. Keep the `Native` loader's path search as the fallback. | `dart run` works today; a compiled executable only finds the library next to itself. |
| 4 | **Progress from native.** A caller-owned struct the archive functions update (bytes done, entry name) and the Dart side polls into `TaskProgress`, so `Console.multiProgress` renders an extraction. | Long extractions are silent today. |
| 5 | **Rust tests.** `cargo test` with the same digest vectors the Dart tests use, and `inside()` as a unit test covering absolute paths, `C:\\`, and a UNC prefix. | The Dart side now has `test/fixtures/zip_slip.zip` and covers `../` for every format; the Rust unit test would cover the Windows shapes a macOS run cannot. |
