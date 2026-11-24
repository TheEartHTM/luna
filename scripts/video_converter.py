#!/usr/bin/env python3
"""
video_converter.py - Offline Media Converter for Luna OS / CC: Tweaked

Converts video and audio media into Luna Video Data (.lvd) format using 2x3 square-pixel
teletext characters (CC characters 128-159) and extracts companion OGG Vorbis audio
for Create: Electro Energetics (CEE) Electric Speakers.

Dependencies:
- Python 3 standard library
- PIL (Pillow)
- ffmpeg & ffprobe command-line tools
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import time
from urllib.parse import urlparse

try:
    from PIL import Image
except ImportError:
    print("Error: Pillow is required. Please install Pillow: pip install Pillow", file=sys.stderr)
    sys.exit(1)


# ComputerCraft Standard 16-Color Palette (RGB)
CC_PALETTE = [
    (240, 240, 240),  # 0: White
    (242, 178,  51),  # 1: Orange
    (229, 127, 216),  # 2: Magenta
    (153, 178, 242),  # 3: Light Blue
    (222, 222, 108),  # 4: Yellow
    (127, 204,  25),  # 5: Lime
    (242, 178, 204),  # 6: Pink
    ( 76,  76,  76),  # 7: Gray
    (153, 153, 153),  # 8: Light Gray
    ( 76, 153, 178),  # 9: Cyan
    (178, 102, 229),  # a: Purple
    ( 51, 102, 204),  # b: Blue
    (127, 102,  76),  # c: Brown
    ( 87, 166,  78),  # d: Green
    (204,  76,  76),  # e: Red
    ( 25,  25,  25),  # f: Black
]

HEX_BYTES = [ord(c) for c in "0123456789abcdef"]

# Precompute squared Euclidean distances between palette entries
COLOR_DIST = [[0] * 16 for _ in range(16)]
for i in range(16):
    r1, g1, b1 = CC_PALETTE[i]
    for j in range(16):
        r2, g2, b2 = CC_PALETTE[j]
        COLOR_DIST[i][j] = (r1 - r2) ** 2 + (g1 - g2) ** 2 + (b1 - b2) ** 2


def build_pillow_palette():
    """Build a 768-byte palette repeated to 256 entries to prevent Pillow quantization overflow."""
    flat_pal = []
    for r, g, b in CC_PALETTE:
        flat_pal.extend([r, g, b])
    # Repeat the 16 colors across all 256 entries
    pal_256 = (flat_pal * 16)[:768]
    pal_img = Image.new("P", (1, 1))
    pal_img.putpalette(pal_256)
    return pal_img


def check_tool_installed(tool_name):
    """Check if an external binary is installed and reachable in PATH."""
    return shutil.which(tool_name) is not None


def has_audio_stream(source_path):
    """Check via ffprobe if the input contains at least one audio stream."""
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "a",
        "-show_entries", "stream=codec_name",
        "-of", "default=noprint_wrappers=1:nokey=1",
        source_path
    ]
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return bool(res.stdout.strip())
    except Exception:
        return False


def get_video_duration(source_path):
    """Estimate video duration in seconds via ffprobe."""
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        source_path
    ]
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        val = res.stdout.strip()
        return float(val) if val else None
    except Exception:
        return None


def resolve_media_source(input_source):
    """Resolve input path or URL. Handle YouTube links via yt-dlp if present."""
    parsed = urlparse(input_source)
    is_url = parsed.scheme in ("http", "https")

    if is_url:
        is_youtube = "youtube.com" in parsed.netloc or "youtu.be" in parsed.netloc
        if is_youtube:
            if not check_tool_installed("yt-dlp"):
                print(
                    "[ERROR] YouTube URL detected, but 'yt-dlp' is not installed in PATH.\n"
                    "        Please install yt-dlp or provide a direct video file / URL.",
                    file=sys.stderr
                )
                sys.exit(1)
            print(":: Resolving YouTube video stream with yt-dlp...")
            cmd = ["yt-dlp", "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best", "-g", input_source]
            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if res.returncode != 0 or not res.stdout.strip():
                print(f"[ERROR] Failed to resolve YouTube URL via yt-dlp: {res.stderr.strip()}", file=sys.stderr)
                sys.exit(1)
            urls = res.stdout.strip().splitlines()
            return urls[0], input_source
        return input_source, input_source
    else:
        if not os.path.exists(input_source):
            print(f"[ERROR] Input video file not found: {input_source}", file=sys.stderr)
            sys.exit(1)
        return os.path.abspath(input_source), input_source


def extract_audio(source_path, output_ogg_path, audio_quality=4):
    """Extract audio track to OGG Vorbis using ffmpeg."""
    cmd = [
        "ffmpeg", "-y", "-i", source_path,
        "-vn", "-c:a", "libvorbis", "-q:a", str(audio_quality),
        output_ogg_path
    ]
    print(f":: Extracting audio stream to OGG Vorbis: {output_ogg_path}...")
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if res.returncode != 0:
        print(f"[WARN] Audio extraction failed: {res.stderr.decode('utf-8', errors='replace').strip()}", file=sys.stderr)
        if os.path.exists(output_ogg_path):
            os.remove(output_ogg_path)
        return False
    return True


def encode_frame_cells(data, width, height, cols, rows):
    """
    Encode quantized pixel indices into 2x3 teletext characters and blit colors.
    Returns: (lines_text, lines_fg, lines_bg) where each element is a list of byte objects.
    """
    stride = width
    lines_text = []
    lines_fg = []
    lines_bg = []

    for cy in range(rows):
        y0_off = (cy * 3) * stride
        y1_off = y0_off + stride
        y2_off = y1_off + stride

        row_text = bytearray(cols)
        row_fg = bytearray(cols)
        row_bg = bytearray(cols)

        for cx in range(cols):
            x0 = cx * 2
            x1 = x0 + 1

            p0 = data[y0_off + x0] % 16
            p1 = data[y0_off + x1] % 16
            p2 = data[y1_off + x0] % 16
            p3 = data[y1_off + x1] % 16
            p4 = data[y2_off + x0] % 16
            p5 = data[y2_off + x1] % 16

            # Fast path: all 6 sub-pixels identical color
            if p0 == p1 == p2 == p3 == p4 == p5:
                row_text[cx] = 128
                row_fg[cx] = HEX_BYTES[p0]
                row_bg[cx] = HEX_BYTES[p0]
                continue

            # Count color occurrences
            pixels = (p0, p1, p2, p3, p4, p5)
            counts = {}
            for p in pixels:
                counts[p] = counts.get(p, 0) + 1

            if len(counts) == 2:
                c1, c2 = counts.keys()
            else:
                sorted_colors = sorted(counts.keys(), key=lambda c: counts[c], reverse=True)
                c1, c2 = sorted_colors[0], sorted_colors[1]

            d_c1 = COLOR_DIST[c1]
            d_c2 = COLOR_DIST[c2]

            # Map pixels to c1 (0) or c2 (1)
            b0 = 0 if p0 == c1 else (1 if p0 == c2 else (0 if d_c1[p0] <= d_c2[p0] else 1))
            b1 = 0 if p1 == c1 else (1 if p1 == c2 else (0 if d_c1[p1] <= d_c2[p1] else 1))
            b2 = 0 if p2 == c1 else (1 if p2 == c2 else (0 if d_c1[p2] <= d_c2[p2] else 1))
            b3 = 0 if p3 == c1 else (1 if p3 == c2 else (0 if d_c1[p3] <= d_c2[p3] else 1))
            b4 = 0 if p4 == c1 else (1 if p4 == c2 else (0 if d_c1[p4] <= d_c2[p4] else 1))
            b5 = 0 if p5 == c1 else (1 if p5 == c2 else (0 if d_c1[p5] <= d_c2[p5] else 1))

            # Teletext encoding: sub-pixel 6 determines background
            if b5 == 0:
                row_text[cx] = 128 + b0 + (b1 << 1) + (b2 << 2) + (b3 << 3) + (b4 << 4)
                row_fg[cx] = HEX_BYTES[c2]
                row_bg[cx] = HEX_BYTES[c1]
            else:
                row_text[cx] = 128 + (1 - b0) + ((1 - b1) << 1) + ((1 - b2) << 2) + ((1 - b3) << 3) + ((1 - b4) << 4)
                row_fg[cx] = HEX_BYTES[c1]
                row_bg[cx] = HEX_BYTES[c2]

        lines_text.append(bytes(row_text))
        lines_fg.append(bytes(row_fg))
        lines_bg.append(bytes(row_bg))

    return lines_text, lines_fg, lines_bg


def convert_video(
    input_source,
    output_dir=None,
    name=None,
    fps=10,
    width=328,
    height=243,
    keyframe_interval=30,
    dither=True,
    extract_audio_track=True,
    audio_quality=4
):
    """Convert input media to .lvd video and .ogg audio."""
    if width < 2 or height < 3:
        print(f"[ERROR] Target resolution must be at least 2x3 pixels (1x1 teletext cells). Got {width}x{height}.", file=sys.stderr)
        sys.exit(1)
    if fps < 1:
        print(f"[ERROR] Target FPS must be at least 1. Got {fps}.", file=sys.stderr)
        sys.exit(1)

    if not check_tool_installed("ffmpeg"):
        print("[ERROR] ffmpeg is not installed or not found in PATH.", file=sys.stderr)
        sys.exit(1)
    if not check_tool_installed("ffprobe"):
        print("[ERROR] ffprobe is not installed or not found in PATH.", file=sys.stderr)
        sys.exit(1)

    source_path, display_name = resolve_media_source(input_source)

    # Determine base name
    if not name:
        if os.path.exists(source_path):
            stem = os.path.splitext(os.path.basename(source_path))[0]
        else:
            stem = os.path.splitext(os.path.basename(display_name))[0]
        name = stem if stem else "video"

    # Determine output directory
    if not output_dir:
        output_dir = os.path.dirname(source_path) if os.path.isfile(source_path) else os.getcwd()
    os.makedirs(output_dir, exist_ok=True)

    output_lvd = os.path.join(output_dir, f"{name}.lvd")
    output_ogg = os.path.join(output_dir, f"{name}.ogg")

    # Dimensions
    cols = width // 2
    rows = height // 3
    actual_width = cols * 2
    actual_height = rows * 3

    if actual_width != width or actual_height != height:
        print(f":: Note: Adjusted resolution to {actual_width}x{actual_height} ({cols}x{rows} cells) for 2x3 grid.")
    width = actual_width
    height = actual_height

    # Check and extract audio
    has_audio = False
    if extract_audio_track and has_audio_stream(source_path):
        has_audio = extract_audio(source_path, output_ogg, audio_quality)
    elif extract_audio_track:
        print(":: No audio stream detected in source media.")

    # Pillow palette setup
    pal_img = build_pillow_palette()
    dither_mode = Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE

    # Estimate total frames
    duration = get_video_duration(source_path)
    est_total_frames = int(duration * fps) if duration else None

    # Spawn FFmpeg rawvideo pipe
    ffmpeg_cmd = [
        "ffmpeg", "-v", "error", "-i", source_path,
        "-vf", f"scale={width}:{height}:force_original_aspect_ratio=decrease,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:black,fps={fps}",
        "-f", "rawvideo",
        "-pix_fmt", "rgb24",
        "-"
    ]

    print(f":: Encoding video stream to {output_lvd}...")
    print(f"   Target: {width}x{height} pixels ({cols}x{rows} cells) @ {fps} fps")
    print(f"   Keyframe Interval: {keyframe_interval} frames, Dithering: {'Enabled' if dither else 'Disabled'}")

    pipe = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    frame_raw_size = width * height * 3

    frame_count = 0
    flags = 1 if has_audio else 0

    t_start = time.time()
    prev_text = None
    prev_fg = None
    prev_bg = None

    with open(output_lvd, "wb") as out_file:
        # Write 16-byte placeholder header: magic (4B), width (2B), height (2B), cols (1B), rows (1B), fps (1B), flags (1B), total_frames (4B)
        header_placeholder = struct.pack(">4sHHBBBB I", b"LVD1", width, height, cols, rows, fps, flags, 0)
        out_file.write(header_placeholder)

        while True:
            raw_rgb = pipe.stdout.read(frame_raw_size)
            if not raw_rgb or len(raw_rgb) < frame_raw_size:
                break

            frame_count += 1
            is_keyframe = (frame_count == 1) or (keyframe_interval > 0 and (frame_count % keyframe_interval == 1))

            # Quantize frame
            img = Image.frombytes("RGB", (width, height), raw_rgb)
            quantized = img.quantize(palette=pal_img, dither=dither_mode)
            q_bytes = quantized.tobytes()

            # Encode 2x3 teletext characters
            lines_text, lines_fg, lines_bg = encode_frame_cells(q_bytes, width, height, cols, rows)

            if is_keyframe or prev_text is None:
                # Keyframe record (Type 0x01)
                # Payload: rows lines of text[cols] + fg[cols] + bg[cols]
                key_payload = bytearray([0x01])
                for cy in range(rows):
                    key_payload.extend(lines_text[cy])
                    key_payload.extend(lines_fg[cy])
                    key_payload.extend(lines_bg[cy])
                out_file.write(key_payload)
            else:
                # Delta frame record (Type 0x02)
                diff_records = []
                for cy in range(rows):
                    txt = lines_text[cy]
                    ptxt = prev_text[cy]
                    fg = lines_fg[cy]
                    pfg = prev_fg[cy]
                    bg = lines_bg[cy]
                    pbg = prev_bg[cy]

                    if txt == ptxt and fg == pfg and bg == pbg:
                        continue

                    # Locate diff span [min_x..max_x]
                    min_x = 0
                    while min_x < cols and txt[min_x] == ptxt[min_x] and fg[min_x] == pfg[min_x] and bg[min_x] == pbg[min_x]:
                        min_x += 1

                    max_x = cols - 1
                    while max_x >= min_x and txt[max_x] == ptxt[max_x] and fg[max_x] == pfg[max_x] and bg[max_x] == pbg[max_x]:
                        max_x -= 1

                    seg_len = max_x - min_x + 1
                    y_cc = cy + 1       # 1-indexed row
                    x_cc = min_x + 1    # 1-indexed column

                    seg_chars = txt[min_x : max_x + 1]
                    seg_fgs   = fg[min_x : max_x + 1]
                    seg_bgs   = bg[min_x : max_x + 1]

                    rec = struct.pack("BBB", y_cc, x_cc, seg_len) + seg_chars + seg_fgs + seg_bgs
                    diff_records.append(rec)

                delta_header = struct.pack(">BH", 0x02, len(diff_records))
                out_file.write(delta_header)
                if diff_records:
                    out_file.write(b"".join(diff_records))

            prev_text = lines_text
            prev_fg = lines_fg
            prev_bg = lines_bg

            if frame_count % 30 == 0:
                elapsed = time.time() - t_start
                rate = frame_count / elapsed if elapsed > 0 else 0
                pct = f"({(frame_count / est_total_frames) * 100:.1f}%)" if est_total_frames else ""
                print(f"   Encoded {frame_count} frames {pct} - {rate:.1f} fps...")

        if pipe.stdout:
            pipe.stdout.close()
        pipe.wait()

        # Update header with final frame count
        out_file.seek(0)
        final_header = struct.pack(">4sHHBBBB I", b"LVD1", width, height, cols, rows, fps, flags, frame_count)
        out_file.write(final_header)
        out_file.flush()

    total_time = time.time() - t_start
    lvd_size = os.path.getsize(output_lvd)
    ogg_size = os.path.getsize(output_ogg) if has_audio and os.path.exists(output_ogg) else 0

    print(f"\n[  OK  ] Media conversion completed successfully in {total_time:.2f}s!")
    print(f"   Frames Encoded : {frame_count} frames ({frame_count / total_time:.1f} fps)")
    print(f"   Video Stream   : {output_lvd} ({lvd_size:,} bytes)")
    if has_audio:
        print(f"   Audio Stream   : {output_ogg} ({ogg_size:,} bytes)")
    else:
        print("   Audio Stream   : None")

    return output_lvd, output_ogg if has_audio else None


def main():
    parser = argparse.ArgumentParser(
        description="Convert video/audio into Luna Video Data (.lvd) for CC:Tweaked monitors."
    )
    parser.add_argument("input", help="Path to input video file or direct media URL")
    parser.add_argument("-o", "--output-dir", help="Output directory (default: current or input dir)")
    parser.add_argument("--name", help="Base name for generated files")
    parser.add_argument("--fps", type=int, default=10, help="Target playback frame rate (default: 10)")
    parser.add_argument("--width", type=int, default=328, help="Target pixel width (default: 328)")
    parser.add_argument("--height", type=int, default=243, help="Target pixel height (default: 243)")
    parser.add_argument("--keyframe-interval", type=int, default=30, help="Keyframe interval in frames (default: 30)")
    parser.add_argument("--no-dither", action="store_true", help="Disable Floyd-Steinberg dithering")
    parser.add_argument("--no-audio", action="store_true", help="Disable audio track extraction")
    parser.add_argument("--audio-quality", type=int, default=4, help="OGG Vorbis quality 0-10 (default: 4)")

    args = parser.parse_args()

    convert_video(
        input_source=args.input,
        output_dir=args.output_dir,
        name=args.name,
        fps=args.fps,
        width=args.width,
        height=args.height,
        keyframe_interval=args.keyframe_interval,
        dither=not args.no_dither,
        extract_audio_track=not args.no_audio,
        audio_quality=args.audio_quality,
    )


if __name__ == "__main__":
    main()
