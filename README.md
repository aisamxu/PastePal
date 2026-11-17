# PastePal

PastePal is a lightweight, native macOS clipboard manager with text and image
history. It lives in the menu bar, remembers what you copy, and lets you paste
an earlier clipping with a keyboard shortcut or from the menu.

PastePal is a macOS-only fork of the MIT-licensed
[Flycut](https://github.com/TermiT/Flycut) project, built with Objective-C and
AppKit.

## Features

- Text and image clipboard history in a single timeline
- Global hotkey (Shift-Command-V by default) with the translucent bezel
- Search, favorites, merge, delete, and clear
- Image thumbnails in the menu and a large preview in the bezel
- Image deduplication by SHA-256: copying the same image again moves it to the top
- One sliding-window limit for text and images (`rememberNum`, 40 by default)
- Configurable image storage cap (500 MB by default) and a 50 MB per-image limit
- Favorites are never removed automatically
- Fully local: no iCloud/CloudKit, no network sync, no analytics

## Requirements

- macOS 10.13 or later
- Accessibility permission so PastePal can paste into other applications

## Installation

Build from source with Xcode (see [Development](#development)), or download the
DMG from the GitHub Releases page when a release is available.

PastePal is distributed as an ad-hoc signed build and is not notarized by
Apple. On first launch:

1. Open the DMG and drag PastePal to Applications.
2. Right-click PastePal in Applications and choose **Open**.
3. Grant Accessibility permission when prompted (System Settings > Privacy &
   Security > Accessibility).

If macOS still blocks the app, remove the quarantine attribute:

```sh
xattr -dr com.apple.quarantine /Applications/PastePal.app
```

The ad-hoc signature changes with every build, so macOS may ask for
Accessibility permission again after an update. If pasting stops working, reset
and re-grant the permission:

```sh
tccutil reset Accessibility io.github.aisamxu.PastePal
```

## Usage

- Copy normally. PastePal records text and images in the background.
- Press Shift-Command-V to open the bezel; use the arrow keys to browse,
  Return to paste, and Esc to close.
- Press Command-, or choose Preferences from the menu for settings.
- The menu-bar menu lists recent clippings. Option-click the menu-bar icon to
  pause or resume clipboard tracking.
- See [help.md](help.md) for the complete keyboard reference.

### Images

PastePal captures clipboard images as PNG, TIFF, JPEG, or HEIC. When a copy
contains both text and an image, the text is recorded instead.

- Images follow the same `rememberNum` sliding window as text.
- Duplicate images are detected by SHA-256 and moved to the top instead of
  being stored twice.
- The image storage limit (Preferences > General) defaults to 500 MB. When it
  is exceeded, the oldest images that are not favorites are removed until the
  limit is met.
- A single image larger than 50 MB is skipped.
- Clearing history deletes image files that are no longer referenced by
  history or favorites.
- Favorites are exempt from automatic cleanup, so actual disk usage can exceed
  the configured limit.
- Images do not expire based on age.

## Privacy

PastePal keeps history on the local Mac. Text and image metadata are stored in
the app's user defaults; image files are stored in
`~/Library/Application Support/PastePal/Images/`. PastePal does not sync to
iCloud, does not use CloudKit, and does not send clipboard data anywhere.

## Development

PastePal requires a full Xcode installation to build. The repository uses
GitHub Actions on macOS runners for compilation and tests; local development can
use Xcode or `xcodebuild`:

```sh
xcodebuild \
  -project PastePal.xcodeproj \
  -scheme PastePal \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The project has three targets:

| Target | Purpose |
| --- | --- |
| `PastePal` | Menu-bar application |
| `PastePalHelper` | Login-item helper |
| `PastePalTests` | Unit tests for clipping, store, operator, and image storage |

See [docs/architecture.md](docs/architecture.md) for the engine, persistence
format, and image storage design. `.github/workflows/ci.yml` runs on every pull
request; `.github/workflows/release.yml` builds the ad-hoc signed DMG when a
`v*` tag is pushed.

## License

PastePal is distributed under the MIT License. See [LICENSE](LICENSE) and
[NOTICE](NOTICE) for the original Flycut and Jumpcut attribution. Third-party
library credits are listed in [acknowledgements.txt](acknowledgements.txt).
