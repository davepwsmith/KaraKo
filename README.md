# KaraKo

Read your [Karakeep](https://karakeep.app) articles on a Kobo, via
[KOReader](https://koreader.rocks).

`karakeep.koplugin` syncs unread bookmarks onto the device as EPUBs, and pushes
your read status and highlights back to Karakeep when you are done with them.

It is modelled on KOReader's [`wallabag.koplugin`][wallabag], which solves the
same problem for a different read-it-later service.

[wallabag]: https://github.com/koreader/koreader/tree/master/plugins/wallabag.koplugin

## What it does

- Downloads unread bookmarks as EPUBs, built on device from Karakeep's crawled
  article HTML, with images embedded.
- Syncs everything unarchived, or just one Karakeep list or tag.
- Archives an article in Karakeep once you finish it, optionally tagging it and
  deleting the local copy.
- Sends the highlights you make in KOReader back to Karakeep.
- Cleans up local copies of articles you archived elsewhere.

## Requirements

- A Karakeep server, and an API key from **Settings → API Keys**.
- KOReader installed on the device. Any KOReader version with `ffi/archiver` and
  `cre.getBalancedHTML` will do — that is anything from 2021 onwards.

## Install

Copy the plugin folder into KOReader's `plugins` directory:

| Device | Destination |
| --- | --- |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/karakeep.koplugin/` |
| Kindle | `/mnt/us/koreader/plugins/karakeep.koplugin/` |
| Desktop / emulator | `<koreader>/plugins/karakeep.koplugin/` |

```sh
git clone https://github.com/davepwsmith/karako
cp -r karako/karakeep.koplugin /mnt/onboard/.adds/koreader/plugins/
```

Restart KOReader. The plugin appears under **Tools → More tools → Karakeep**
(the hamburger menu in the file manager).

## Set up

1. **Karakeep → Server.** Enter your server's base address (e.g.
   `https://karakeep.example.com`, or `http://192.168.1.10:3000` on a LAN) and
   your API key. `Save and test` reports whether the address and key work — a
   pasted `/api/v1` suffix is stripped for you.
2. **Karakeep → Download folder.** Pick where articles should live. On a Kobo,
   somewhere under `/mnt/onboard` keeps them visible in the native library too.
3. **Karakeep → What to sync.** All unarchived bookmarks (the default), or a
   single list or tag — the plugin fetches your lists and tags to choose from.
4. **Karakeep → Synchronise now.**

You can bind *Synchronise Karakeep* to a gesture under
**Settings → Gestures**.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| What to sync | All unread | All unarchived bookmarks, or one list or tag |
| Articles per sync | 30 | Fetches the most recent unread articles, up to this many |
| Embed images | On | Off gives much smaller files and faster syncs |
| Archive it in Karakeep | On | When you mark an article as finished |
| Archive when 100% read | On | Reaching the last page counts as finished |
| Archive when abandoned | Off | Treat "abandoned" as done |
| Also add a tag | Off | e.g. `read-on-kobo`, created if it does not exist |
| Delete the local copy once archived | On | Off keeps finished articles on device |
| Send highlights to Karakeep | On | See the caveat below |

## How highlights are matched

This is the one part that is best-effort, and it is worth understanding.

KOReader records a highlight's position as a crengine XPointer into *the EPUB
this plugin generated*. Karakeep's `/highlights` API wants character offsets into
*its own* rendered content. Those two coordinate systems have nothing in common,
so the only thing the two sides genuinely share is the highlighted text itself.

So the plugin matches on text:

- A passage found exactly once gets correct offsets.
- A passage appearing more than once resolves to its **first** occurrence, which
  may not be the one you highlighted.
- A passage that cannot be found at all is still sent, with the text and your
  note intact but no position (offsets `0,0`). Losing the note seemed worse than
  an unanchored highlight.
- Highlights already in Karakeep with the same text are skipped, so repeated
  syncs do not pile up duplicates.

Your note and the chapter title travel with the highlight. Highlight colours are
mapped onto the four Karakeep supports; anything else becomes yellow.

## Notes and limitations

- **Karakeep has no EPUB export endpoint**, unlike Wallabag, so the plugin builds
  the EPUB itself: it sanitises the crawled HTML, hands it to crengine's
  `getBalancedHTML()` to make it well-formed, fetches images, and writes the
  container with `ffi/archiver`. Image-heavy articles are noticeably slower on
  Kobo hardware than a plain text sync — turn off *Embed images* if you mind.
- **Only `link` and `text` bookmarks sync.** Asset bookmarks (uploaded PDFs and
  images) are skipped; they are already in a readable format and do not need us.
- **WebP images are skipped**, because crengine does not render them. Image types
  are detected from their magic bytes rather than the URL's extension, and any
  image that fails to download has its `<img>` removed so you never see a broken
  image box.
- **Local deletion is conservative.** Articles are only removed when the sync saw
  your whole library uninterrupted — never after a capped or cancelled run — and
  never if you have opened them. An article archived on another device is tidied
  up on the next full sync. A consequence worth knowing: if your unread count
  exceeds *Articles per sync*, every run is capped, so this cleanup never
  happens until the backlog drops below the limit.
- **The API key is stored in the clear** in
  `koreader/settings/karakeep.lua`, as KOReader has no keystore. It is worth
  giving the device its own key so you can revoke just that one.

## Optionally, an OPDS bridge

If you would rather have the EPUBs generated server-side, [yazdipour/karakeep-opds][opds]
exposes Karakeep as an OPDS catalog that KOReader's built-in OPDS browser can
read. It produces nicer EPUBs than anything achievable in Lua on a Kobo.

It is not a replacement for this plugin, though — OPDS is a download-only
protocol, so nothing flows back: no archive-on-finish and no highlights. The two
compose well, since its acquisition links carry the Karakeep bookmark ID
(`/opds/bookmarks/{id}.epub`).

[opds]: https://github.com/yazdipour/karakeep-opds

## Development

```sh
make test   # runs the specs with any Lua 5.1
make check  # syntax check every file
```

`articleutil.lua` has no KOReader dependencies and carries the bulk of the
fiddly logic, so it is directly testable off-device. See [TESTING.md](TESTING.md)
for how to exercise the rest against a real KOReader.

## Licence

AGPL-3.0-or-later, matching KOReader, whose modules this plugin builds on.
