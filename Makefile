# dart-toolkit — the release steps, in the order a release runs them.
#
#   make            analyze, format check, tests
#   make native     build the Rust library for this machine into native/prebuilt/<target>/
#   make bench      startup cost per module
#   make release    everything above, then the version bump reminder

DART ?= dart

.PHONY: all check format analyze test native native-all native-clean audit bench startup release clean

all: check test

check: analyze format

analyze:
	$(DART) analyze --fatal-infos

format:
	$(DART) format --output=none --set-exit-if-changed lib bin test tool

test:
	$(DART) test

## The native library. Builds into native/prebuilt/<os>_<arch>/.
##   make native                                           -> host platform
##   make native RUST_TARGET=x86_64-unknown-linux-gnu      -> native/prebuilt/linux_x64/
##   make native-all                                       -> all supported platforms
native:
	$(DART) run tool/native.dart $(if $(RUST_TARGET),--target=$(RUST_TARGET),)

native-all:
	$(DART) run tool/native.dart --all

native-clean:
	$(DART) run tool/native.dart --clean-only

## The archive parsers read files from the internet, so the release checks them for advisories.

audit:
	@command -v cargo-audit >/dev/null 2>&1 \
		&& (cd native && cargo audit) \
		|| echo "cargo-audit not installed: cargo install cargo-audit (skipping advisory check)"

bench:
	$(DART) run tool/bench.dart

startup: bench

release: check test native audit
	@echo "Bump version in pubspec.yaml and move Unreleased in CHANGELOG.md, then: git tag v$$(grep '^version' pubspec.yaml | cut -d' ' -f2)"

clean: native-clean
	rm -rf .dart_tool/pub coverage
