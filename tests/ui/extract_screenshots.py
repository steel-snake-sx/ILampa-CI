#!/usr/bin/env python3
"""
Extract XCUITest screenshot attachments from an .xcresult bundle.
Supports both xcrun xcresulttool export and raw binary scanning of xcresult attachments.
"""

import sys
import os
import shutil
import subprocess
import argparse

import zlib

PNG_HEADER = b"\x89PNG\r\n\x1a\n"

def extract_via_xcresulttool(xcresult_path, output_dir):
    for flag in ["--output-path", "--output-directory"]:
        try:
            cmd = [
                "xcrun", "xcresulttool", "export", "attachments",
                "--path", xcresult_path,
                flag, output_dir
            ]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode == 0:
                exported = [f for f in os.listdir(output_dir) if f.lower().endswith(".png")]
                if exported:
                    print(f"[extract_screenshots] xcresulttool with {flag} exported {len(exported)} images successfully.")
                    return True
        except Exception as e:
            print(f"[extract_screenshots] xcresulttool ({flag}) attempt failed: {e}")
    return False

def extract_via_binary_scan(xcresult_path, output_dir):
    extracted_count = 0
    os.makedirs(output_dir, exist_ok=True)
    
    for root, _, files in os.walk(xcresult_path):
        for f in files:
            file_path = os.path.join(root, f)
            try:
                with open(file_path, "rb") as fp:
                    data = fp.read()
                    
                    # Direct uncompressed check
                    if data.startswith(PNG_HEADER):
                        extracted_count += 1
                        dest_name = f"attachment_{extracted_count}_{f}.png" if not f.lower().endswith(".png") else f
                        dest_path = os.path.join(output_dir, dest_name)
                        shutil.copyfile(file_path, dest_path)
                        continue

                    # Attempt zlib decompression (xcresult compression)
                    try:
                        decompressed = zlib.decompress(data)
                        if decompressed.startswith(PNG_HEADER):
                            extracted_count += 1
                            dest_name = f"decompressed_{extracted_count}_{f}.png"
                            dest_path = os.path.join(output_dir, dest_name)
                            with open(dest_path, "wb") as out_fp:
                                out_fp.write(decompressed)
                    except Exception:
                        pass
            except (IOError, OSError):
                continue
                
    print(f"[extract_screenshots] Binary/decompression scan extracted {extracted_count} PNG attachments.")
    return extracted_count > 0

def main():
    parser = argparse.ArgumentParser(description="Extract screenshots from .xcresult")
    parser.add_argument("--xcresult", default="build/TestResults.xcresult", help="Path to .xcresult bundle")
    parser.add_argument("--output", default="build/ui-screenshots", help="Directory to save extracted PNGs")
    args = parser.parse_args()

    xcresult_path = os.path.abspath(args.xcresult)
    output_dir = os.path.abspath(args.output)

    if not os.path.exists(xcresult_path):
        print(f"[extract_screenshots] WARNING: .xcresult not found at {xcresult_path}")
        return

    os.makedirs(output_dir, exist_ok=True)
    
    success = extract_via_xcresulttool(xcresult_path, output_dir)
    if not success or len(os.listdir(output_dir)) == 0:
        extract_via_binary_scan(xcresult_path, output_dir)

    images = [f for f in os.listdir(output_dir) if f.lower().endswith(".png")]
    print(f"== Extracted {len(images)} Screenshots ==")
    for img in sorted(images):
        full_path = os.path.join(output_dir, img)
        size = os.path.getsize(full_path)
        print(f"  - {img} ({size} bytes)")

if __name__ == "__main__":
    main()
