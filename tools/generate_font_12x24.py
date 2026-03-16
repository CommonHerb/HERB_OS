"""Generate 12x24 font from 8x16 via nearest-neighbor scaling.

Reads boot/font_data.inc (256 glyphs x 16 bytes, 8px wide)
Outputs boot/font_12x24.inc (256 glyphs x 24 rows x 2 bytes = 12,288 bytes)

Byte order: little-endian for x86 word load.
  word bit 15 = column 0 (leftmost), bit 4 = column 11, bits 3-0 = 0
  byte[offset+1] (bits 15-8) = columns 0-7
  byte[offset+0] (bits 7-0)  = columns 8-11 in high nibble
"""

import re
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FONT_IN = os.path.join(SCRIPT_DIR, "..", "boot", "font_data.inc")
FONT_OUT = os.path.join(SCRIPT_DIR, "..", "boot", "font_12x24.inc")

# Nearest-neighbor column mapping: out_col -> src_col
# src_col = out_col * 8 // 12
COL_MAP = [c * 8 // 12 for c in range(12)]
# [0, 0, 1, 2, 2, 3, 4, 4, 5, 6, 6, 7]

# Nearest-neighbor row mapping: out_row -> src_row
# src_row = out_row * 16 // 24
ROW_MAP = [r * 16 // 24 for r in range(24)]


def parse_font_data(path):
    """Parse font_data.inc into list of 256 glyphs, each 16 bytes."""
    glyphs = []
    current = []
    with open(path, "r") as f:
        for line in f:
            m = re.match(r'\s*db\s+(.*)', line)
            if not m:
                continue
            vals = m.group(1).split(',')
            for v in vals:
                v = v.strip()
                if v:
                    current.append(int(v, 16))
            if len(current) >= 16:
                glyphs.append(current[:16])
                current = current[16:]
    assert len(glyphs) == 256, f"Expected 256 glyphs, got {len(glyphs)}"
    return glyphs


def scale_glyph(glyph_8x16):
    """Scale one 8x16 glyph to 12x24, returning list of 24 16-bit words."""
    rows_24 = []
    for out_row in range(24):
        src_row = ROW_MAP[out_row]
        src_byte = glyph_8x16[src_row]  # 8 bits, MSB = col 0

        # Build 12-bit row from source
        word = 0
        for out_col in range(12):
            src_col = COL_MAP[out_col]
            # Source bit: bit (7 - src_col) of src_byte
            if src_byte & (0x80 >> src_col):
                # Set bit (15 - out_col) in the 16-bit word
                word |= (0x8000 >> out_col)

        rows_24.append(word)
    return rows_24


def write_font_inc(path, all_glyphs_24):
    """Write font_12x24.inc as NASM db lines."""
    with open(path, "w") as f:
        f.write("; font_12x24 -- 256 chars x 48 bytes = 12288 bytes\n")
        f.write("; Generated from font_data.inc via nearest-neighbor 1.5x scale\n")
        f.write("; 2 bytes per row (little-endian word), 24 rows per glyph\n")
        f.write("font_12x24:\n")

        for gi, glyph in enumerate(all_glyphs_24):
            # Write 24 rows as 2 db lines of 24 bytes each (12 rows per line)
            for half in range(2):
                start = half * 12
                end = start + 12
                bytes_list = []
                for row_word in glyph[start:end]:
                    lo = row_word & 0xFF
                    hi = (row_word >> 8) & 0xFF
                    bytes_list.append(f"0x{lo:02X}")
                    bytes_list.append(f"0x{hi:02X}")
                f.write(f"    db {','.join(bytes_list)}\n")


def main():
    glyphs_8x16 = parse_font_data(FONT_IN)
    glyphs_12x24 = [scale_glyph(g) for g in glyphs_8x16]
    write_font_inc(FONT_OUT, glyphs_12x24)
    print(f"Generated {FONT_OUT}")
    print(f"  {len(glyphs_12x24)} glyphs, 48 bytes each = {len(glyphs_12x24)*48} bytes total")

    # Quick sanity: check glyph 0x41 ('A') has some set bits
    a_glyph = glyphs_12x24[0x41]
    set_count = sum(bin(w).count('1') for w in a_glyph)
    print(f"  Glyph 'A' has {set_count} set pixels (sanity check)")


if __name__ == "__main__":
    main()
