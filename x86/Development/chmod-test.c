/* SPDX-FileCopyrightText: (C) 2026 Novavero AI Inc.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Additional permission under GNU GPL version 3 section 7:
 * see LICENSE.EXCEPTION in the root of this project.
 *
 * Calls chmod(argv[2], argv[1]) once, with argv[1] read as a number (0755 is
 * octal, as in C), and exits 0 if chmod returned 0, 1 if it did not and 2 if
 * the arguments are wrong.  What chmod did to the file is for the caller to
 * look at: the chain's CI reads the nova.exec stream beside it through
 * PowerShell, which reaches streams through Win32 rather than this layer.
 *
 * Built by the chain's CI against the full M2libc and libc-full.M1, and
 * linked by hex2-new, whose own chmod(output, 0750) marks it; the step there
 * lists the files it compiles with. */
#include <sys/stat.h>

int main(int argc, char** argv)
{
	if(3 != argc) return 2;
	if(0 != chmod(argv[2], strtoint(argv[1]))) return 1;
	return 0;
}
