# Testing

## What runs off-device

```sh
make test
```

`articleutil.lua` has no KOReader dependencies, and `epubbuilder.lua`'s
`markdownToHtml()` and `buildDocument()` only need its networking and logging
stubbed. Between them that covers filename round-tripping, HTML sanitising,
entity decoding, image collection, highlight text matching, query building and
the markdown fallback — the parts most likely to be wrong.

`make check` runs `luac -p` over every file, and also greps the bytecode for
`SETGLOBAL`, which catches the accidental globals that Lua otherwise fails on
silently at runtime.

## What does not

Four things need a real KOReader and cannot be faked usefully:

| Area | Why | How to exercise it |
| --- | --- | --- |
| `EpubBuilder.build()` | Needs crengine (`getBalancedHTML`) and libarchive | Sync one article, then open the EPUB |
| `api.lua` | Needs LuaSocket and a live Karakeep | `Server → Save and test` |
| `highlights.lua` | Reads real `.sdr` sidecars | Highlight, then `Send read status and highlights` |
| Menus, Trapper, network | UI framework | By hand |

## Using the KOReader emulator

The emulator is far quicker to iterate against than a Kobo, and everything
except device-specific paths behaves the same.

```sh
git clone https://github.com/koreader/koreader
cd koreader
./kodev fetch-thirdparty
./kodev build
ln -s "$(pwd)/../karako/karakeep.koplugin" koreader-emulator-*/koreader/plugins/
./kodev run
```

The plugin lands in **Tools → More tools → Karakeep**. Logs go to stdout; raise
the level with `./kodev run -v` and look for lines tagged `Karakeep:` or
`KarakeepApi:`.

## Checks worth doing on a real device

The interesting failures are all on-device, so these are the ones that matter:

1. **A large image-heavy article.** This is the main performance risk of building
   EPUBs in Lua on a Kobo. Time it, and compare with *Embed images* off.
2. **A malformed source page.** Find an article whose crawl produced ragged HTML
   and confirm `getBalancedHTML()` copes and the EPUB still opens.
3. **Highlight round trip.** Highlight a passage that appears twice in the
   article and confirm the first-occurrence behaviour described in the README —
   then one that appears once, and check the offsets land correctly in
   Karakeep's web UI.
4. **Interrupted sync.** Cancel mid-download and confirm nothing local is
   deleted; the guard for this is `complete and not cancelled` in `synchronize()`.
5. **Capped sync.** Set *Articles per sync* below your unread count and confirm
   that articles beyond the cap are not treated as remotely deleted.
6. **Archive from another device.** Archive something in Karakeep's web UI, then
   sync, and confirm the unopened local copy is removed.
7. **Self-signed certificate**, if your Karakeep is behind one. KOReader has its
   own CA bundle and will refuse an unknown issuer; the failure surfaces as
   `Could not reach the server.`

## Adding specs

`spec/runner.lua` is a deliberately small `describe`/`it` harness — busted is not
used because these modules must run under a plain Lua 5.1 interpreter, the
dialect LuaJIT implements. Add a file to `spec/`, require it from `spec/all.lua`,
and use `assertEqual`, `assertTrue`, `assertNil`, `assertMatch` and
`assertNoMatch`.

To cover a module that pulls in KOReader, stub what it needs via
`package.preload` before requiring it, as `spec/epubbuilder_spec.lua` does.
