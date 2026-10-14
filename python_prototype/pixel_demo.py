#!/usr/bin/env python3
"""
Benchmark Demo: QR Video vs Pure Pixel Block Video
Directly compares throughput, file size, video duration, and speed of both approaches.
"""

import os
import time
import hashlib
from encoder import encode_file_to_video
from decoder import decode_video_to_file
from pixel_encoder import encode_file_to_pixel_video
from pixel_decoder import decode_pixel_video_to_file


def file_hash(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def run_benchmark():
    print("=" * 75)
    print("      BENCHMARK: QR CODE VIDEO  VS  PURE PIXEL BLOCK VIDEO (ISG)")
    print("=" * 75)

    # 1. Create a 50 KB realistic test file (code + text + binary patterns)
    test_file = "benchmark_data.bin"
    chunk_text = (
        "Pure Pixel Block Encoding Benchmark Test.\n"
        "Testing high-throughput optical and video-based data transmission.\n"
        "Data integrity, compression resilience, and throughput comparison.\n"
    ).encode("utf-8")
    
    with open(test_file, "wb") as f:
        # 50 KB mixed data
        while f.tell() < 50000:
            f.write(chunk_text)
            f.write(os.urandom(64))

    orig_size = os.path.getsize(test_file)
    orig_sha = file_hash(test_file)
    print(f">> Created test payload: '{test_file}' ({orig_size:,} bytes)")
    print(f">> Original SHA-256:     {orig_sha}\n")

    # =========================================================================
    # Test 1: Standard QR Code Video
    # =========================================================================
    print(">>> [TEST 1] Standard QR Code Video Pipeline")
    qr_video = "test_qr.mp4"
    t0 = time.time()
    encode_file_to_video(test_file, qr_video, chunk_size=500, fps=10, hold_frames=2)
    qr_enc_time = time.time() - t0

    t0 = time.time()
    qr_restored = decode_video_to_file(qr_video, "restored_qr_dir")
    qr_dec_time = time.time() - t0
    qr_video_size = os.path.getsize(qr_video)
    qr_match = file_hash(qr_restored) == orig_sha

    # =========================================================================
    # Test 2: Pure Pixel Block Video
    # =========================================================================
    print("\n>>> [TEST 2] Pure Pixel Block (ISG-Style) Pipeline")
    pixel_video = "test_pixel.mp4"
    t0 = time.time()
    encode_file_to_pixel_video(
        test_file,
        pixel_video,
        width=1280,
        height=720,
        block_size=4,
        fps=10,
        hold_frames=2,
        crf=22,
    )
    pixel_enc_time = time.time() - t0

    t0 = time.time()
    pixel_restored = decode_pixel_video_to_file(pixel_video, "restored_pixel_dir", block_size=4)
    pixel_dec_time = time.time() - t0
    pixel_video_size = os.path.getsize(pixel_video)
    pixel_match = file_hash(pixel_restored) == orig_sha

    # =========================================================================
    # Comparison Summary Report
    # =========================================================================
    print("\n" + "=" * 75)
    print("                     HEAD-TO-HEAD BENCHMARK REPORT")
    print("=" * 75)
    print(f"{'Metric':<28} | {'QR Code Video':<20} | {'Pure Pixel Block':<20}")
    print("-" * 75)
    print(f"{'Original File Size':<28} | {orig_size:>10,} B          | {orig_size:>10,} B")
    print(f"{'Output Video File Size':<28} | {qr_video_size:>10,} B          | {pixel_video_size:>10,} B")
    print(f"{'Video Expansion Ratio':<28} | {qr_video_size / orig_size:>10.2f}x          | {pixel_video_size / orig_size:>10.2f}x")
    print(f"{'Encoding Time':<28} | {qr_enc_time:>10.2f} s          | {pixel_enc_time:>10.2f} s")
    print(f"{'Decoding Time':<28} | {qr_dec_time:>10.2f} s          | {pixel_dec_time:>10.2f} s")
    print(f"{'Total Pipeline Time':<28} | {qr_enc_time + qr_dec_time:>10.2f} s          | {pixel_enc_time + pixel_dec_time:>10.2f} s")
    print(f"{'SHA-256 Bit-Exact Match':<28} | {'PASSED' if qr_match else 'FAILED':>10}            | {'PASSED' if pixel_match else 'FAILED':>10}")
    print("=" * 75)

    # Cleanup test outputs
    import shutil
    for f_path in [test_file, qr_video, pixel_video]:
        if os.path.exists(f_path):
            os.remove(f_path)
    for d_path in ["restored_qr_dir", "restored_pixel_dir"]:
        if os.path.exists(d_path):
            shutil.rmtree(d_path)


if __name__ == "__main__":
    run_benchmark()
