# Testing

Three layers, cheapest first. The first two run without a device.

```sh
make check   # syntax + accidental globals, every file
make test    # 70 specs, any Lua 5.1
```

Then `tools/epubcheck.lua` against a real KOReader (below), which is the one
that matters: EPUB assembly is the part most likely to be wrong, and it needs
crengine and libarchive.

## Getting a KOReader to test against

**Do not build from source unless you need to.** KOReader's own docs note that
if you only want to work on Lua frontend code — which is all this plugin is —
you can extract the AppImage instead. That takes about a minute rather than the
best part of an hour.

```sh
# Pick the current tag from https://github.com/koreader/koreader/releases
curl -LO https://github.com/koreader/koreader/releases/download/v2026.07/koreader-v2026.07-x86_64.AppImage
chmod +x koreader-v2026.07-x86_64.AppImage
./koreader-v2026.07-x86_64.AppImage --appimage-extract
cd squashfs-root/usr/lib/koreader
```

That directory contains everything needed: `luajit`, `libs/libkoreader-cre.so`,
`ffi/archiver.lua`, fonts, and a `plugins/` directory. Install the plugin with:

```sh
cp -r /path/to/karako/karakeep.koplugin plugins/
```

### Running the UI

```sh
./luajit reader.lua                 # file manager
./luajit reader.lua path/to.epub    # straight into a document
```

Headless works too, which is useful over SSH or in CI:

```sh
xvfb-run -a -s "-screen 0 600x800x24" ./luajit reader.lua path/to.epub
```

Two messages are container noise and can be ignored: SDL's
`XDG_RUNTIME_DIR is invalid or not set`, and `XIO: fatal IO error` when Xvfb is
torn down at the end.

Confirm the plugin loaded — the log line is `Plugin loaded karakeep`:

```sh
./luajit reader.lua 2>&1 | grep -i karakeep
```

It appears under **Tools → More tools → Karakeep**.

### Building from source instead

Worth it if you want the Kobo screen simulations, which the AppImage cannot give
you. `kodev run` takes a device profile:

```sh
git clone https://github.com/koreader/koreader && cd koreader
./kodev fetch-thirdparty && ./kodev build
ln -s /path/to/karako/karakeep.koplugin \
      koreader-emulator-*/koreader/plugins/
./kodev run -s kobo-clara        # or kobo-forma, kobo-aura-one, kobo-h2o
```

`--simulate` accepts `kobo-forma`, `kobo-aura-one`, `kobo-clara`, `kobo-h2o`,
`kindle-paperwhite`, `legacy-paperwhite`, `kindle` and `hidpi`; `-W`, `-H` and
`-D` set width, height and DPI directly. This needs the full toolchain
(SDL3 ≥ 3.2.12, meson, ninja, nasm and the rest — see KOReader's
`doc/Building.md`), or you can use their premade Docker image from
[koreader/virdevenv](https://github.com/koreader/virdevenv), which needs only
Git and Docker.

## tools/epubcheck.lua

Drives `EpubBuilder.build()` against the real crengine and libarchive without
starting the UI, and asserts on the result. 26 checks; exits non-zero on
failure.

```sh
cd squashfs-root/usr/lib/koreader
cp -r /path/to/karako/tools .
./luajit tools/epubcheck.lua
```

To include the image checks, run the fixture server first — it serves a real
PNG, a PNG behind a `.jpg` name, and an HTML error page where an image should
be:

```sh
python3 tools/fixtures.py &                       # 127.0.0.1:8799
KK_IMG_SERVER=http://127.0.0.1:8799/ ./luajit tools/epubcheck.lua
```

It covers the things that silently degrade rather than crash: that crengine
actually balances the ragged HTML, that `<script>` and `onclick` are gone, that
entities become UTF-8, that image media types come from the bytes rather than
the URL, and that an image which fails to download leaves no `<img>` behind.

## What is verified, and what is not

Verified against KOReader v2026.07:

- The plugin loads (`Plugin loaded karakeep`) with `main.lua` initialising
  cleanly alongside 32 stock plugins.
- Generated EPUBs open in `CreDocument`, render, and pass
  `validateAndFixToc(): TOC is fine`.
- `content.xhtml`, `content.opf`, `toc.ncx` and `container.xml` are all
  well-formed XML.
- Ragged HTML is balanced; images are fetched, sniffed and embedded, with
  failures dropped cleanly.

Still unverified, and worth doing on a real Kobo:

1. **A large image-heavy article**, timed. This is the main performance risk of
   building EPUBs in Lua on a Kobo. Compare with *Embed images* off.
2. **`api.lua` against a live Karakeep** — every endpoint here is exercised only
   against the OpenAPI spec, not a running server. Start with
   `Server → Save and test`.
3. **Highlight round trip.** Highlight a passage appearing twice and confirm the
   first-occurrence behaviour in the README; then one appearing once, and check
   the offsets land correctly in Karakeep's web UI.
4. **Interrupted and capped syncs.** Cancel mid-download, and set *Articles per
   sync* below your unread count; confirm nothing local is deleted either time.
   The guard is `complete and not cancelled` in `synchronize()`.
5. **Archive from another device**, then sync, and confirm the unopened local
   copy is removed.
6. **A self-signed certificate**, if your Karakeep uses one. KOReader has its own
   CA bundle and will refuse an unknown issuer; it surfaces as
   `Could not reach the server.`

## Adding specs

`spec/runner.lua` is a deliberately small `describe`/`it` harness. busted is not
used because these modules must run under a plain Lua 5.1 interpreter, the
dialect LuaJIT implements. Add a file to `spec/`, require it from `spec/all.lua`,
and use `assertEqual`, `assertTrue`, `assertNil`, `assertMatch` and
`assertNoMatch`.

To cover a module that pulls in KOReader, stub what it needs via
`package.preload` before requiring it, as `spec/epubbuilder_spec.lua` does. Note
that `socketutil` drags in the whole device stack, which probes SDL and needs a
display — `epubbuilder.lua` requires the networking modules lazily inside
`fetchUrl()` for exactly this reason.
