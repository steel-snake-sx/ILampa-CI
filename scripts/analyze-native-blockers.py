#!/usr/bin/env python3
"""Read retained xcresult SQLite/attachments without modifying original evidence.

Python 3.14 is required for the stdlib zstd decoder used by these Xcode bundles.
This is evidence extraction, NOT a replacement native test runner/xcresulttool.
"""
import argparse
import hashlib
import json
import sqlite3
import zipfile
from compression import zstd
from pathlib import Path


def analyze(source: Path, output: Path) -> list[dict]:
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for bundle in sorted(source.glob("*/Concurrency.xcresult.zip")):
        run = bundle.parent.name
        destination = output / run
        destination.mkdir(parents=True, exist_ok=True)
        checksum = hashlib.sha256(bundle.read_bytes()).hexdigest()
        expected = json.loads((bundle.parent / "artifact-checksums.json").read_text())[bundle.name]
        if checksum != expected["sha256"] or bundle.stat().st_size != expected["bytes"]:
            raise ValueError(f"Retained artifact checksum mismatch: {bundle}")
        with zipfile.ZipFile(bundle) as archive:
            bad = archive.testzip()
            if bad:
                raise ValueError(f"Retained ZIP CRC failure: {bundle}: {bad}")
            if "Concurrency.xcresult/database.sqlite3" not in archive.namelist():
                # Initial bundle predates the materialized SQLite index. Keep
                # that distinction explicit; do not invent SQL-derived totals.
                extracted = []
                for entry in archive.infolist():
                    if "/data." not in entry.filename:
                        continue
                    payload = archive.read(entry)
                    data = zstd.decompress(payload) if payload.startswith(b"\x28\xb5\x2f\xfd") else payload
                    if data.startswith((b"Standard output and standard error", b"Xcode version:", b"Date/Time:", b"\x89PNG")):
                        extension = ".png" if data.startswith(b"\x89PNG") else ".txt"
                        name = f"legacy-{len(extracted)}{extension}"
                        (destination / name).write_bytes(data)
                        extracted.append({"object": entry.filename, "file": name,
                                          "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
                result = {"run": run, "sha256": checksum, "zipCRC": "passed",
                          "counts": "No SQLite index; see original suite-results-from-log.json and XCTest logs",
                          "issues": None, "extractedAttachments": extracted}
                (destination / "analysis.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
                results.append(result)
                continue
            database = destination / "database.sqlite3"
            database.write_bytes(archive.read("Concurrency.xcresult/database.sqlite3"))
            with sqlite3.connect(f"{database.resolve().as_uri()}?mode=ro", uri=True) as connection:
                connection.row_factory = sqlite3.Row
                counts = [dict(row) for row in connection.execute(
                    "SELECT result, COUNT(*) AS count FROM TestCaseResultsByDestinationAndConfiguration "
                    "WHERE destination_fk IS NOT NULL AND configuration_fk IS NOT NULL GROUP BY result")]
                failures = [dict(row) for row in connection.execute("""
                    SELECT TestCases.identifier, TestIssues.compactDescription, TestIssues.detailedDescription
                    FROM TestIssues LEFT JOIN TestCaseRuns ON TestCaseRuns.rowid=TestIssues.testCaseRun_fk
                    LEFT JOIN TestCases ON TestCases.rowid=TestCaseRuns.testCase_fk
                """)]
                attachments = []
                for row in connection.execute("""
                    SELECT name, uniformTypeIdentifier, xcResultKitPayloadRefId FROM Attachments
                    WHERE name LIKE '%Spindump%' OR name LIKE '%LocalPlayerProbe%'
                """):
                    payload = archive.read("Concurrency.xcresult/Data/data." + row["xcResultKitPayloadRefId"])
                    data = zstd.decompress(payload) if payload.startswith(b"\x28\xb5\x2f\xfd") else payload
                    name = f"attachment-{len(attachments)}.txt"
                    (destination / name).write_bytes(data)
                    attachments.append({"originalName": row["name"], "file": name,
                                        "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
                result = {"run": run, "sha256": checksum, "zipCRC": "passed", "counts": counts,
                          "issues": failures, "extractedAttachments": attachments}
                (destination / "analysis.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
                results.append(result)
    if not results:
        raise FileNotFoundError(f"No retained Concurrency.xcresult.zip bundles under {source}")
    (output / "summary.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("build/concurrency-native"))
    parser.add_argument("--output", type=Path, default=Path("build/native-blockers-analysis"))
    args = parser.parse_args()
    for result in analyze(args.source, args.output):
        issues = "not indexed" if result["issues"] is None else len(result["issues"])
        print(result["run"], result["counts"], "CRC/SHA256 verified; issues:", issues)
