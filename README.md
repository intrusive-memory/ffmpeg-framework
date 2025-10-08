# FFmpeg Framework Swift Package

This package wraps the FFmpeg project in a Swift Package Manager compatible
layout. The build tooling fetches FFmpeg from the official GitHub repository,
compiles the constituent static libraries for the Apple platforms supported by
SwiftPM, and emits XCFramework bundles that can be shipped as binary targets.
The current GitHub Actions configuration focuses on delivering a macOS
Apple Silicon (`arm64`) build, which is the only variant produced by the
automated pipeline.

## Repository layout

- `Scripts/build-ffmpeg.sh` – orchestrates cloning FFmpeg, compiling each static
  library for the supported Apple SDKs, and packaging the results into
  `.xcframework` bundles under `Artifacts/xcframeworks`.
- `.github/workflows/build.yml` – GitHub Actions workflow that runs the build
  script with the same configuration used locally, archives the generated
  XCFrameworks, computes SwiftPM checksums, and publishes artifacts when a
  release is created.

## Prerequisites

Local builds require the following tooling installed through Xcode and
Homebrew:

- Xcode 16.4 (or later) with the command line tools installed.
- Command line utilities: `git`, `nasm`, `yasm`, `pkg-config`, `automake`,
  `cmake`, `ninja`, and `meson`.

The GitHub Actions workflow automatically installs these tools on the macOS
runners.

## Building locally

```bash
# Build FFmpeg for all supported Apple platforms and package the XCFrameworks.
Scripts/build-ffmpeg.sh

# Build the macOS Apple Silicon variant that matches the CI pipeline.
Scripts/build-ffmpeg.sh --platform macos

# Build a specific platform only (e.g. iOS simulator).
Scripts/build-ffmpeg.sh --platform ios-simulator

# Use a different FFmpeg ref or branch.
Scripts/build-ffmpeg.sh --ffmpeg-ref n6.1.1
```

Artifacts are produced under `Artifacts/xcframeworks`. Each generated bundle can
be zipped and attached to a GitHub release to be consumed via SwiftPM binary
targets.

## Continuous integration

The `Build FFmpeg XCFrameworks` workflow runs on pushes, pull requests, manual
invocations, and release publication. It performs the following steps:

1. Selects the Xcode 16.4 toolchain to match local builds.
2. Installs the Homebrew dependencies required by FFmpeg.
3. Runs `Scripts/build-ffmpeg.sh --platform macos` (optionally with a custom
   FFmpeg ref when triggered manually) to produce a macOS Apple Silicon build.
4. Archives the XCFramework directory, computes SwiftPM checksums for each
   bundle, and uploads the results as workflow artifacts.
5. On release events, attaches the generated archives and checksum files to the
   GitHub release via `softprops/action-gh-release`.

These artifacts can be referenced from `Package.swift` as binary targets once a
release has been created.
