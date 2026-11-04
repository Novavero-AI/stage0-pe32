/* SPDX-FileCopyrightText: (C) 2026 Novavero AI Inc.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Additional permission under GNU GPL version 3 section 7:
 * see LICENSE.EXCEPTION in the root of this project.
 *
 * Writes a line to a file through stdio and returns from main without
 * closing the file.  Returning from main is an exit (C99 5.1.2.2.3), and exit
 * flushes every open stream, so exit-flush.txt has to hold the line afterwards.
 *
 * Built and run by the chain's CI against the full M2libc and libc-full.M1;
 * the step there lists the files it compiles with. */
#include <stdio.h>

int main()
{
	FILE* f = fopen("exit-flush.txt", "w");
	if(NULL == f) return 1;
	fputs("flushed\n", f);
	return 0;
}
