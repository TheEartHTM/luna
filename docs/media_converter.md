# Luna OS Offline Media Converter & LunaVid (.lvd) Specification

The Luna OS media conversion suite converts standard video and audio streams into high-performance teletext video data (`.lvd`) and companion OGG Vorbis audio (`.ogg`) tailored for ComputerCraft: Tweaked (CC:T) and Create: Electro Energetics (CEE).

---

## 1. Overview & Architecture

Modern Minecraft terminals and monitors operate on character grids. `video_converter.py` bridges the gap between high-definition modern media and ComputerCraft displays by:
1. **Direct Memory Streaming**: Pipes raw video from FFmpeg into Python memory, avoiding thousands of temporary PNG files on disk.
2. **Aspect Ratio Preservation**: Automatically scales and letterboxes video to fit target monitor aspect ratios without distortion.
3. **Pillow Floyd-Steinberg Quantization**: Dithers video frames to the CC 16-color palette with a 256-color palette expansion to prevent color clamping errors.
4. **2x3 Teletext Encoding**: Subdivides each character cell into a 2-column by 3-row grid of sub-pixels, producing **100% square pixels** using CC characters 128–159.
5. **Delta Compression Container (`.lvd`)**: Stores keyframes periodically and delta diff bounding spans between frames, reducing bandwidth by 80–95%.
6. **CEE Speaker Audio**: Extracts 44.1 kHz OGG Vorbis audio streams compatible with CEE Electric Speakers (`spk.speakOgg`).

---

## 2. Prerequisites & Installation

### System Dependencies
- **Python**: Python 3.8+ (standard library only)
- **Pillow**: Python Imaging Library (`pip install Pillow`)
- **FFmpeg & FFprobe**: Required for media demuxing and filtering
- **yt-dlp** *(Optional)*: Required only if converting directly from YouTube URLs

```bash
# On Debian / Ubuntu:
sudo apt update && sudo apt install -y ffmpeg python3-pil

# On Arch Linux:
sudo pacman -S ffmpeg python-pillow

# Optional YouTube downloader:
pip install yt-dlp
```

---

## 3. Command-Line Reference

```
python3 scripts/video_converter.py <input> [options]
```

### Positional Arguments
- `input`: Path to a local media file (`.mp4`, `.mov`, `.webm`, `.mkv`, etc.) or a web URL (`http://`, `https://`).

### Options
| Option | Type | Default | Description |
|---|:---:|:---:|---|
| `-o`, `--output-dir` | Path | input dir / cwd | Directory where `.lvd` and `.ogg` files are saved |
| `--name` | String | auto | Base name for generated `.lvd` and `.ogg` files |
| `--fps` | Integer | `10` | Target playback frame rate (e.g. 10, 12, 15, 20) |
| `--width` | Integer | `328` | Target pixel width (must be even number) |
| `--height` | Integer | `243` | Target pixel height (must be divisible by 3) |
| `--keyframe-interval` | Integer | `30` | Interval in frames between full I-frames |
| `--no-dither` | Flag | `False` | Disable Floyd-Steinberg dithering |
| `--no-audio` | Flag | `False` | Skip audio track extraction |
| `--audio-quality` | Integer | `4` | OGG Vorbis audio quality level (0 to 10) |
| `-h`, `--help` | Flag | — | Show help message and exit |

---

## 4. Monitor Resolutions & Video Walls

In CC:Tweaked, each character cell is 6 pixels wide by 9 pixels tall. When divided into 2 horizontal and 3 vertical sub-pixels:
$$\text{Sub-pixel Width} = \frac{6}{2} = 3 \text{ pixels}, \quad \text{Sub-pixel Height} = \frac{9}{3} = 3 \text{ pixels} \implies \text{PAR} = 1.0 \text{ (Square!)}$$

### Standard Target Configurations

| Display Setup | Text Scale | Character Grid (Cols x Rows) | Square Pixel Resolution (W x H) | Aspect Ratio | Converter Arguments |
|:---|:---:|:---:|:---:|:---:|---|
| **Single 8x6 Monitor** | `0.5` | 164 x 81 | **328 x 243** | ~4:3 | *(default)* `--width 328 --height 243` |
| **2x2 Video Wall** | `0.5` | 328 x 162 | **656 x 486** | ~4:3 | `--width 656 --height 486` |
| **3x2 Video Wall** | `0.5` | 492 x 162 | **984 x 486** | ~2:1 | `--width 984 --height 486` |
| **2x1 Widescreen** | `0.5` | 328 x 81 | **656 x 243** | ~8:3 | `--width 656 --height 243` |
| **Terminal Display** | `1.0` | 51 x 24 | **102 x 72** | ~4:3 | `--width 102 --height 72` |

---

## 5. Binary Container Specification (`.lvd`)

Luna Video Data (`.lvd`) uses big-endian binary packing for rapid parsing in CC Lua.

### Header (16 bytes)
```
Offset  Size  Type       Description
0x00    4     ASCII      Magic bytes: "LVD1"
0x04    2     uint16     Pixel Width (e.g. 328)
0x06    2     uint16     Pixel Height (e.g. 243)
0x08    1     uint8      Character Columns (width / 2, e.g. 164)
0x09    1     uint8      Character Rows (height / 3, e.g. 81)
0x0A    1     uint8      Nominal Frame Rate (FPS)
0x0B    1     uint8      Flags: bit 0 = 1 if companion audio present
0x0C    4     uint32     Total Frame Count
```

### Keyframe Record (Type `0x01`)
A keyframe replaces the entire screen state.
```
Byte 0: 0x01 (Keyframe indicator)
Payload: rows lines, where each line consists of:
  - cols bytes: Text teletext character bytes (128..159)
  - cols bytes: Foreground hex color characters ('0'..'f')
  - cols bytes: Background hex color characters ('0'..'f')
Total Payload Length: rows * cols * 3 bytes
```

### Delta Frame Record (Type `0x02`)
A delta frame contains updates only for changed rows.
```
Byte 0: 0x02 (Delta frame indicator)
Bytes 1..2: diff_count (uint16 big-endian)
Followed by diff_count Diff Segments:
  - y: uint8 (1-indexed row, 1..rows)
  - x: uint8 (1-indexed start column, 1..cols)
  - len: uint8 (segment length in columns)
  - chars: len bytes (character bytes 128..159)
  - fgs: len bytes (hex characters '0'..'f')
  - bgs: len bytes (hex characters '0'..'f')
```

---

## 6. Usage Examples

### 1. Basic Conversion
Convert a standard video at default 10 FPS for an 8x6 monitor:
```bash
python3 scripts/video_converter.py input.mp4 -o output/
```
Outputs:
- `output/input.lvd` (encoded video stream)
- `output/input.ogg` (CEE Electric Speaker audio)

### 2. High Frame-Rate Conversion
Encode at 15 FPS with keyframes every 2 seconds:
```bash
python3 scripts/video_converter.py input.mp4 --fps 15 --keyframe-interval 30 -o output/
```

### 3. Video for 2x2 Video Wall
Encode video for a 4-monitor wall array (each monitor 8x6 blocks):
```bash
python3 scripts/video_converter.py input.mp4 --width 656 --height 486 --fps 12 -o output/
```

### 4. YouTube URL Conversion
*(Requires `yt-dlp`)*:
```bash
python3 scripts/video_converter.py "https://www.youtube.com/watch?v=K4X5BpYSYt8" --name trailer -o output/
```

---

## 7. Playback in Luna OS / CC: Tweaked

After copying the `.lvd` and `.ogg` files to your computer or disk drive:

```bash
# Play on auto-detected monitor (companion audio auto-detected):
video input.lvd

# Play on specific monitor:
video -m /dev/mon0 input.lvd

# Play on a 2x2 video wall:
video -w 2x2 input.lvd

# Loop playback continuously:
video --loop input.lvd

# Override volume:
video -v 0.7 input.lvd
```

Controls:
- Press **q** or **x** to halt playback.
- Press **Ctrl+T** to terminate.
