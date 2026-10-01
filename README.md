# R2Drop

A native macOS menu bar app that uploads screenshots and images straight to a
Cloudflare R2 bucket and copies the link to your clipboard. It is the native
rewrite of the
[R2 Image Uploader](https://github.com/yongkang-yang/raycast-r2-image-uploader)
Raycast extension, without Raycast (or the AWS SDK) underneath it.

## Commands

Every command has its own global shortcut (Settings → Shortcuts) and a place in
the menu bar menu.

- **Capture & Upload** — the native interactive screenshot (`screencapture -i`:
  drag a region, or Space for a window), uploaded, link copied. Bind it to
  something like `⌥⇧4` for a screenshot → clipboard-link flow.
- **Upload Clipboard Image** — uploads the image on the clipboard (a copied
  screenshot, an image copied from a browser or app, or a file copied in Finder)
  and replaces it with the link.
- **Upload Image…** — an open panel for one or more images, with the output
  format and an optional name below it. The name only applies to a single file.
- **Upload Finder Selection** — uploads the images selected in Finder.
- **Preview Last Upload** — the most recent upload at full size, with its key,
  time and URL, and buttons to copy the link or open it.
- **Drop images on the menu bar icon** to upload them.
- **Capture to BlogWatcher** — the same interactive screenshot, uploaded and
  saved to a [BlogWatcher](https://github.com/yongkang-yang/blogwatcher) inbox
  together with the text recognised in it (on this Mac, Chinese and English),
  so it can be found by searching. The clipboard is left alone. Set the
  deployment's capture URL and key under Settings → BlogWatcher; the command
  appears in the menu once they are set.

The menu shows the last upload with its thumbnail; click it to copy its link
again in your default format.

## Setup

1. In the Cloudflare dashboard, create an R2 bucket and an S3 API token (Access
   Key ID + Secret Access Key) with write access to it.
2. Bind a custom domain to the bucket (recommended over the `r2.dev` URL) to use
   as the **Public Base URL**.
3. Open R2Drop; Settings opens on first run. Fill in Account ID, Bucket, Access
   Key ID, Secret Access Key and Public Base URL, and pick what to copy after an
   upload: URL, Markdown, HTML, or Markdown with the file name as alt text.

The secret is kept in the login keychain. Requests are signed on this Mac
(AWS Signature Version 4, via CryptoKit) and sent straight to
`<account>.r2.cloudflarestorage.com` — no intermediary server.

macOS asks for **Screen Recording** the first time you capture, and for control
of **Finder** the first time you upload a Finder selection.

### Moving over from the Raycast extension

Raycast keeps extension preferences encrypted, so copy them by hand: open Raycast
→ Settings → Extensions → R2 Image Uploader and carry the six preferences into
Settings → R2, and your command hotkeys into Settings → Shortcuts. Remove the
hotkeys from Raycast first: while Raycast holds a shortcut, R2Drop can't
register it and says so under the recorder.

## Object keys

Uploads are stored as `yyyy/mm/<name>-<hash>.<ext>`, e.g.
`2026/09/survey2-team-list-a8f31c.png`, exactly as the extension named them. The
trailing hash avoids collisions; the name is the file's, or the one given in
Upload Image.
Screenshots saved to BlogWatcher get a 16-character hash instead of 6: the
inbox is private, and the link is all that keeps its images so.

## Build

Requires macOS 14+ and Xcode (Swift 6 toolchain).

```sh
swift test               # SigV4 against AWS's worked examples, keys, formats
./Scripts/bundle.sh      # → build/R2Drop.app, installed in /Applications
```

`bundle.sh` wraps the binary in an `.app`, signs it with your Developer ID or
Apple Development certificate (falling back to ad-hoc; set `CODESIGN_IDENTITY`
to choose one) so the privacy grants and keychain item survive rebuilds, and
installs it over `/Applications/R2Drop.app`, quitting and relaunching a running
copy. Pass `--no-install` to stop at `build/`. The icon is drawn by
`swift Scripts/make-icon.swift`.

## License

[GPL-3.0-or-later](LICENSE). Cloudflare and R2 are trademarks of Cloudflare,
Inc.; this is an unofficial client.
