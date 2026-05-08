#!/usr/bin/env python3
"""Convert a Spectrum Next NXI image to an 8-bit palettized BMP.

Auto-detects the NXI variant from file size:
  49152  -> 256x192x256  (no palette in file)
  49664  -> 256x192x256  (512-byte palette)
  81920  -> 320x256x256  (no palette)
  81952  -> 640x256x16   (32-byte palette)
  82432  -> 320x256x256  (512-byte palette)
A leading 128-byte PLUS3DOS header is stripped if present.

Layer 2 stores pixels column-major (256-byte columns left-to-right). This
is the default. Use --row-major if you have a file authored that way.
"""

import argparse
import struct
import sys
from pathlib import Path

PLUS3DOS_SIG = b"PLUS3DOS"


def expand_3bit(v: int) -> int:
    """Replicate 3-bit value to 8 bits (0..7 -> 0..255)."""
    return (v << 5) | (v << 2) | (v >> 1)


def _entry_to_rgb(hi: int, lo: int) -> tuple[int, int, int]:
    r3 = (hi >> 5) & 0x07
    g3 = (hi >> 2) & 0x07
    b3 = ((hi & 0x03) << 1) | (lo & 0x01)
    return (expand_3bit(r3), expand_3bit(g3), expand_3bit(b3))


def decode_palette(raw: bytes, n_entries: int) -> list[tuple[int, int, int]]:
    """Decode an NXI 9-bit palette block: 2 bytes/entry, first = RRRGGGBB,
    second's bit 0 = 9th bit of blue. Pads to 256 entries with black."""
    pal = [_entry_to_rgb(raw[i * 2], raw[i * 2 + 1]) for i in range(n_entries)]
    while len(pal) < 256:
        pal.append((0, 0, 0))
    return pal


def identity_rainbow_palette() -> list[tuple[int, int, int]]:
    """Standard NextZXOS rainbow identity palette: high = index (RRRGGGBB),
    low byte's bit-0 = 0 only when the 2-bit blue field is 0, else 1.
    Matches what the .nxiview viewer installs when the file has no palette."""
    return [_entry_to_rgb(i, 0 if (i & 3) == 0 else 1) for i in range(256)]


def probe_picks_640(pixels: bytes) -> bool:
    """Same nibble-histogram probe the viewer runs for 81920-byte files.
    Returns True iff 640x256x16 is the better interpretation."""
    counts = [0] * 256
    for b in pixels:
        counts[b] += 1
    same_idx = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
                0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
    same_total = sum(counts[i] for i in same_idx)
    other_total = sum(counts[i] for i in range(256)
                      if i not in same_idx and i != 0 and i != 0xFF)
    if same_total <= other_total:
        return False
    same_sorted = sorted(counts[i] for i in same_idx)
    median_same = same_sorted[7]
    other_counts = [counts[i] for i in range(256)
                    if i not in same_idx and i != 0 and i != 0xFF]
    other_exceeds = sum(1 for c in other_counts if c > median_same)
    return other_exceeds < 120


def column_to_row_major(data: bytes, width: int, height: int) -> bytes:
    """Convert column-major bytes (each column = `height` contiguous bytes)
    into row-major (one row of `width` bytes after another)."""
    out = bytearray(width * height)
    for c in range(width):
        col_base = c * height
        for r in range(height):
            out[r * width + c] = data[col_base + r]
    return bytes(out)


def unpack_640_4bpp(data: bytes) -> bytes:
    """Layer 2 640x256x16 storage: same column-major layout as 320x256, but
    each byte is two horizontally-adjacent pixels (top nibble = left, low =
    right). The 81920 bytes form 320 chunks of 256 bytes; each chunk fills
    two screen columns."""
    width, height = 640, 256
    out = bytearray(width * height)
    for chunk in range(320):
        chunk_base = chunk * 256
        for r in range(256):
            b = data[chunk_base + r]
            row_base = r * width
            out[row_base + chunk * 2] = (b >> 4) & 0x0F
            out[row_base + chunk * 2 + 1] = b & 0x0F
    return bytes(out)


def write_bmp(path: Path, width: int, height: int,
              palette: list[tuple[int, int, int]], top_down_pixels: bytes) -> None:
    """Write an 8bpp indexed BMP. top_down_pixels is row-major, top row first."""
    row_padded = (width + 3) & ~3
    pixel_bytes = bytearray(row_padded * height)
    for r in range(height):
        src = (height - 1 - r) * width  # BMP rows are stored bottom-up
        pixel_bytes[r * row_padded : r * row_padded + width] = \
            top_down_pixels[src : src + width]

    file_header_size = 14
    info_header_size = 40
    palette_size = 256 * 4
    pixel_offset = file_header_size + info_header_size + palette_size
    file_size = pixel_offset + len(pixel_bytes)

    with open(path, "wb") as f:
        # BITMAPFILEHEADER
        f.write(b"BM")
        f.write(struct.pack("<IHHI", file_size, 0, 0, pixel_offset))
        # BITMAPINFOHEADER (40 bytes)
        f.write(struct.pack("<IiiHHIIiiII",
                            info_header_size, width, height, 1, 8,
                            0, len(pixel_bytes), 2835, 2835, 256, 0))
        # Palette (BGRA per entry)
        for r, g, b in palette:
            f.write(bytes((b, g, r, 0)))
        # Pixels
        f.write(bytes(pixel_bytes))


VARIANTS = {
    49152: (256, 192, 0,   8, "256x192x256"),
    49664: (256, 192, 512, 8, "256x192x256 +pal"),
    81920: (320, 256, 0,   8, "320x256x256 or 640x256x16 (probe decides)"),
    81952: (640, 256, 32,  4, "640x256x16 +pal"),
    82432: (320, 256, 512, 8, "320x256x256 +pal"),
}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", help="input .nxi file")
    p.add_argument("output", nargs="?",
                   help="output .bmp (default: input with .bmp extension)")
    p.add_argument("--row-major", action="store_true",
                   help="treat pixel bytes as row-major instead of L2 column-major")
    p.add_argument("--mode-640", action="store_true",
                   help="for the ambiguous 81920-byte size, treat as 640x256x16")
    args = p.parse_args()

    in_path = Path(args.input)
    out_path = Path(args.output) if args.output else in_path.with_suffix(".bmp")

    raw = in_path.read_bytes()
    if raw[:8] == PLUS3DOS_SIG:
        raw = raw[128:]

    size = len(raw)
    if size not in VARIANTS:
        sys.exit(f"Unrecognized NXI size: {size} bytes")

    width, height, pal_bytes, bpp, label = VARIANTS[size]
    pal_raw = raw[:pal_bytes]
    pix_raw = raw[pal_bytes:]

    # For the ambiguous 81920-byte size, run the same nibble probe the asm
    # viewer uses, unless the user forced --mode-640.
    if size == 81920:
        if args.mode_640 or probe_picks_640(pix_raw):
            width, height, bpp = 640, 256, 4
            label = "640x256x16 (probe)" if not args.mode_640 else "640x256x16 (forced)"

    if pal_bytes:
        palette = decode_palette(pal_raw, pal_bytes // 2)
    else:
        palette = identity_rainbow_palette()

    if bpp == 8:
        if args.row_major:
            pixels = pix_raw
        else:
            pixels = column_to_row_major(pix_raw, width, height)
    else:  # 4bpp 640x256
        pixels = unpack_640_4bpp(pix_raw)

    write_bmp(out_path, width, height, palette, pixels)
    print(f"{in_path.name}: {label} -> {out_path} ({width}x{height})")


if __name__ == "__main__":
    main()
