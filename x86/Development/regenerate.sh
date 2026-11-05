#!/bin/sh
# SPDX-FileCopyrightText: (C) 2026 Gavin John
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regenerate the .hex0, .hex1 and .hex2 sources in ../, and M2libc's
# ntdll-slots.h, from the generators here, and check that each program among
# them assembles to exactly the binary its generator built.
set -e

# CC_X86_UPSTREAM (see the end of this file) is a path from wherever this was
# run, and everything below runs from here, so make it absolute first.
case ${CC_X86_UPSTREAM:-} in
  '' | /*) ;;
  *) CC_X86_UPSTREAM=$PWD/$CC_X86_UPSTREAM ;;
esac
cd "$(dirname "$0")"

# The binaries the generators build are only compared, never kept.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM

python3 gen_hex0.py   "$scratch/hex0.exe"  ../hex0_x86.hex0 hex0_32-original.exe
python3 gen_hex1.py   "$scratch/hex1.exe"  ../hex1_x86.hex0 hex0_32-original.exe
python3 gen_hex2.py   "$scratch/hex2.exe"  ../hex2_x86.hex1 hex0_32-original.exe
python3 gen_header.py ../PE32-i386.hex2
python3 gen_catm.py   "$scratch/catm.exe"  ../catm_x86.hex2
python3 gen_ntdll.py  "$scratch/ntdll.exe" ../ntdll-i386.hex2 ../../M2libc/x86/windows/ntdll-slots.h
python3 gen_m0.py     "$scratch/M0.exe"    ../M0_x86.hex2 ../ntdll-i386.hex2
cmp "$scratch/hex0.exe" ../../bootstrap-seeds/PE32/i386/hex0-seed.exe
echo "seed still reproduces"

# libc-core.M1 is hand-written M1 whose mnemonics have to exist in the
# x86_defs.M1 it will be concatenated with.  M0 does not diagnose one that
# doesn't -- it passes the token through and the instruction silently vanishes
# -- so check here, where the failure is a message rather than a corrupt binary
# noticed several stages later.
python3 check_mnemonics.py ../libc-core.M1 ../../M2libc/x86/x86_defs.M1
python3 check_mnemonics.py ../libc-full.M1 ../../M2libc/x86/x86_defs.M1
python3 check_mnemonics.py ../libc-bootstrap.M1 ../../M2libc/x86/x86_defs.M1

# cc_x86.M1 is readable assembly rather than hex, so it is not written from
# scratch here: port_cc_x86.py patches upstream's copy.  Point CC_X86_UPSTREAM
# at a stage0-posix checkout's x86/cc_x86.M1 to re-derive it and see whether
# upstream has moved under any of the passages the port replaces.
if [ -n "${CC_X86_UPSTREAM:-}" ]; then
  python3 port_cc_x86.py "$CC_X86_UPSTREAM" ../cc_x86.M1
else
  echo "cc_x86: not re-derived (set CC_X86_UPSTREAM to upstream's x86/cc_x86.M1)"
fi
