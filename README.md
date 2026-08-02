> [!CAUTION]
> This plugin is vibe-coded with Claude Code. I have done my best to review the
> output and believe it to be reasonable, and have tested on a Kobo reader - but
> treat it with the caution that anything vibe-coded deserves!

# KaraKo

Read your [Karakeep](https://karakeep.app) articles on a Kobo, via
[KOReader](https://koreader.rocks).

`karako.koplugin` syncs unread bookmarks onto the device as EPUBs, and pushes
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
- Optionally syncs when Wi-Fi connects, without interrupting your reading.
- Cleans up local copies of articles you archived elsewhere.

## Requirements

- A Karakeep server, and an API key from **Settings → API Keys**.
- KOReader installed on the device. Downloading needs `ffi/archiver` and
  `cre.getBalancedHTML`, which is anything from 2021 onwards.
- **Sending highlights back needs KOReader 2024.04 or newer**, which is where
  highlights and bookmarks were merged into the single `annotations` sidecar
  table this reads. On an older build everything else works and highlight
  syncing simply finds nothing; the log says so once per article.

## API key scopes

Karakeep lets you scope an API key per resource. The plugin touches six, and
needs **None** for everything else — no Backups, Feeds, Prompts, Rules, Webhooks,
or any Admin scope:

| Resource | Access | Needed for |
| --- | --- | --- |
| **Bookmarks** | Read/write | Everything. Read to list and fetch articles; write to archive them |
| **Assets** | Read | Page archives, and a fallback for article text. Optional |
| **Highlights** | Read/write | Sending highlights back. Read first, to avoid duplicates |
| **Lists** | Read | Only the "choose a list" picker |
| **Tags** | Read | Only the "choose a tag" picker |
| **User account** | Read | Only the `Save and test` button |
| *everything else* | None | Never called |

**Assets: Read is the one you can skip.** Ordinary article text arrives inline
under Bookmarks: Read, whatever its length. Assets: Read is needed only to read a
saved page archive, and as a safety net when Karakeep fails to expand a large
article itself — see [Where article text comes from](#where-article-text-comes-from).

Two of these are not what you would guess, so they are worth stating plainly.
Both were confirmed against Karakeep's own scope enforcement in
`packages/trpc/index.ts`, where a tRPC query needs `read` and a mutation needs
`readwrite` on whichever resource its router is scoped to:

- **Syncing a list or a tag does not need the Lists or Tags scope.**
  `GET /lists/{id}/bookmarks` and `GET /tags/{id}/bookmarks` both call
  `api.bookmarks.getBookmarks` internally, so Bookmarks: Read covers them. Lists
  and Tags are needed only so the settings menu can show you what to pick from.
- **Tagging on archive needs Bookmarks: Read/write, not Tags: Read/write.**
  `POST /bookmarks/{id}/tags` routes through `api.bookmarks.updateTags`.

### Cutting it down further

Each write scope maps to one feature, so you can grant less if you turn the
matching feature off:

| If you want | Grant |
| --- | --- |
| Downloads only, nothing written back | Bookmarks: **Read** |
| …plus saved page archives as a content source | Assets: **Read** |
| …plus archive on finish, and tag on archive | Bookmarks: **Read/write** |
| …plus highlights sent back | Highlights: **Read/write** |
| …plus picking a list or tag in the menu | Lists: **Read**, Tags: **Read** |
| …plus the connection test button | User account: **Read** |

A key missing a scope fails that one call with `403 API key is missing required
scope: <scope>`, which the log records — the rest of the sync carries on.

Give the device its own key rather than reusing one, so you can revoke just that
one if you lose the Kobo.

## Install

Copy the plugin folder into KOReader's `plugins` directory:

| Device | Destination |
| --- | --- |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/karako.koplugin/` |
| Kindle | `/mnt/us/koreader/plugins/karako.koplugin/` |
| Flatpak | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/karako.koplugin/` |
| AppImage | `~/.config/koreader/plugins/karako.koplugin/` |
| Desktop / emulator | `<koreader>/plugins/karako.koplugin/` |

```sh
git clone https://github.com/davepwsmith/karako
cp -r karako/karako.koplugin /mnt/onboard/.adds/koreader/plugins/
```

Restart KOReader. The plugin appears under **Tools → More tools → KaraKo**
(the hamburger menu in the file manager).

### Flatpak and AppImage

These two do not use the `plugins` directory next to the application — that one
is read-only under Flatpak. KOReader also scans a writable plugin directory
inside its data directory, and that is where the plugin has to go:

```sh
mkdir -p ~/.var/app/rocks.koreader.KOReader/config/koreader/plugins
cp -r karako/karako.koplugin ~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/
```

`datastorage.lua` picks that path whenever `FLATPAK`, `APPIMAGE` or
`KO_MULTIUSER` is set in the environment: the data directory becomes
`$XDG_CONFIG_HOME/koreader`, which Flatpak redirects into
`~/.var/app/rocks.koreader.KOReader/config`. Confirm the plugin was found with:

```sh
flatpak run rocks.koreader.KOReader 2>&1 | grep -iE "Looking for plugins|karako"
```

You want two lines — the directory being scanned, and `Plugin loaded karako`.

One further Flatpak gotcha: the sandbox restricts filesystem access, so the
**download folder must be somewhere KOReader can write**. Check what it is
allowed to reach with `flatpak info --show-permissions rocks.koreader.KOReader`,
and grant more if you need to:

```sh
flatpak override --user --filesystem=~/Books rocks.koreader.KOReader
```

## If a sync downloads nothing

The most common cause is the download folder. Before fetching anything, KaraKo
now checks that the folder exists — creating it if not — and that it can
actually write there, and says so plainly if it cannot. Previously an unwritable
folder surfaced only as every article failing to build, one line at a time, deep
inside the zip writer.

Under Flatpak this is the likely default rather than an edge case: the sandbox
reaches very little of your filesystem. Check what it is allowed:

```sh
flatpak info --show-permissions rocks.koreader.KOReader
flatpak override --user --filesystem=~/Books rocks.koreader.KOReader
```

Anywhere under the data directory itself always works, because KOReader owns it:

```
~/.var/app/rocks.koreader.KOReader/config/koreader/karako/
```

On a Kobo, somewhere under `/mnt/onboard` is both writable and visible to the
native library.

If the folder is fine and articles still fail, the sync summary now names the
first reason, and the log has one line per failure tagged `KaraKo:`.

## Seeing the log

KOReader logs to standard output, so start it from a terminal:

```sh
flatpak run rocks.koreader.KOReader          # Flatpak
./koreader-*.AppImage                        # AppImage
```

The default log level is `info`, which hides this plugin's `logger.dbg` lines —
including every API request. Pass `-d` for debug, or `-d -v` for verbose:

```sh
flatpak run rocks.koreader.KOReader -d
```

It can also be turned on persistently in the UI, under
**Help → Report a bug → Enable verbose logging**.

The first thing the plugin logs is which copy of itself is running, which is the
quickest way to catch a stale install — the line numbers in a stack trace will
not tell you:

```
INFO  KaraKo: version 0.6.0, main.lua modified 2026-08-02 09:14:03, loaded from …/plugins/karako.koplugin
```

If that timestamp is older than your last `cp`, KOReader is running the previous
copy. Delete the destination folder before copying over it.

Lines from this plugin are tagged `KaraKo:`, and HTTP requests `KaraKoApi:`:

```sh
flatpak run rocks.koreader.KOReader -d 2>&1 | grep -iE "karako"
```

Note that on desktop platforms nothing redirects output to `crash.log`, unlike
on a Kobo or Kindle — stdout is the only place the log appears.

## Set up

1. **KaraKo → Server.** Enter your server's base address (e.g.
   `https://karakeep.example.com`, or `http://192.168.1.10:3000` on a LAN) and
   your API key. `Save and test` reports whether the address and key work — a
   pasted `/api/v1` suffix is stripped for you.
2. **KaraKo → Download folder.** Pick where articles should live. On a Kobo,
   somewhere under `/mnt/onboard` keeps them visible in the native library too.
3. **KaraKo → What to sync.** All unarchived bookmarks (the default), or a
   single list or tag — the plugin fetches your lists and tags to choose from.
4. **KaraKo → Synchronise now.**

You can bind *Synchronise KaraKo* to a gesture under
**Settings → Gestures**.

### Setting up from a file instead

Typing an API key on an e-reader keyboard is miserable, so settings can be read
from a plain text file instead. **KaraKo → Settings file → Create an example
file** writes a commented one for you; edit it on a computer and use *Reload it
now*, or just restart KOReader.

```ini
# karako.conf
server_url = https://karakeep.example.com
api_token  = ak1_your_key_here
directory  = /mnt/onboard/karakeep

articles_per_sync = 50
download_images   = false
archive_tag       = read-on-kobo
```

Checked in this order, first found wins — **Settings file → Where KaraKo looks**
shows the list with the active one ticked:

1. `<koreader data dir>/karako.conf`
2. `<koreader data dir>/settings/karako.conf`
3. `karako.koplugin/karako.conf`, next to the plugin

On Flatpak the data directory is
`~/.var/app/rocks.koreader.KOReader/config/koreader`; on a Kobo it is
`/mnt/onboard/.adds/koreader`.

Notes on how it behaves:

- The file **seeds** settings the first time KaraKo runs. They then appear in the
  menus like any other setting, and **whatever you set in the menus wins** from
  that point on.
- Editing the file later does nothing by itself. Use **Settings file → Reload it
  now** to pull the changes in, which overwrites the matching settings.
- Anything the file leaves out is under the menu's control from the start.
- Values are taken literally to end of line, so URLs and tokens need no quoting.
  `key: value` works as well as `key = value`; `#` and `;` start a comment;
  booleans accept `true/false`, `yes/no`, `on/off`, `1/0`.
- A misspelled setting is **reported in the log**, not silently ignored.
- The file holds your API key in plain text. Keep it readable only by you, and
  give the device its own key so it can be revoked on its own.

## How articles are named

Downloads are named `Article Title [kk-id_abc123].epub`. The bracketed marker is
how the Karakeep bookmark ID survives a round trip through the filesystem — it is
what lets a later sync know that an article is already on the device, archive the
right bookmark when you finish it, and attach your highlights to it. There is no
separate index to fall out of step.

It sits at the **end** so the title is what you see. Earlier versions led with it,
which put an opaque ID where the title should be and, since a file browser
truncates the end of a long name, pushed the title out of sight entirely. It also
made the folder sort by ID rather than alphabetically.

Both forms are read back the same way, so upgrading orphans nothing and
re-downloads nothing — articles already on the device simply keep their old
names. **KaraKo → Tidy up old file names** renames them if you want them
consistent; reading progress, highlights and collection membership follow the
file.

Renaming an article yourself is fine, as long as the `[kk-id_…]` marker survives
somewhere in the name. Remove it and KaraKo stops recognising the file: it will
download the article again and will never archive it.

## Automatic syncing

Off by default. **KaraKo → Sync when Wi-Fi connects** reacts to the network
coming up — it never turns the radio on itself, which would be a bad trade on a
device that spends most of its life asleep.

What it does depends on what you are doing:

- **Reading a document** — sends read status and highlights only. That is the
  half that goes stale on the server, it needs no progress dialogs, and so it
  cannot interrupt you. Downloads wait.
- **In the file manager** — a full sync, reporting to a transient notification
  rather than a modal.

**Sync at most every** (default 30 minutes) stops a flaky connection from
syncing repeatedly. Manual *Synchronise now* ignores the limit.

Whether to bother is a fair question. The plugin is designed so that nothing is
lost by syncing late: read status and highlights live durably in KOReader's
`.sdr` sidecars and are reconciled against the server on every run, so a sync
you never got round to is caught by the next one. Automatic syncing buys
timeliness, not correctness. If you sync manually often enough to keep the
device stocked, manual is perfectly sound.

## What syncs which way, and what happens on a conflict

There is no conflict *resolution* here, and it is worth being plain about that
rather than implying more than the plugin does.

| Thing | Direction | On conflict |
| --- | --- | --- |
| Article content | Karakeep → device | Re-downloaded only if missing locally |
| Finished / read | device → Karakeep | Device wins. Un-archiving in Karakeep while the local copy is finished re-archives it on the next sync |
| Archived elsewhere | Karakeep → device | Local copy deleted, **but only if you never opened it** |
| Highlights | device → Karakeep | Create-only, matched by text. See below |
| Reading position | neither | Not synced at all — that is [KOSync][kosync]'s job, between KOReader devices |
| Tags, title, notes | Karakeep → device | Read at download time; later edits do not reach an already-downloaded copy |

[kosync]: https://github.com/koreader/koreader/tree/master/plugins/kosync.koplugin

### Highlights specifically

Highlights are pushed one way and never deleted or updated, and the matching is
by text because nothing else is shared between the two sides. The consequences
are worth knowing:

- **Deleting a highlight in KOReader does not delete it in Karakeep.**
- **Deleting a highlight in Karakeep brings it back.** It is still in the local
  sidecar, and the next sync sees it missing from the server and recreates it.
  To be rid of one, delete it on the device as well.
- **Editing a highlight's text in Karakeep creates a duplicate**, because the
  local text no longer matches anything on the server.
- **Editing only the note in KOReader changes nothing remotely** — the text
  still matches, so the highlight is treated as already present.
- Highlighting the same passage twice on the device sends it once.

If any of that bothers you, **KaraKo → Send highlights to Karakeep** turns the
whole thing off and nothing is written.

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

Offsets are counted in UTF-16 code units, because that is how a JavaScript
string is indexed and Karakeep is a JavaScript application. Counting bytes
instead — which is what Lua does by default — puts every highlight in an article
progressively out of place as soon as it contains anything outside ASCII, and a
single curly quote or em-dash is enough.

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
- **Lazy-loaded images are resolved.** Karakeep's extraction keeps a page's
  original markup, so articles from sites that lazy-load arrive with a
  placeholder in `src` and the real picture in `data-src`, `data-original`,
  `srcset` and friends. Those are read in preference to `src`, and a `<noscript>`
  block is unwrapped when it contains the plain `<img>` such sites hide there.
  From a `srcset`, the widest candidate up to 1600px wins.
- **WebP is embedded.** crengine links libwebp and renders it — verified by
  page count, since a tall WebP takes a one-page document to three. An earlier
  version excluded WebP on the assumption it could not, which quietly dropped a
  large share of images from modern sites.
- Image types are detected from their magic bytes rather than the URL's
  extension, and any image that fails to download has its `<img>` removed so you
  never see a broken image box.
- **Image embedding is bounded**, at 2 MB for any one image and 8 MB across an
  article, on top of the *Embed images* count limit. Every image is held in
  memory until the EPUB is written, and a Kobo has little to spare; an article
  pointing at print-resolution photographs would otherwise take all of it.
  Anything over the limit is dropped with its `<img>`, and the log names it.
- **Local deletion is conservative.** Articles are only removed when the sync saw
  your whole library uninterrupted — never after a capped or cancelled run — and
  never if you have opened them. An article archived on another device is tidied
  up on the next full sync. A consequence worth knowing: if your unread count
  exceeds *Articles per sync*, every run is capped, so this cleanup never
  happens until the backlog drops below the limit.
- **The API key is stored in the clear** in
  `koreader/settings/karako.lua`, as KOReader has no keystore. It is worth
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
make check  # syntax and accidental globals, every file
make test   # the spec suite, any Lua 5.1
```

`articleutil.lua` has no KOReader dependencies and carries the bulk of the fiddly
logic, so it is directly testable off-device. EPUB assembly needs the real
crengine and libarchive; `tools/epubcheck.lua` drives those headlessly against an
extracted KOReader AppImage — no build required.

See [TESTING.md](TESTING.md), which also lists what is verified and what still
needs checking on a real Kobo.

## Licence

AGPL-3.0-or-later, matching KOReader, whose modules this plugin builds on.
