# Changelog

All notable changes to PastePal are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## 1.0.0 - Unreleased

Initial PastePal release, based on a snapshot of the upstream Flycut `master`
branch. The application is macOS-only and keeps history entirely on the local
Mac.

### Added

- Menu-bar clipboard history with the translucent bezel, search, favorites,
  merge, delete, and clear.
- Image clipboard history in the same timeline as text, with PNG, TIFF, JPEG,
  and HEIC capture and pasteboard output.
- SHA-256 image deduplication: copying an existing image moves it to the top of
  the history without storing a second copy.
- Unified `rememberNum` sliding window for text and images, plus a configurable
  image storage cap (500 MB by default) and a 50 MB per-image limit.
- Image thumbnails in the menu and a large preview with dimensions, format, and
  byte size in the bezel.
- Mark-and-sweep cleanup that removes unreferenced image files after delete,
  clear, and capacity eviction. Favorites are never removed automatically.
- Unit tests for clipping equality, image storage, deduplication, eviction,
  favorites protection, and persistence.
- GitHub Actions CI and an ad-hoc signed DMG release workflow with SHA-256
  checksums.

### Changed

- Renamed the application, targets, preferences domain, and bundle identifiers
  to PastePal.
- New application icon and monochrome menu-bar template icons.
- Persistence format extended to version 0.8 to store image metadata; version
  0.7 text-only data remains readable.

### Removed

- All iOS targets, iOS-only dependencies, and iOS build configuration.
- iCloud/CloudKit synchronization and related preferences and entitlements.
- App Store, notarization, and Developer ID release automation.
