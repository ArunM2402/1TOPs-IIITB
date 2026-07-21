#!/usr/bin/env python3
"""Convert a RISC-V ELF to a $readmemh-compatible hex file.
Uses riscv64-unknown-elf-objcopy to extract raw binary, then
writes one byte per line in hex, with base address 0x80000000
subtracted (memory starts at index 0).
"""
import subprocess, sys, os, tempfile

def elf2hex(elf_path, hex_path):
    with tempfile.NamedTemporaryFile(suffix='.bin', delete=False) as tmp:
        tmp_bin = tmp.name
    try:
        subprocess.check_call([
            'riscv64-unknown-elf-objcopy', '-O', 'binary', elf_path, tmp_bin
        ], stderr=subprocess.DEVNULL)
        with open(tmp_bin, 'rb') as f:
            data = f.read()
        with open(hex_path, 'w') as f:
            for byte in data:
                f.write(f'{byte:02x}\n')
    finally:
        os.unlink(tmp_bin)

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.elf> <output.hex>")
        sys.exit(1)
    elf2hex(sys.argv[1], sys.argv[2])
