#!/usr/bin/env bash
# ============================================================
#  get_sym.sh — Extract symbol offset (relative to 0x80000000)
#  Usage: ./get_sym.sh <elf> <symbol_name>
# ============================================================
BASE=0x80000000
ELF="$1"
SYM="$2"
ADDR=$(riscv64-unknown-elf-nm "$ELF" 2>/dev/null | grep -w "$SYM" | head -1 | awk '{print $1}')
if [ -z "$ADDR" ]; then
    echo "-1"
else
    python3 -c "print(0x${ADDR} - ${BASE})"
fi
