# Security policy

## Reporting a vulnerability

Please report security issues **privately**, through GitHub's private vulnerability reporting: open the repository's [Security tab](https://github.com/strawdynamics/rcam/security) and choose **Report a vulnerability**. Don't open a public issue, pull request or discussion for them.

Include the RCam version (Settings › General › Version, which has a Copy button), your macOS version, what an attacker can do, and steps to reproduce. A proof of concept helps but isn't required. You'll get a reply in the advisory thread, and a fix ships as a normal release through the app's automatic updates.

Only the latest release is supported. Please check that the issue still reproduces there.

## Scope

In scope:

- The RCam app, its camera system extension, and `rcamcli`, as built from this repository.
- How RCam stores and handles camera credentials (the Keychain, and URLs in memory and in logs).
- The update path: the Sparkle feed at `https://rcam.strawdynamics.com/appcast.xml`, update signature checks, and the signed, notarized DMGs on GitHub Releases.
- The release pipeline in `.github/workflows/` and `scripts/`, if a change from outside could make it publish something it shouldn't.
- How RCam builds and links its vendored FFmpeg (for example, if RCam enables a vulnerable code path or skips a fix).

Out of scope:

- Vulnerabilities in FFmpeg, Sparkle or macOS themselves. Report those upstream. If one affects RCam, please do let us know so we can ship an update.
- The security of your cameras, their firmware, or RTSP itself. RTSP streams are usually unencrypted, and anyone on your network can read them. RCam can't change that.
- Attacks that need an attacker who already has admin rights on your Mac, or physical access to it while it's unlocked.
- The project website, beyond the appcast above.
