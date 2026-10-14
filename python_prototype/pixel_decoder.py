#!/usr/bin/env python3
"""
Pure Pixel Block Video Decoder (pixel_decoder)
Decodes a pixel matrix MP4 video back into the exact original file.
No computer vision libraries needed. Uses sub-millisecond numpy center-pixel sampling.
"""

import os
import sys
import glob
import gzip
import zlib
import struct
import hashlib
import argparse
import tempfile
import subprocess
import numpy as np
from PIL import Image

MAGIC = b"PXL1"
HEADER_FMT = ">4sHHII"
HEADER_LEN = struct.calcsize(HEADER_FMT)


def compute_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def decode_pixel_video_to_file(
    video_file: str,
    output_dir: str = ".",
    block_size: int = 4,
) -> str:
    """
    Decodes an MP4 video of pure pixel blocks back to the original file.
    """
    if not os.path.isfile(video_file):
        raise FileNotFoundError(f"Video file not found: {video_file}")

    print("=" * 65)
    print(" [Pure Pixel Block Video Decoder (ISG-Style)]")
    print(f" Input Video: {video_file} ({os.path.getsize(video_file):,} bytes)")
    print(f" Block Size:  {block_size}x{block_size} px")
    print("=" * 65)

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
        total_video_frames = len(frame_paths)
        print(f">> Total video frames extracted: {total_video_frames}")

        collected_chunks = {}
        total_chunks_expected = None
        scanned_frames = 0
        half = block_size // 2

        print(">> Sampling pixel matrices...")
        for frame_path in frame_paths:
            scanned_frames += 1
            img = Image.open(frame_path).convert("L")
            arr = np.array(img)

            # Sample center of each block
            sampled = arr[half::block_size, half::block_size]
            bits = (sampled > 128).astype(np.uint8).flatten()
            raw_bytes = np.packbits(bits).tobytes()

            if len(raw_bytes) < HEADER_LEN:
                continue

            magic, total, idx, payload_len, chunk_crc = struct.unpack(
                HEADER_FMT, raw_bytes[:HEADER_LEN]
            )

            if magic != MAGIC:
                continue  # Corrupted or non-protocol frame

            payload = raw_bytes[HEADER_LEN : HEADER_LEN + payload_len]

            # Verify packet-level CRC32
            if zlib.crc32(payload) != chunk_crc:
                print(f"   [Warning] CRC32 mismatch on frame {scanned_frames}, skipping...")
                continue

            total_chunks_expected = total

            if idx not in collected_chunks:
                collected_chunks[idx] = payload
                pct = (len(collected_chunks) / total) * 100
                print(f"   [Progress] Chunk {idx + 1:3d}/{total} captured ({pct:5.1f}%) | Frame {scanned_frames}/{total_video_frames}")

            # Early termination when all chunks are present
            if total_chunks_expected and len(collected_chunks) == total_chunks_expected:
                print(f">> All {total_chunks_expected} chunks collected early at frame {scanned_frames}/{total_video_frames}!")
                break

    if total_chunks_expected is None or len(collected_chunks) < total_chunks_expected:
        missing = [i for i in range(total_chunks_expected or 0) if i not in collected_chunks]
        raise RuntimeError(
            f"Restoration failed! Received {len(collected_chunks)}/{total_chunks_expected} chunks. Missing: {missing}"
        )

    # 4. Reconstruct full stream
    print(">> Reassembling stream and parsing file metadata...")
    full_stream = b"".join(collected_chunks[i] for i in range(total_chunks_expected))

    # Parse metadata header:
    # [fname_len (2B)][fname][orig_size (8B)][orig_sha256 (64B)][use_gzip (1B)][body]
    fname_len = struct.unpack(">H", full_stream[:2])[0]
    offset = 2
    filename = full_stream[offset : offset + fname_len].decode("utf-8")
    offset += fname_len

    orig_size, sha256_bytes, use_gzip_byte = struct.unpack(
        ">Q64sB", full_stream[offset : offset + 73]
    )
    offset += 73
    expected_sha256 = sha256_bytes.decode("ascii")
    use_gzip = use_gzip_byte == 1
    payload_body = full_stream[offset:]

    # Decompress
    if use_gzip:
        restored_bytes = gzip.decompress(payload_body)
    else:
        restored_bytes = payload_body

    # Check exact size and SHA256
    actual_sha256 = compute_sha256(restored_bytes)
    if actual_sha256 != expected_sha256:
        raise ValueError(
            f"Checksum Mismatch!\n"
            f" Expected SHA256: {expected_sha256}\n"
            f" Actual SHA256:   {actual_sha256}"
        )

    # Save to disk
    os.makedirs(output_dir, exist_ok=True)
    out_path = os.path.join(output_dir, filename)

    base, ext = os.path.splitext(filename)
    counter = 1
    target_path = out_path
    while os.path.exists(target_path):
        target_path = os.path.join(output_dir, f"{base}_pixel_restored_{counter}{ext}")
        counter += 1

    with open(target_path, "wb") as f:
        f.write(restored_bytes)

    print("=" * 65)
    print(" [File Restoration SUCCESSFUL]")
    print(f" Restored File:    {target_path}")
    print(f" Restored Size:    {len(restored_bytes):,} bytes")
    print(f" SHA-256 Checksum: {actual_sha256}")
    print(f" Verification:     PASSED (100% Bit-Exact Match)")
    print("=" * 65)
    return target_path


def main():
    parser = argparse.ArgumentParser(description="Decode a pure pixel matrix MP4 video back to the original file.")
    parser.add_argument("video_file", help="Path to input pixel video file")
    parser.add_argument("-o", "--output-dir", default=".", help="Directory to save restored file (default: .)")
    parser.add_argument("--block-size", type=int, default=4, help="Pixel block size in pixels (default: 4)")

    args = parser.parse_args()
    decode_pixel_video_to_file(
        video_file=args.video_file,
        output_dir=args.output_dir,
        block_size=args.block_size,
    )


if __name__ == "__main__":
    main()
