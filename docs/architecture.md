# Architecture

PastePal is a macOS menu-bar application written in Objective-C with AppKit. It
is a renamed and slimmed-down fork of Flycut; the shared clipboard engine and
class names are intentionally kept close to upstream to make the code easy to
compare.

## Targets

| Target | Product | Role |
| --- | --- | --- |
| `PastePal` | `PastePal.app` | Menu-bar application (`LSUIElement=1`) |
| `PastePalHelper` | `PastePalHelper.app` | Login-item helper embedded in `Contents/Library/LoginItems` |
| `PastePalTests` | `PastePalTests.xctest` | Logic tests; compiles the engine sources directly |

All targets use manual reference counting (MRC). There are no iOS targets.

## Clipboard capture

`AppController` polls `NSPasteboard` with a one-second timer. A copy is ignored
when the pasteboard's `changeCount` has not changed or tracking is disabled
(Option-click on the menu-bar icon).

Text has priority: `NSStringPboardType` is checked first, so an application that
puts both text and a TIFF representation on the pasteboard is recorded as text.
Only when no string is available does PastePal look for `public.png`,
`public.tiff`, `public.jpeg`, then `public.heic`.

Text is read on a background queue; images are read, size-checked, hashed, and
parsed on a background queue as well. Before committing a result, the main
thread verifies that the pasteboard `changeCount` still matches the value
captured when the read started. The store and UI are only modified on the main
thread.

When PastePal writes its own clipping to the pasteboard (`pbBlockCount`), the
next poll is suppressed so PastePal does not re-record its own paste.

## Data model

`FlycutClipping` represents both kinds of history entries:

- `clipKind`: `FlycutClipKindText` or `FlycutClipKindImage`.
- Text: `contents`, type, and display string, as in Flycut.
- Image: `imageHash` (SHA-256 hex), `imageFile` (file name on disk),
  `imageUTI`, pixel dimensions, and byte size. `contents` holds a human-readable
  display string such as `Image 1920×1080 · PNG · 1.2 MB`.

Equality is kind-aware: text clippings compare `contents`, while image clippings
compare `imageHash`. This prevents two different images with the same placeholder
text from being deduplicated.

## History stores

`FlycutStore` is an array of clippings ordered newest first. Insertion always
happens at index 0; when the array grows beyond `rememberNum`, the oldest entry
is deleted. That sliding window is shared by text and images.

There are two stores:

- The main history (`clippingStore`).
- The favorites store (`favoritesStore`).

When the user browses favorites, `FlycutOperator` temporarily points
`clippingStore` at the favorites store and keeps the previous store in
`stashedStore`. New clipboard captures are still written to the history store
via the operator's internal `historyStore` accessor. `mergeList` only merges
text entries.

## Image storage

`PastePalImageStore` owns image files:

- Root directory:
  `~/Library/Application Support/PastePal/Images/` (resolved through
  `NSSearchPathForDirectoriesInDomains`).
- File name: `<sha256>.<ext>`, where the extension is derived from the UTI
  (`png`, `tiff`, `jpeg`, `heic`, or `img` for unknown types).
- Writes are atomic (`NSDataWritingAtomic`) and serialized on a private serial
  queue. Writing the same hash twice reuses the existing file.
- Thumbnails and previews are produced with ImageIO's
  `CGImageSourceCreateThumbnailAtIndex`, so large originals are not fully
  decoded. An `NSCache` holds recent thumbnails.
- Pasted representations are generated from the original data where possible;
  other formats are encoded with ImageIO (JPEG/HEIC quality 0.9). At most one
  encoded representation set is cached to bound memory use.

Image binaries are never written to `NSUserDefaults`.

### Deduplication and retention

- Image deduplication is mandatory and independent of the text
  `removeDuplicates` preference. If the hash already exists in history, the
  existing entry is moved to the top.
- If the hash exists only in favorites, a new history entry is created and
  shares the same file.
- The unified `rememberNum` window can evict images when text is inserted; every
  operator-level insertion therefore runs a mark-and-sweep afterwards.
- A separate byte cap (`imageHistoryMaxBytes`, default 500 MB) counts only
  images in the history. When exceeded, the oldest non-favorite images are
  removed until the total fits.
- `imageMaxItemBytes` (default 50 MB) causes oversized clipboard images to be
  skipped before they are written to disk.
- Mark-and-sweep collects hashes from both history and favorites and deletes
  image files that are not referenced. Because all writes and sweeps run
  serially on the main thread, no grace period is needed. Favorites protect
  their files from deletion.
- There is no time-based expiration.

## Persistence

History is stored in `NSUserDefaults` under the `store` key as a hand-written
dictionary, as in Flycut. PastePal writes format version `0.8`:

- `version`, `rememberNum`, `favoritesRememberNum`
- `jcList` and `favoritesList`: arrays of clipping dictionaries
- Text entries: `Contents`, `Type`, `Position`, `AppLocalizedName`,
  `AppBundleURL`, `Timestamp`
- Image entries additionally: `Kind = image`, `ImageHash`, `ImageFile`,
  `ImageUTI`, `PixelWidth`, `PixelHeight`, `ByteSize`

On load, an image entry whose file is missing is skipped instead of producing an
empty history item. After loading, the capacity limit is enforced and
unreferenced files are swept.

## Pasteboard output

For an image clipping, PastePal declares the formats it can produce in this
order: `public.png`, `public.tiff`, `public.jpeg`, `public.heic`. The first
format is the original data; the others are generated on demand. A format that
cannot be produced is omitted. PNG is declared first so receivers prefer a
lossless representation.

Text pasteboard output is unchanged from Flycut.

## User interface

- The status-bar icon is a monochrome template image, so macOS handles light and
  dark menu bars automatically.
- The menu lists recent clippings with a 32-pixel thumbnail for image entries.
- `BezelWindow` has a text mode and an image mode. Image mode shows a preview
  decoded at a maximum of 640 pixels plus one line of dimensions/format/size
  text, so the bezel does not grow with the source image.
- The image storage limit is edited in Preferences > General. The input row is
  added programmatically so the existing XIB does not need a risky structural
  change.

## Build and CI

`PastePal.xcodeproj` builds the app, helper, and test targets. The shared
`PastePal` scheme runs the test target. GitHub Actions uses `macos-latest` with
the latest stable Xcode to build and run tests on every pull request.

The release workflow builds an unsigned archive, copies the app out, signs the
helper and app ad-hoc from the inside out with hardened runtime, verifies the
signature, creates a DMG with an Applications symlink, and publishes the DMG and
its SHA-256 checksum for `v*` tags. No Developer ID certificate or Apple
notarization is used.
