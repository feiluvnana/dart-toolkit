# dart-toolkit — the release steps, in the order a release runs them. Every recipe is a `dart`
# or `cargo` command, so it runs the same from sh on macOS and Linux and from cmd on Windows.
#
#   make                 analyze, format check, catch check, tests
#   make native          build the native libraries for this machine into native/lib/<os>_<arch>/
#   make native-all      every target this machine can cross-build
#   make native-release  native-all, then the GitHub release a first use downloads from
#   make bench           throughput per case (AOT) and startup cost per module
#   make release         everything above, then the version bump reminder

DART ?= dart

ifeq ($(OS),Windows_NT)
BENCH = .dart_tool\bench\runner.exe
else
BENCH = .dart_tool/bench/runner
endif

.PHONY: all check format analyze catches test native native-all native-release audit bench bench-build bench-check release clean

all: check test

FORMATTED = lib test tool example

check: analyze format catches

## Every empty catch in lib/ says why on its line: an error is never swallowed unexplained.
catches:
	$(DART) run tool/check_catches.dart

analyze:
	$(DART) analyze --fatal-infos

format:
	$(DART) format --output=none --set-exit-if-changed $(FORMATTED)

test:
	$(DART) test

## The native libraries (dart_toolkit_native, dart_toolkit_torrent). A program builds them on its
## first use too; this is for after an edit to native/.
native:
	$(DART) run tool/build_native.dart

native-all:
	$(DART) run tool/build_native.dart --all

## Needs native/ committed and `gh` signed in: the release is named by the hash of native/.
native-release:
	$(DART) run tool/build_native.dart --release

## The archive parsers read files from the internet, so the release checks them for advisories
## (cargo install cargo-audit).
audit:
	cargo audit --file native/Cargo.lock

## Throughput is measured AOT, one process per case (its own peak RSS); startup stays JIT. AOT has
## no package root, so the native libraries go beside the runner.
bench-build:
	$(DART) run tool/build_native.dart --copy-to .dart_tool/bench
	$(DART) compile exe tool/bench/runner.dart -o $(BENCH)

bench: bench-build
	$(BENCH)
	$(DART) run tool/module_bench.dart

bench-check: bench-build
	$(BENCH) --check

release: check test native audit bench-check
	@echo Bump the version in pubspec.yaml, move Unreleased in CHANGELOG.md, run make native-release, then tag the version.

clean:
	$(DART) run tool/build_native.dart --clean
