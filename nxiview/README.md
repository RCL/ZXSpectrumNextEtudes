# nxiview

A NextZXOS dot command that displays an NXI image on Layer 2.

## Features

- Auto-detects the format from the file size (256×192×256, 320×256×256, 640×256×16; with or without an in-file palette).
- Allocates its own Layer 2 banks via `IDE_BANK`, so it doesn't stomp on the OS's default L2 area.
- Picks a transparency colour automatically so no pixel goes transparent.
- Saves and restores every NextReg it touches (palette, scroll, clip, MMU3, transparency, fallback colour, CPU speed, etc.) — when it exits, the caller (BASIC, a file manager, ...) sees the system in the state it left it.
- Supports a 128-byte PLUS3DOS header transparently.
- Supports quotes in filesystem arguments for paths with spaces

## Usage

```
.nxiview <file.nxi>
```

While the image is shown:

| Key            | Action                                |
|----------------|---------------------------------------|
| **M**          | Toggle 320×256×256 ↔ 640×256×16       |
| Any other key  | Exit                                  |

`.nxiview`, `.nxiview -h`, `.nxiview -?` print a short usage banner instead of trying to open a file.

## Supported sizes

| Bytes  | Mode             | Palette in file |
|--------|------------------|-----------------|
| 49152  | 256×192×256      | no              |
| 49664  | 256×192×256      | 256 entries     |
| 81920  | 320×256×256 or 640×256×16 (probe decides) | no |
| 81952  | 640×256×16       | 16 entries      |
| 82432  | 320×256×256      | 256 entries     |

A leading PLUS3DOS header (128 bytes) is recognised and skipped.

## Building

`sjasmplus` must be on your PATH.

- **Linux / macOS:** `./build.sh`
- **Windows:** `build.bat`

The output is a single `nxiview` binary (to be copied to `C:/DOT/` on the SD card).

## Installation

1. Build `nxiview` (see above).
2. Copy it to `C:/DOT/` on the Spectrum Next SD card.
3. From BASIC: `.nxiview path/to/picture.nxi`

## Tools

`nxi2bmp.py` — Python script that converts an NXI to an 8-bit palettised BMP, useful for previewing NXIs on a host machine.

```
python3 nxi2bmp.py file.nxi [out.bmp]
```

## Credits

Vibe-coded by RCL/VVG, with testing and debugging help from Leonis.
