#!/usr/bin/env python3
"""
File to QR Code Video Encoder (file_to_video)
Converts any file into a sequence of animated QR codes packaged into an MP4 video.
"""

import os
import sys
import json
import gzip
import base64
import hashlib
import argparse
import tempfile
import subprocess
from PIL import Image, ImageDraw, ImageFont
import qrcode

VERSION = 1
DEFAULT_CHUNK_SIZE = 500  # Raw bytes per QR code
DEFAULT_FPS = 10          # Video frames per second
DEFAULT_HOLD_FRAMES = 2   # Repeat each QR code for N frames for resilience


def compute_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def create_qr_canvas(payload_str: str, header_text: str, footer_text: str) -> Image.Image:
    """
    Generates a QR code image with top/bottom informational banners.
    """
    qr = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=8,
        border=3,
    )
    qr.add_data(payload_str)
    qr.make(fit=True)
    qr_img = qr.make_image(fill_color="black", back_color="white").convert("RGB")

    banner_top_h = 50
    banner_bottom_h = 30
    canvas_w = max(qr_img.width + 40, 640)
    # Ensure dimensions are even numbers for H.264 compatibility
    if canvas_w % 2 != 0:
        canvas_w += 1

    canvas_h = qr_img.height + banner_top_h + banner_bottom_h + 20
    if canvas_h % 2 != 0:
        canvas_h += 1

    canvas = Image.new("RGB", (canvas_w, canvas_h), color=(245, 247, 250))
    draw = ImageDraw.Draw(canvas)

    # Top banner background
    draw.rectangle([0, 0, canvas_w, banner_top_h], fill=(33, 37, 41))
    draw.text((15, 15), header_text, fill=(255, 255, 255))

    # Center QR code
    qr_x = (canvas_w - qr_img.width) // 2
    qr_y = banner_top_h + 10
    canvas.paste(qr_img, (qr_x, qr_y))

    # Bottom banner text
    draw.text((15, canvas_h - banner_bottom_h + 5), footer_text, fill=(108, 117, 125))

    return canvas


def encode_file_to_video(
    input_file: str,
    output_video: str = None,
    chunk_size: int = DEFAULT_CHUNK_SIZE,
    fps: int = DEFAULT_FPS,
    hold_frames: int = DEFAULT_HOLD_FRAMES,
    repeat_cycles: int = 1,
) -> str:
    """
    Encodes an input file into an MP4 video containing QR codes.
    """
    if not os.path.isfile(input_file):
        raise FileNotFoundError(f"Input file not found: {input_file}")

    filename = os.path.basename(input_file)
    with open(input_file, "rb") as f:
        raw_bytes = f.read()

    orig_size = len(raw_bytes)
    orig_sha256 = compute_sha256(raw_bytes)
    file_id = orig_sha256[:8]

    # Compress file if beneficial
    compressed_bytes = gzip.compress(raw_bytes, compresslevel=9)
    if len(compressed_bytes) < orig_size:
        use_gzip = True
        payload_data = compressed_bytes
    else:
        use_gzip = False
        payload_data = raw_bytes

    # Split into chunks
    chunks = [
        payload_data[i : i + chunk_size]
        for i in range(0, len(payload_data), chunk_size)
    ]
    total_chunks = len(chunks)

    if output_video is None:
        output_video = f"{os.path.splitext(filename)[0]}_qr.mp4"

    print("=" * 60)
    print(" [File to QR Video Encoder]")
    print(f" Input File:        {filename}")
    print(f" Original Size:     {orig_size:,} bytes")
    print(f" Gzip Compressed:   {'Yes (' + str(len(compressed_bytes)) + ' bytes)' if use_gzip else 'No'}")
    print(f" Total QR Chunks:   {total_chunks}")
    print(f" Chunk Size:        {chunk_size} bytes")
    print(f" FPS / Hold Frames: {fps} fps / {hold_frames} frames per QR")
    print(f" Repeat Cycles:     {repeat_cycles}")
    print(f" SHA-256:           {orig_sha256}")
    print("=" * 60)

    with tempfile.TemporaryDirectory() as tmpdir:
        frame_idx = 1
        print(">> Generating QR frames...")

        for cycle in range(repeat_cycles):
            for idx, chunk in enumerate(chunks):
                chunk_b64 = base64.b64encode(chunk).decode("ascii")
                packet = {
                    "v": VERSION,
                    "id": file_id,
                    "name": filename,
                    "size": orig_size,
                    "sha256": orig_sha256,
                    "gz": use_gzip,
                    "total": total_chunks,
                    "idx": idx,
                    "data": chunk_b64,
                }
                payload_str = json.dumps(packet, separators=(",", ":"))

                header = f"[{idx + 1}/{total_chunks}] {filename} ({orig_size:,} B)"
                footer = f"ID: {file_id} | Cycle: {cycle + 1}/{repeat_cycles} | Antigravity File2QR"
                canvas = create_qr_canvas(payload_str, header, footer)

                # Save repeated frames
                for _ in range(hold_frames):
                    frame_path = os.path.join(tmpdir, f"frame_{frame_idx:06d}.png")
                    canvas.save(frame_path)
                    frame_idx += 1

                if (idx + 1) % 10 == 0 or (idx + 1) == total_chunks:
                    print(f"   Progress: {idx + 1}/{total_chunks} chunks generated")

        total_frames = frame_idx - 1
        video_duration = total_frames / fps
        print(f">> Encoding {total_frames} frames to MP4 ({video_duration:.1f}s) via FFmpeg...")

        ffmpeg_cmd = [
            "ffmpeg",
            "-y",
            "-framerate", str(fps),
            "-i", os.path.join(tmpdir, "frame_%06d.png"),
            "-c:v", "libx264",
            "-crf", "18",
            "-preset", "fast",
            "-pix_fmt", "yuv420p",
            output_video,
        ]

        result = subprocess.run(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 0:
            raise RuntimeError(f"FFmpeg error: {result.stderr.decode('utf-8')}")

    out_size = os.path.getsize(output_video)
    print(f">> Successfully generated video: {output_video}")
    print(f"   Video Size: {out_size:,} bytes, Duration: {video_duration:.1f}s")
    print("=" * 60)
    return output_video


def main():
    parser = argparse.ArgumentParser(description="Convert any file into a QR code MP4 video.")
    parser.add_argument("input_file", help="Path to the file to encode")
    parser.add_argument("-o", "--output", default=None, help="Output MP4 file path")
    parser.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE, help="Raw chunk size (default: 500 bytes)")
    parser.add_argument("--fps", type=int, default=DEFAULT_FPS, help="Video frame rate (default: 10)")
    parser.add_argument("--hold-frames", type=int, default=DEFAULT_HOLD_FRAMES, help="Frames to hold each QR (default: 2)")
    parser.add_argument("--repeat", type=int, default=1, help="Repeat cycles of the entire sequence (default: 1)")

    args = parser.parse_args()
    encode_file_to_video(
        input_file=args.input_file,
        output_video=args.output,
        chunk_size=args.chunk_size,
        fps=args.fps,
        hold_frames=args.hold_frames,
        repeat_cycles=args.repeat,
    )


if __name__ == "__main__":
    main()
