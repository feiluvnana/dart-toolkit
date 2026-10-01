# dart-toolkit — the release steps, in the order a release runs them.
#
#   make            analyze, format check, tests
#   make native     build the Rust library for this machine into native/prebuilt/<target>/
#   make bench      startup cost per module
#   make release    everything above, then the version bump reminder

DART ?= dart

# The folder under native/prebuilt/ — `<os>_<arch>`, as NativeBridge.target names it — for
# RUST_TARGET when one is given, else for this machine.
os_of = $(if $(findstring darwin,$1),macos,$(if $(findstring windows,$1)$(findstring MINGW,$1)$(findstring MSYS,$1),windows,linux))
arch_of = $(if $(findstring aarch64,$1)$(findstring arm64,$1),arm64,x64)
HOST := $(shell uname -sm | tr 'A-Z ' 'a-z-')
TARGET := $(if $(RUST_TARGET),$(call os_of,$(RUST_TARGET))_$(call arch_of,$(RUST_TARGET)),$(call os_of,$(HOST))_$(call arch_of,$(HOST)))
LIB := $(if $(findstring macos,$(TARGET)),libdart_toolkit_native.dylib,$(if $(findstring windows,$(TARGET)),dart_toolkit_native.dll,libdart_toolkit_native.so))
# Another OS links through zig; another mac architecture links with Apple's own toolchain.
CARGO := $(if $(and $(RUST_TARGET),$(if $(findstring darwin,$(RUST_TARGET)),,cross)),cargo zigbuild,cargo build)

.PHONY: all check format analyze test native native-clean audit bench startup release clean

all: check test

check: analyze format

analyze:
	$(DART) analyze --fatal-infos

format:
	$(DART) format --output=none --set-exit-if-changed lib bin test tool

test:
	$(DART) test

## The native library. Needs cargo; nothing else. Another mac architecture needs
## `rustup target add x86_64-apple-darwin`; another OS needs zig and `cargo install cargo-zigbuild`:
##   make native RUST_TARGET=x86_64-unknown-linux-gnu      -> native/prebuilt/linux_x64/
native:
	cd native && $(CARGO) --release $(if $(RUST_TARGET),--target $(RUST_TARGET),)
	mkdir -p native/prebuilt/$(TARGET)
	cp native/target/$(if $(RUST_TARGET),$(RUST_TARGET)/,)release/$(LIB) native/prebuilt/$(TARGET)/
	@ls -la native/prebuilt/$(TARGET)/

native-clean:
	cd native && cargo clean

## The archive parsers read files from the internet, so the release checks them for advisories.

audit:
	@command -v cargo-audit >/dev/null 2>&1 \
		&& (cd native && cargo audit) \
		|| echo "cargo-audit not installed: cargo install cargo-audit (skipping advisory check)"

startup:
	$(DART) run tool/startup.dart

bench: startup

release: check test native audit
	@echo "Bump version in pubspec.yaml and move Unreleased in CHANGELOG.md, then: git tag v$$(grep '^version' pubspec.yaml | cut -d' ' -f2)"

clean: native-clean
	rm -rf .dart_tool/pub coverage
