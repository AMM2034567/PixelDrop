#!/usr/bin/env python3
"""
QR Code Video to File Decoder (video_to_file)
Reads an MP4 video, scans each frame for QR codes, reassembles and verifies the original file.
"""

import os
import sys
import glob
import json
import gzip
import base64
import hashlib
import argparse
import tempfile
import subprocess
from PIL import Image
from pyzbar.pyzbar import decode as decode_qr


def compute_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def decode_video_to_file(video_file: str, output_dir: str = ".") -> str:
    """
    Extracts QR codes from video frames and restores the original file.
    """
    if not os.path.isfile(video_file):
        raise FileNotFoundError(f"Video file not found: {video_file}")

    print("=" * 60)
    print(" [QR Video to File Decoder]")
    print(f" Input Video: {video_file} ({os.path.getsize(video_file):,} bytes)")
    print("=" * 60)

    with tempfile.TemporaryDirectory() as tmpdir:
        print(">> Extracting video frames via FFmpeg...")
        extract_cmd = [
            "ffmpeg",
            "-y",
            "-i", video_file,
            os.path.join(tmpdir, "frame_%06d.png"),
        ]
        res = subprocess.run(extract_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if res.returncode != 0:
            raise RuntimeError(f"FFmpeg extraction failed: {res.stderr.decode('utf-8')}")

        frame_paths = sorted(glob.glob(os.path.join(tmpdir, "frame_*.png")))
        total_frames = len(frame_paths)
        print(f">> Total frames extracted: {total_frames}")

        collected_chunks = {}
        metadata = None
        scanned_frames = 0
        decoded_qr_count = 0

        for frame_path in frame_paths:
            scanned_frames += 1
            try:
                img = Image.open(frame_path)
                qr_results = decode_qr(img)
            except Exception as e:
                continue

            for qr in qr_results:
                try:
                    raw_str = qr.data.decode("utf-8")
                    packet = json.loads(raw_str)
                except Exception:
                    continue

                if "v" not in packet or "idx" not in packet or "data" not in packet:
                    continue

                decoded_qr_count += 1
                idx = packet["idx"]
                total = packet["total"]

                if metadata is None:
                    metadata = packet
                    print(f">> Identified target file: '{packet['name']}' (ID: {packet['id']}, Chunks: {total})")

                if idx not in collected_chunks:
                    chunk_bytes = base64.b64decode(packet["data"])
                    collected_chunks[idx] = chunk_bytes
                    progress_pct = (len(collected_chunks) / total) * 100
                    print(f"   [Progress] Chunk {idx + 1:3d}/{total} captured ({progress_pct:5.1f}%) | Frame {scanned_frames}/{total_frames}")

                # Check if all chunks have been collected
                if metadata and len(collected_chunks) == metadata["total"]:
                    print(f">> All {metadata['total']} chunks captured early at frame {scanned_frames}/{total_frames}!")
                    break

            if metadata and len(collected_chunks) == metadata["total"]:
                break

    if metadata is None or len(collected_chunks) < metadata["total"]:
        missing = []
        if metadata:
            missing = [i for i in range(metadata["total"]) if i not in collected_chunks]
        raise RuntimeError(
            f"Failed to restore file! Collected {len(collected_chunks)}/{metadata['total'] if metadata else '?'} chunks. "
            f"Missing chunks: {missing}"
        )

    print(">> Reassembling chunks and validating checksum...")
    total_chunks = metadata["total"]
    payload_combined = b"".join(collected_chunks[i] for i in range(total_chunks))

    # Decompress if gzip was used
    if metadata.get("gz", False):
        try:
            restored_bytes = gzip.decompress(payload_combined)
        except Exception as e:
            raise RuntimeError(f"Gzip decompression failed: {e}")
    else:
        restored_bytes = payload_combined

    # Verify SHA-256
    actual_sha256 = compute_sha256(restored_bytes)
    expected_sha256 = metadata["sha256"]

    if actual_sha256 != expected_sha256:
        raise ValueError(
            f"Checksum MISMATCH!\n"
            f" Expected SHA256: {expected_sha256}\n"
            f" Actual SHA256:   {actual_sha256}"
        )

    # Save restored file
    os.makedirs(output_dir, exist_ok=True)
    out_file_path = os.path.join(output_dir, metadata["name"])

    # If the destination file already exists and isn't the same file, avoid collision
    base, ext = os.path.splitext(metadata["name"])
    counter = 1
    target_path = out_file_path
    while os.path.exists(target_path):
        target_path = os.path.join(output_dir, f"{base}_restored_{counter}{ext}")
        counter += 1

    with open(target_path, "wb") as f:
        f.write(restored_bytes)

    print("=" * 60)
    print(" [File Restoration SUCCESSFUL]")
    print(f" Restored File:     {target_path}")
    print(f" File Size:         {len(restored_bytes):,} bytes")
    print(f" SHA-256 Checksum:  {actual_sha256}")
    print(f" Integrity Check:   PASSED (100% Bit-Exact Match)")
    print("=" * 60)
    return target_path


def main():
    parser = argparse.ArgumentParser(description="Decode an MP4 QR video back into the original file.")
    parser.add_argument("video_file", help="Path to input QR video file")
    parser.add_argument("-o", "--output-dir", default=".", help="Directory to save the restored file (default: .)")

    args = parser.parse_args()
    decode_video_to_file(video_file=args.video_file, output_dir=args.output_dir)


if __name__ == "__main__":
    main()
