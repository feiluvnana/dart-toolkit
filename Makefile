# dart-toolkit — the release steps, in the order a release runs them.
#
#   make            analyze, format check, tests
#   make native     build the Rust library for this machine into native/prebuilt/<target>/
#   make bench      startup cost per module, and the digest/parser throughput probes
#   make release    everything above, then the version bump reminder

DART ?= dart
TARGET := $(shell $(DART) run --packages=.dart_tool/package_config.json tool/target.dart 2>/dev/null)

.PHONY: all check format analyze deps test native native-clean audit bench startup release clean

all: check test

check: analyze format

analyze:
	$(DART) analyze --fatal-infos

format:
	$(DART) format --output=none --set-exit-if-changed lib bin example test tool

test:
	$(DART) test

## The native library. Needs cargo; nothing else. Cross-compiling other targets needs
## `cargo install cargo-zigbuild` and zig, then `make native TARGET=linux_x64 RUST_TARGET=x86_64-unknown-linux-gnu`.
native:
	cd native && cargo build --release $(if $(RUST_TARGET),--target $(RUST_TARGET),)
	mkdir -p native/prebuilt/$(TARGET)
	cp native/target/$(if $(RUST_TARGET),$(RUST_TARGET)/,)release/*dart_toolkit_native.* native/prebuilt/$(TARGET)/
	@ls -la native/prebuilt/$(TARGET)/

native-clean:
	cd native && cargo clean

## The archive parsers read files from the internet, so the release checks them for advisories.
## `cargo install cargo-audit` if it is missing; the target says so rather than failing silently.
audit:
	@command -v cargo-audit >/dev/null 2>&1 \
		&& (cd native && cargo audit) \
		|| echo "cargo-audit not installed: cargo install cargo-audit (skipping advisory check)"

startup:
	$(DART) run tool/startup.dart

bench: startup
	$(DART) run example/collections.dart > /dev/null && echo "collections example: ok"

release: check test native audit
	@echo "Bump version in pubspec.yaml and move Unreleased in CHANGELOG.md, then: git tag v$$(grep '^version' pubspec.yaml | cut -d' ' -f2)"

clean: native-clean
	rm -rf .dart_tool/pub coverage
