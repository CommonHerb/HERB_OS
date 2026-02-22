#!/usr/bin/env python3
"""Convert a .herb binary or .herb.json file to a C header with a byte array."""
import sys

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.herb|input.herb.json> <output.h>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], 'rb') as f:
        data = f.read()

    with open(sys.argv[2], 'w') as out:
        out.write("/* Auto-generated from {} */\n\n".format(sys.argv[1]))
        out.write("static const unsigned char program_data[] = {\n")

        for i, byte in enumerate(data):
            if i % 16 == 0:
                out.write("    ")
            out.write("0x{:02x},".format(byte))
            if i % 16 == 15:
                out.write("\n")

        if len(data) % 16 != 0:
            out.write("\n")
        out.write("};\n")
        out.write("static const herb_size_t program_data_len = {};\n".format(len(data)))

if __name__ == "__main__":
    main()
