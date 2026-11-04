/* SPDX-FileCopyrightText: (C) 2026 Novavero AI Inc.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Additional permission under GNU GPL version 3 section 7:
 * see LICENSE.EXCEPTION in the root of this project.
 *
 * A file opens to read while another handle on it can write, as POSIX
 * allows: GNU Mes keeps each file it writes open until it exits, and MesCC
 * runs M1 on the assembly it has just written.  The program opens share.txt
 * to write, writes a line and flushes it, then opens the same file to read
 * with the first still open.  It exits 1 if that open fails or what it reads
 * is not the line, and 0 if it reads the line back.
 *
 * Built and run by the chain's CI against the full M2libc and libc-full.M1;
 * the step there lists the files it compiles with. */
#include <stdio.h>

int main()
{
	FILE* out;
	FILE* in;
	char* want;
	int i;
	int c;

	want = "shared\n";
	out = fopen("share.txt", "w");
	if(NULL == out) return 1;
	fputs(want, out);
	fflush(out);

	in = fopen("share.txt", "r");
	if(NULL == in) return 1;
	i = 0;
	c = fgetc(in);
	while(EOF != c)
	{
		if(c != want[i]) return 1;
		i = i + 1;
		c = fgetc(in);
	}
	if(0 != want[i]) return 1;
	return 0;
}
