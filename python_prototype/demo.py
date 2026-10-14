#!/usr/bin/env python3
"""
End-to-End Automated Demo
Demonstrates converting a file into a QR video and restoring it back with 100% fidelity.
"""

import os
import hashlib
from encoder import encode_file_to_video
from decoder import decode_video_to_file


def file_hash(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def run_demo():
    print("=" * 70)
    print("   FILE-TO-QR-VIDEO PROTOTYPE DEMONSTRATION")
    print("=" * 70)

    # 1. Prepare sample data file
    sample_file = "sample_document.txt"
    sample_content = (
        "===============================================================\n"
        "   File-to-QR Video Transmission Protocol Demo\n"
        "   Date: 2026-10-14\n"
        "===============================================================\n\n"
        "This is a demonstration of optical air-gapped data transfer using dynamic QR codes.\n"
        "The system breaks arbitrary binary or text files into chunks, encapsulates them\n"
        "with self-describing metadata headers and SHA-256 checksums, and renders them into\n"
        "an H.264 MP4 video stream.\n\n"
        "Key features verified in this test:\n"
        "1. Automatic Gzip compression for payload optimization.\n"
        "2. Base64 encoding for universal scanner compatibility.\n"
        "3. Top and bottom visual progress banners on each frame.\n"
        "4. Inter-frame hold resilience against video codec compression.\n"
        "5. Early termination on decoder once 100% of chunks are collected.\n"
        "6. Bit-for-bit SHA-256 cryptographic verification upon reconstruction.\n\n"
        "Random test payload:\n"
    ) + ("A" * 120 + "\n" + "B" * 120 + "\n" + "C" * 120 + "\n") * 15

    with open(sample_file, "w", encoding="utf-8") as f:
        f.write(sample_content)

    orig_sha256 = file_hash(sample_file)
    orig_size = os.path.getsize(sample_file)
    print(f">> Created test file: '{sample_file}' ({orig_size:,} bytes)")
    print(f">> Original SHA-256: {orig_sha256}\n")

    # 2. Encode to video
    output_video = "demo_qr_video.mp4"
    encode_file_to_video(
        input_file=sample_file,
        output_video=output_video,
        chunk_size=400,
        fps=10,
        hold_frames=2,
        repeat_cycles=1,
    )

    # 3. Decode from video
    restored_dir = "restored_output"
    os.makedirs(restored_dir, exist_ok=True)
    restored_file = decode_video_to_file(output_video, output_dir=restored_dir)

    # 4. Verification
    restored_sha256 = file_hash(restored_file)
    restored_size = os.path.getsize(restored_file)

    print("\n" + "=" * 70)
    print("                    FINAL VERIFICATION REPORT")
    print("=" * 70)
    print(f"Original File:   {sample_file} ({orig_size:,} bytes)")
    print(f"Restored File:   {restored_file} ({restored_size:,} bytes)")
    print(f"Original SHA256: {orig_sha256}")
    print(f"Restored SHA256: {restored_sha256}")

    match = (orig_sha256 == restored_sha256) and (orig_size == restored_size)
    if match:
        print("\n [RESULT]: SUCCESS! Files are 100% IDENTICAL (Bit-exact match)! ")
    else:
        print("\n [RESULT]: FAILURE! Hashes do not match!")
    print("=" * 70)


if __name__ == "__main__":
    run_demo()
