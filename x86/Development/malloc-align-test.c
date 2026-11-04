/* SPDX-FileCopyrightText: (C) 2026 Novavero AI Inc.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Additional permission under GNU GPL version 3 section 7:
 * see LICENSE.EXCEPTION in the root of this project.
 *
 * malloc and calloc hand out memory aligned for any object, on the 8-byte
 * boundary Windows guarantees on x86, whatever was allocated before and
 * wherever the program's data ended.  Windows checks some of this itself: a
 * file call whose name's buffer is at an odd address fails with
 * STATUS_DATATYPE_MISALIGNMENT.  Each size from 1 to 39 is allocated both
 * ways, and the program exits 1 at the first block that is not aligned and 0
 * if none is.
 *
 * Built and run by the chain's CI against the full M2libc and libc-full.M1;
 * the step there lists the files it compiles with. */
#include <stdlib.h>

int main()
{
	int size;
	int at;

	size = 1;
	while(size < 40)
	{
		at = malloc(size);
		if(0 != (at % 8)) return 1;
		at = calloc(size, 1);
		if(0 != (at % 8)) return 1;
		size = size + 1;
	}
	return 0;
}
