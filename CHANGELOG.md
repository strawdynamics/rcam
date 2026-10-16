# Changelog

All notable changes to RCam are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and RCam uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.2] - 2026-XX-XX

The first public release. RCam is now free and open source under the MIT
License.

### Added

- Turn RTSP security and IP camera streams into a macOS virtual camera you can
  pick in Zoom, Meet, FaceTime, Photo Booth and more.
- Camera presets that fill in the stream URL for common camera and NVR
  platforms, with a choice between each camera's main stream and substream.
- Camera usernames and passwords are kept in your Keychain, never in plain-text
  settings.
- Automatic reconnect: if a stream drops, RCam retries with a growing delay
  (up to 30 seconds) and reconnects as soon as your Mac wakes from sleep.
- Placeholder frames while a camera connects or reconnects, so your video
  never freezes mid-call.
- Automatic updates. RCam checks for new versions and waits until the camera
  isn't in use before asking you to update. You can turn automatic checks off
  in Settings › General, or check any time with "Check for Updates…".

### Changed

- RCam is now free, with no in-app purchase and no watermark.
- RCam is now distributed from GitHub instead of the Mac App Store. Help and
  bug reports go through GitHub Issues.
