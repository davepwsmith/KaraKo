#!/usr/bin/env python3
"""Serve image fixtures for tools/epubcheck.lua.

The image path in epubbuilder.lua needs real HTTP responses to exercise:
a decodable image, one whose extension lies about its contents, a non-image
served where an image was expected, and a duplicate source.

    python3 tools/fixtures.py          # serves on 127.0.0.1:8799
    KK_IMG_SERVER=http://127.0.0.1:8799/ ./luajit tools/epubcheck.lua
"""

import http.server
import os
import struct
import sys
import tempfile
import zlib

PORT = int(os.environ.get("KK_FIXTURE_PORT", "8799"))


def png(width=40, height=40):
    """A small valid PNG, generated rather than committed as a binary blob."""

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    rows = b"".join(
        b"\x00" + b"".join(bytes([(x * 6) % 256, (y * 6) % 256, 128]) for x in range(width))
        for y in range(height)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


def main():
    root = tempfile.mkdtemp(prefix="kk-fixtures-")
    image = png()

    (open(os.path.join(root, "a.png"), "wb")).write(image)
    # Real PNG bytes behind a .jpg name: the sniffer must ignore the extension.
    (open(os.path.join(root, "liar.jpg"), "wb")).write(image)
    # What a 404 page looks like when a CDN serves it in place of an image.
    (open(os.path.join(root, "broken.png"), "wb")).write(b"<!DOCTYPE html><html>404</html>")

    os.chdir(root)
    print(f"serving fixtures from {root} on http://127.0.0.1:{PORT}/", file=sys.stderr)
    http.server.test(
        HandlerClass=http.server.SimpleHTTPRequestHandler,
        port=PORT,
        bind="127.0.0.1",
    )


if __name__ == "__main__":
    main()
