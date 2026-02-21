#!/usr/bin/env python3
"""Generate a C header embedding multiple .herb binary program files.

Usage: python gen_multi_program_data.py name1:file1.herb name2:file2.herb ... output.h

Each name:file pair produces:
  static const unsigned char program_NAME[] = { ... };
  static const herb_size_t program_NAME_len = NNN;
"""
import sys

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} name:file [name:file ...] output.h", file=sys.stderr)
        sys.exit(1)

    output_path = sys.argv[-1]
    entries = []
    for arg in sys.argv[1:-1]:
        if ':' not in arg:
            print(f"Error: expected name:file, got '{arg}'", file=sys.stderr)
            sys.exit(1)
        name, path = arg.split(':', 1)
        with open(path, 'rb') as f:
            data = f.read()
        entries.append((name, data))

    with open(output_path, 'w') as out:
        out.write("/* Auto-generated: multiple .herb program binaries */\n\n")

        for name, data in entries:
            out.write(f"static const unsigned char program_{name}[] = {{\n")
            for i, byte in enumerate(data):
                if i % 16 == 0:
                    out.write("    ")
                out.write("0x{:02x},".format(byte))
                if i % 16 == 15:
                    out.write("\n")
            if len(data) % 16 != 0:
                out.write("\n")
            out.write("};\n")
            out.write(f"static const herb_size_t program_{name}_len = {len(data)};\n\n")

if __name__ == "__main__":
    main()
