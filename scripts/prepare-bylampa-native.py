#!/usr/bin/env python3
"""Build-time ByLampa runtime selection. Public upstream commit and Git blob pinned."""
from __future__ import annotations

import hashlib
from pathlib import Path
from urllib.request import Request, urlopen

COMMIT = "ad961847ed7b71ebd9257afdd64c39b016632bea"
BLOB = "7b99cd3f06985fac7a57117fdae737c4a5637bcc"
SIZE = 2101468
URL = f"https://raw.githubusercontent.com/bylampa/lampa/{COMMIT}/app.min.js"
TARGET = Path("iLampa/Resources/www/app.min.js")


def git_blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\\0".encode() + data).hexdigest()


def main() -> None:
    request = Request(URL, headers={"User-Agent": "ILampa-native-build/2.3.0"})
    with urlopen(request, timeout=30) as response:
        data = response.read(SIZE + 1)
    if len(data) != SIZE or git_blob(data) != BLOB:
        raise SystemExit("Pinned ByLampa distribution failed Git blob and size verification")
    if b"Lampa" not in data:
        raise SystemExit("Downloaded distribution is not a Lampa runtime")
    TARGET.write_bytes(data)
    print(f"ByLampa core installed: commit={COMMIT} git_blob={BLOB} sha256={hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
