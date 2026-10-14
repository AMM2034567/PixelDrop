#!/usr/bin/env python3
"""
Pure Pixel Block Video Encoder (pixel_encoder)
Converts any file into a high-density black-and-white pixel matrix MP4 video.
No QR codes, no finder patterns, 100% full-screen data throughput.
"""

import os
import sys
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
HEADER_FMT = ">4sHHII"  # Magic(4B), TotalChunks(2B), ChunkIdx(2B), PayloadLen(4B), CRC32(4B)
HEADER_LEN = struct.calcsize(HEADER_FMT)  # 16 bytes


def compute_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encode_file_to_pixel_video(
    input_file: str,
    output_video: str = None,
    width: int = 1280,
    height: int = 720,
    block_size: int = 4,
    fps: int = 10,
    hold_frames: int = 2,
    crf: int = 22,
) -> str:
    """
    Encodes any file into a pure pixel matrix video.
    """
    if not os.path.isfile(input_file):
        raise FileNotFoundError(f"Input file not found: {input_file}")

    filename = os.path.basename(input_file)
    with open(input_file, "rb") as f:
        raw_bytes = f.read()

    orig_size = len(raw_bytes)
    orig_sha256 = compute_sha256(raw_bytes)

    # 1. Gzip compression
    compressed = gzip.compress(raw_bytes, compresslevel=9)
    use_gzip = len(compressed) < orig_size
    payload_body = compressed if use_gzip else raw_bytes

    # 2. Package file metadata prefix:
    # [Filename_len (2B)][Filename (UTF-8)][Orig_Size (8B)][SHA256 (32B hex)][Use_Gzip (1B)][Body]
    fname_bytes = filename.encode("utf-8")
    meta_header = struct.pack(
        f">H{len(fname_bytes)}sQ64sB",
        len(fname_bytes),
        fname_bytes,
        orig_size,
        orig_sha256.encode("ascii"),
        1 if use_gzip else 0,
    )
    full_stream = meta_header + payload_body

    # 3. Calculate grid geometry
    grid_w = width // block_size
    grid_h = height // block_size
    frame_capacity = (grid_w * grid_h) // 8  # Total bytes capacity per frame
    chunk_payload_capacity = frame_capacity - HEADER_LEN

    # Slice stream into chunks
    chunks = [
        full_stream[i : i + chunk_payload_capacity]
        for i in range(0, len(full_stream), chunk_payload_capacity)
    ]
    total_chunks = len(chunks)

    if output_video is None:
        output_video = f"{os.path.splitext(filename)[0]}_pixel.mp4"

    print("=" * 65)
    print(" [Pure Pixel Block Video Encoder (ISG-Style)]")
    print(f" Input File:        {filename}")
    print(f" Original Size:     {orig_size:,} bytes")
    print(f" Compressed Size:   {len(payload_body):,} bytes ({'Gzip' if use_gzip else 'None'})")
    print(f" Resolution:        {width}x{height} (Block: {block_size}x{block_size} px)")
    print(f" Single Frame Cap:  {chunk_payload_capacity:,} bytes/frame")
    print(f" Total Frames:      {total_chunks} chunks ({total_chunks * hold_frames} video frames)")
    print(f" FPS / Hold Frames: {fps} fps / {hold_frames} hold")
    print(f" SHA-256:           {orig_sha256}")
    print("=" * 65)

    with tempfile.TemporaryDirectory() as tmpdir:
        frame_idx = 1
        print(">> Generating pixel matrix frames...")

        for idx, chunk in enumerate(chunks):
            # Packet: [Header (16B)] + [Payload] + [Zero Padding to frame_capacity]
            chunk_crc = zlib.crc32(chunk)
            header = struct.pack(HEADER_FMT, MAGIC, total_chunks, idx, len(chunk), chunk_crc)
            padding_len = chunk_payload_capacity - len(chunk)
            frame_raw = header + chunk + (b"\x00" * padding_len)

            # Unpack bits: 0 -> 0 (Black), 1 -> 255 (White)
            bits = np.unpackbits(np.frombuffer(frame_raw, dtype=np.uint8))
            grid = (bits.reshape((grid_h, grid_w)) * 255).astype(np.uint8)

            # Scale up to block_size
            img_arr = np.repeat(np.repeat(grid, block_size, axis=0), block_size, axis=1)
            img = Image.fromarray(img_arr, mode="L")

            for _ in range(hold_frames):
                frame_path = os.path.join(tmpdir, f"frame_{frame_idx:06d}.png")
                img.save(frame_path)
                frame_idx += 1

            if (idx + 1) % 10 == 0 or (idx + 1) == total_chunks:
                print(f"   Progress: {idx + 1}/{total_chunks} frames rendered")

        total_video_frames = frame_idx - 1
        duration = total_video_frames / fps
        print(f">> Encoding {total_video_frames} frames to MP4 ({duration:.1f}s) via FFmpeg (CRF {crf})...")

        ffmpeg_cmd = [
            "ffmpeg",
            "-y",
            "-framerate", str(fps),
            "-i", os.path.join(tmpdir, "frame_%06d.png"),
            "-c:v", "libx264",
            "-crf", str(crf),
            "-preset", "medium",
            "-tune", "stillimage",
            "-g", "300",
            "-pix_fmt", "yuv420p",
            output_video,
        ]

        result = subprocess.run(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 0:
            raise RuntimeError(f"FFmpeg error: {result.stderr.decode('utf-8')}")

    out_size = os.path.getsize(output_video)
    expansion_ratio = out_size / orig_size if orig_size > 0 else 0
    print(f">> Successfully generated video: {output_video}")
    print(f"   Video Size:      {out_size:,} bytes")
    print(f"   Expansion Ratio: {expansion_ratio:.2f}x")
    print(f"   Duration:        {duration:.1f}s")
    print("=" * 65)
    return output_video


def main():
    parser = argparse.ArgumentParser(description="Encode any file into a pure pixel matrix MP4 video.")
    parser.add_argument("input_file", help="Path to input file")
    parser.add_argument("-o", "--output", default=None, help="Output MP4 path")
    parser.add_argument("--width", type=int, default=1280, help="Video width (default: 1280)")
    parser.add_argument("--height", type=int, default=720, help="Video height (default: 720)")
    parser.add_argument("--block-size", type=int, default=4, help="Pixel block size in pixels (default: 4)")
    parser.add_argument("--fps", type=int, default=10, help="Video frame rate (default: 10)")
    parser.add_argument("--hold-frames", type=int, default=2, help="Hold frames per chunk (default: 2)")
    parser.add_argument("--crf", type=int, default=22, help="H.264 CRF quality (default: 22)")

    args = parser.parse_args()
    encode_file_to_pixel_video(
        input_file=args.input_file,
        output_video=args.output,
        width=args.width,
        height=args.height,
        block_size=args.block_size,
        fps=args.fps,
        hold_frames=args.hold_frames,
        crf=args.crf,
    )


if __name__ == "__main__":
    main()
