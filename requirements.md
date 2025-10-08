# Requirements:

- Find a reliable way to download the source code to ffmpeg. The repo is at [github.com/ffmpeg/ffmpeg.](https://github.com/FFmpeg/FFmpeg.git)
  I believe you have to use something configured in the .github actions build file but double check my knowledge on that.

- For each supporting library in root directory, compile an .xcframework source. Add the building of those frameworks to
  the github actions. Use directives in the Swift Package as much as possible and use the latest versions of the xcode tooling as defined here:
  https://github.com/stovak/SwiftScreenplay/blob/main/.github/workflows/tests.yml

- When the build is complete, I sould be able to reference this package in the swift package manager
  and add it to any other project to be able to use ffmpeg in swift in any project.
