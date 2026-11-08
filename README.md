<!--
SPDX-FileCopyrightText: (C) 2026 Gavin John
SPDX-FileCopyrightText: (C) 2026 Novavero AI Inc.

SPDX-License-Identifier: GPL-3.0-or-later
-->

# stage0-pe32

A full-source bootstrap for Windows, in the shape of
[stage0-posix](https://github.com/oriansj/stage0-posix).

Every program in the chain is built from source by the chain itself, starting
from a 1623-byte seed whose own annotated source is in the tree. Each link is
written in the language of the link below it, so the whole thing can be audited
by reading, from the bottom up.

    bootstrap-seeds/PE32/i386/hex0-seed.exe   1623 bytes, the trust anchor
    x86/hex0_x86.hex0                         hex0, written in hex0
    x86/hex1_x86.hex0                         hex1, written in hex0
    x86/hex2_x86.hex1                         hex2, written in hex1
    x86/catm_x86.hex2                         catm, written in hex2
    x86/PE32-i386.hex2                        the PE32 header, in hex2
    x86/ntdll-i386.hex2                       the shared Windows plumbing, in hex2
    x86/M0_x86.hex2                           M0, written in hex2
    x86/cc_x86.M1                             cc_x86, written in M1
    M2-Planet                                 a fuller C compiler, in C
    mescc-tools/M1-macro.c                    M1-macro, a fuller assembler, in C
    mescc-tools/hex2_linker.c                 hex2 again, in C, without the fixed table
    mescc-tools/Kaem/kaem.c                   kaem, a shell, in C

| link | adds |
| ---- | ---- |
| hex0 | hexadecimal pairs become bytes |
| hex1 | single character labels, and relative pointers to them |
| hex2 | labels with names, pointers with widths: a linker |
| catm | concatenating files, so a header can be put in front of a program |
| M0   | macros, strings and immediates: the first real language |
| cc_x86 | a subset of C, large enough to compile M2-Planet |
| M2-Planet | the rest of the C this project's programs are written in |
| M1-macro | more label and pointer widths, and every architecture stage0 supports, in one binary |
| hex2 (from C) | the same linker without the hand-written one's fixed label table |
| kaem | a shell built from source, for what builds on the chain |

## Building

Clone with submodules -- from cc_x86 up, the build compiles C, and M2-Planet,
M2libc, mescc-tools and mescc-tools-extra are vendored as submodules rather
than by hand.  mescc-tools-extra is upstream's exactly as upstream wrote it.
M2libc is a fork that carries the `x86/windows/` target and a Windows path in
`_malloc_brk`, mescc-tools a fork that carries kaem's Windows changes, and
M2-Planet a fork that carries two general fixes, all described where they
matter below.

The chain and kaem's tests read their files byte for byte as committed. Git
for Windows installs with `core.autocrlf` set to `true`, which checks text
files out with CRLF line endings, so turn it off before cloning:

    git config --global core.autocrlf false
    git clone --recurse-submodules <this repo>

`git -c core.autocrlf=false clone --recurse-submodules <this repo>` checks out
the submodules unchanged too and leaves the global setting alone, but it
applies to that one command: a later checkout or `git submodule update`
without it writes CRLF again.

From the root of the clone, on x64 or ARM64 Windows:

    x86\mescc-tools-mini.cmd

Upstream drives the equivalent sequence with kaem, a shell it has to bootstrap
first. Windows always has cmd.exe, so there is nothing to bootstrap: the build
script is ordinary batch, and it is the only part of this that is not built
from source here.

The first thing the build does is assemble `hex0_x86.hex0` with the seed and
require the result to be identical to the seed; if it is not, the build stops
with `hex0.exe is not the seed`.

## How this differs from stage0-posix

There are no syscalls. A PE32 image here imports nothing at all: it finds ntdll
through the PEB at run time and resolves the handful of routines it needs from
ntdll's export table by name. There is no import table to inspect and nothing
between the file and the kernel.

That plumbing is the same in every program, so from M0 upward it lives in
`x86/ntdll-i386.hex2` and catm puts it in front of the program, the way it puts
the header stub in front of both. Part of it is splitting the command line,
because Windows hands a program one string rather than a vector: from M0 up
that split is the whole rule `CommandLineToArgvW` defines, backslash escaping
and all, since anything that launches another program writes an embedded quote
as `\"` and an argument cut off at the first one is worse than useless. hex0, hex1, hex2 and catm cannot use it --
there is no catm below catm to join files with -- so they carry their own
copies. Upstream has the same arrangement in `x86/libc-core.M1`.

There is no `brk`. `x86/PE32-i386.hex2` gives every program a section whose
VirtualSize runs to the top of a 128 MB image, so the memory past the end of
the file is already mapped and already zero. A hand-written link declares a
buffer by putting a label after `:PE_end` and never asks the operating system
for memory; M0 processing the M1 that builds M2-Planet uses over 22 MB of it.
The `malloc` in M2libc's `stdlib.c` hands out that section first, in 8-byte
aligned blocks, and reserves more from the system once it runs out.

`SectionAlignment` is the page size, and the header pads to 0x1000 to match.
The format permits less, and Wine accepts less, but Windows 11 refuses such an
image with ERROR_BAD_EXE_FORMAT. `SizeOfRawData`, which the format says must be
a multiple of `FileAlignment`, is left as the exact length of the program, and
that Windows does accept.

This chain does not use kaem: cmd.exe drives it, see Building above. Its last
link builds kaem all the same, for what builds *on* the chain: nova-nix, which
has no cmd.exe to reach for, wants a shell that is itself built from source.
kaem's changes for Windows are all under `__windows__`, in the mescc-tools fork
named under Building:

- It starts a program with `spawn` from `M2libc/x86/windows/process.c`, which
  starts it and waits for it in one step, as kaem does on UEFI. Windows has no
  call that replaces a running program, so `execve` there starts the program
  as a new process, waits for it and exits with its status, and `fork` then
  `execve` would make two processes for every command where `spawn` makes one.
  `exec` calls that `execve`, so a script ends at `exec` as it does on POSIX.
- A name that starts with `.` or `/`, or whose second character is a colon
  (`C:/tools/foo.exe`), is a path, and kaem runs it exactly as written, so a
  path to a program has to name its `.exe`. Any other name it looks for in
  each directory of PATH, which it splits on semicolons, first as given and
  then with `.exe` after it.
- As it reads the environment it renames `Path`, the name Windows gives the
  search path, to PATH, the name kaem and its scripts use.

`x86\kaem-test.ps1` runs kaem's own tests, `mescc-tools/Kaem/test`, against
the kaem the chain built. It takes each test and its flags from
`mescc-tools/Kaem/test.sh` and checks each output against the hashes in
`test.answers`. It needs PowerShell 7, and a `printf` on the search path for
the tests that run one. Git for Windows has `printf.exe` in its `usr\bin`,
which a default install leaves off the search path. After the build, at
cmd.exe, from the root of the clone:

    set PATH=%PATH%;C:\Program Files\Git\usr\bin
    pwsh x86\kaem-test.ps1

## Where the sources come from

The `.hex0`, `.hex1` and `.hex2` files are generated, by the scripts in
`x86/Development/`, and they are the reviewable artefact -- every byte carries
the instruction it encodes and the reason for it. Regenerate and re-verify them
with:

    x86/Development/regenerate.sh

Each program's generator assembles the source it wrote and compares the result
with the binary it built, and hex0's has to be the seed, so a source that has
drifted from its binary fails there rather than later. CI runs `regenerate.sh`
and fails if it changes anything in the tree, so a generator and what it writes
are committed together.

`x86/cc_x86.M1` is the exception, because it is readable assembly rather than
hex and because the compiler in it is upstream's and is not being ported. It is
derived from upstream's `x86/cc_x86.M1` by `x86/Development/port_cc_x86.py`,
which is written as a list of exact before-and-after passages: every one of them
must match, so if upstream moves under any of the places this port replaces, the
script fails rather than quietly producing something nobody has read. Point
`CC_X86_UPSTREAM` at an upstream checkout's `x86/cc_x86.M1` to re-derive it:

    CC_X86_UPSTREAM=../stage0-posix/x86/cc_x86.M1 x86/Development/regenerate.sh

The whole of the port is `_start`, `malloc`, `fgetc`, `fputc`, the two exits
(`Exit_Failure` and the one that ends `debug_list`), a new `use_stderr` that
points error messages at the console, and the name of the label that ends the
image, with the macros and globals those need. Feed the same C to upstream's
`cc_x86` and to this one and the two outputs differ in exactly one line, the
`:ELF_end` that becomes `:PE_end`. The binaries share nothing -- different
format, different entry, different plumbing -- but the compiler between them is
demonstrably the same compiler.

From cc_x86 up, the chain compiles C rather than hand-written assembly, and the
C it compiles first is M2-Planet's own: `M2-Planet/`, `M2libc/` and
`mescc-tools/` are git submodules. Each follows upstream's default branch, with
the commits upstream has not taken on top. Almost nothing in them is
Windows-specific: mescc-tools needs kaem's changes listed above, and M2libc
needs the `x86/windows/` target this project wrote and a Windows path in
`_malloc_brk`.

M2-Planet needs nothing Windows-specific either, but carries two fixes that
are not. The first: `&&` and `||` were compiled as the exact same instruction as `&`
and `|` on every architecture -- both sides evaluated unconditionally, no
short-circuit, the raw bitwise combination kept as the result rather than
0 or 1. `if (p && *p)`, the ordinary C idiom for "don't read through a
pointer that might be null", read through it first and checked second.
Found by exactly that shape crashing GNU Mes's own `__assert_fail` on this
port -- the two are pinned against each other for a reason -- but the bug
and the fix are both general; nothing about them is Windows's.

The second: `&p[i]` started from the address of the variable `p` rather than
its value whenever `p` was a pointer or a global array, so it compiled to the
wrong address without a warning. Upstream's own fix covers local arrays only;
this one is offered upstream.

`mescc-tools-extra/` follows upstream's master as well, with nothing on top,
because nothing in it needed porting at all. It is not part of the chain, which
neither builds nor uses it, but mkdir, cp, chmod and the unpackers are what
anything built on top of the chain reaches for once it has a compiler, and
they are ordinary C standing on the same M2libc. `x86/libc-core.M1` and `M2libc/x86/windows/bootstrap.c` are
what M2-Planet and M1-macro compile against instead of
`M2libc/x86/linux/bootstrap.c` -- the argc/argv/exit plumbing a C program
needs, standing on `x86/ntdll-i386.hex2` the same way `x86/cc_x86.M1` does. See
their own headers for what each routine does.

The two C libraries need different things done around `main`, so
`libc-core.M1`'s `_start` calls `:__libc_init` before it and `:__libc_fini`
after it, and catm decides what those are: `x86/libc-bootstrap.M1`, where both
do nothing, or `x86/libc-full.M1`, where `__libc_init` calls M2libc's
`__init_malloc` and `__init_io` and `__libc_fini` calls `__kill_io`. The second
is not optional and its absence is quiet: `stdin`, `stdout` and `stderr` are
globals that start NULL, so a program linked without it works until the first
time it tries to report an error and then faults inside `fputs` instead of
printing it. `__kill_io` is what makes returning from `main` an exit, as C
requires: it flushes every stream, so output a program wrote and never closed
is not lost.

`M2libc/x86/x86_defs.M1` -- the submodule's copy, not a copy of it -- matters
more than its name suggests: it is the mnemonic set M2's own code generator
actually emits, wider than what cc_x86.M1's hand-written assembly happens to
use. Getting this wrong doesn't fail loudly. M0 passes an unrecognized
mnemonic through as plain text rather than erroring, hex2 can't make sense of
it either, and the instruction is silently dropped: the build succeeds, the
binary comes out a few bytes short, and the failure surfaces later as an
illegal instruction somewhere unrelated.

`regenerate.sh` runs `x86/Development/check_mnemonics.py` on each of
`libc-core.M1`, `libc-full.M1` and `libc-bootstrap.M1` together with
`M2libc/x86/x86_defs.M1`, and it fails on a mnemonic nothing DEFINEs.

M2-Planet's own C is unmodified, so it always ends its output with `:ELF_end`,
the label its ELF header expects; `PE32-i386.hex2` expects `:PE_end`.
`x86/pe-end-shim.M1` defines `:PE_end` at that same address without touching
the vendored source -- catm puts it right after M2's output.

`M2libc/x86/windows/` is where the port actually lives. `bootstrap.c` is the
whole C library for the stages that can use `--bootstrap-mode`; `unistd.c`,
`fcntl.c` and `sys/stat.c` are the POSIX layer underneath M2libc's own
`stdio.c` for the stages that cannot. A file descriptor is a Windows HANDLE,
with 0, 1 and 2 still meaning the three standard streams -- no real handle is
that small, so nothing above can tell. `open` shares the file for reading,
writing and deletion, because a POSIX open is never refused for another process
having the file open: GNU Mes keeps each file it writes open until it exits,
and MesCC runs M1 on the assembly it has just written. `brk` has nothing to ask
the kernel for, since the image carries its writable memory with it. Windows
runs a PE because its header says so and keeps no executable bit, but a Nix
archive records one for every regular file, so `chmod` keeps the owner execute
bit as the `nova.exec` alternate data stream nova-nix reads it from: set, the
stream is made; clear, it is removed. hex2 built from C calls
`chmod(output, 0750)` on what it links, so its output is marked as on Linux.

Everything M2libc's `unistd.h` and `sys/stat.h` declare is there.
`M2libc/x86/windows/ntdll.c` is what the rest of it stands on:
`__ntdll_resolve(name)` finds a routine by walking this process's own
PEB -> Ldr -> module list and ntdll's own export table, in-process, and
`__ntobject(path)` turns a filename into the OBJECT_ATTRIBUTES around an NT
path that every ntdll call naming a file wants. `x86/Development/
ntdll-resolve-test.c` checks it against every routine the older mechanism
below still resolves, by name, and confirms a name ntdll does not export
comes back NULL rather than something else's address.

Underneath that, hex0 through M0 -- which have no C compiler yet and so
cannot call `__ntdll_resolve` -- still reach ntdll the older way: by a fixed
slot `resolve_all` fills in at startup (`ntdll-i386.hex2`), which
`__ntdll(slot)` and `M2libc/x86/windows/ntdll-slots.h`'s `NT_*` constants
name. `ntdll-slots.h` is generated from the same list `ntdll-i386.hex2` is,
so the two cannot drift apart. Of the C, only `ntdll-resolve-test.c` reads it:
the compiled C layer above calls `__ntdll_resolve` instead.
`x86/Development/posix-test.c` calls every routine once and checks the
answer.

Where Windows has no answer -- `chroot`, `mount`, `unshare`, `symlink`,
`mknod`, `fchdir`, `fchmod` -- the call fails, and says why above itself.
Failing is the point: `chroot` returning 0 would tell its caller something
that is not true.

Calling ntdll from compiled C works because of an accident of M2-Planet's code
generator, and comes with a rule that has to be kept by hand. M2-Planet saves
the stack pointer in EBP before pushing arguments and restores it from there
afterwards, so it never adds back what it pushed -- which is what lets it call
stdcall routines that pop their own arguments. It also pushes the first
argument first, so every call below is written backwards.

`M2libc/x86/windows/process.c` is starting another program and waiting for it,
and `fork`.

`fork` is `__clone_process_wow64fix`: Windows' own clone call,
`RtlCloneUserProcess`, with the child's one thread set up before it runs. The
clone has its parent's whole address space, so the child comes back from
`fork` with 0, on its parent's stack and with its parent's memory, and the
parent gets the child's process handle. Left alone, the child of a 32-bit clone
on 64-bit Windows hangs or dies in its loader init, for the reasons
[`x86/Development/fork-notes.md`](x86/Development/fork-notes.md) sets out. So
`fork` clones with the child's thread suspended and, before letting it go,
starts that thread at `wow64cpu!BTCpuSimulate`, the entry to the loop that runs
32-bit code, sets its 32-bit `Eax` to `STATUS_PROCESS_CLONED`, the status a
clone's child returns with, and clears a lock in the child's `ntdll` that the
parent held across the clone.

What it rests on:

- The lock is found at a fixed distance from `RtlCloneUserProcess`, taken from
  one Windows 11 machine's `ntdll` rather than looked up, and nothing checks
  it: under any other `ntdll` build, `fork` zeroes four bytes of the child's
  `ntdll` that hold something else.
- Wine does not export `RtlCloneUserProcess`, so there `fork` returns -1.
- In a process with no `wow64cpu.dll` among its 64-bit modules, `fork` is the
  plain clone, `__clone_process`, which has not been measured running.
- `x86/Development/fork-test.c`, `fork-file-test.c`, `fork-deep-test.c` and
  `fork-many-test.c` exercise it: the child's copy of a local and of something
  malloc handed out, its output landing in the parent's stream, a file its
  parent opened, a fork from deep in a call chain, a hundred forks in a row,
  `waitpid` bringing back what the child exited with, and `fork` with `execve`
  after it. CI does not run them.

`waitpid` stores 256 times the child's exit status, the encoding a caller's
`WEXITSTATUS` expects. A child that dies of an exception exits with an
`NTSTATUS` such as `0xC0000005`, which that multiplication wraps to `0x500`, so
it reads as a normal exit with status 5. This and the unchecked lock offset are
tracked, with the rest of what is known to be wrong, in the
[open issues](https://github.com/Novavero-AI/stage0-pe32/issues).

A file the parent had open is open in the child, at the same descriptor.
`fork` asks the clone to inherit handles, and that is why the shared
`open_file` asks for `OBJ_INHERIT`: an inheritable handle is the one kind a
child receives, and it receives it under the *same number*, which is what keeps
the number in the child's copy of memory meaningful. POSIX hands every
descriptor to a child across both fork and exec unless it is marked
`FD_CLOEXEC`, and there is no `FD_CLOEXEC` here to ask for the other behaviour.
Only the shared copy asks for it, and only the shared copy shares a file for
writing and deletion as well as reading: `hex0`, `hex1`, `hex2` and `catm` carry
their own `open_file`, none of them forks, and `hex0`'s bytes *are* the seed the
chain is checked against -- so changing theirs would move the trust anchor to
no purpose.

Four calls, and a caller wanting a child may say either what POSIX says or the
shorter thing Windows can do directly:

    fork()                      twice-returning, 0 in the child
    __spawn(path, argv, envp)   start a program; a handle to it comes back
    waitpid(pid, &status, 0)    wait for one of those to finish
    execve(path, argv, envp)    both of the above, and then exit as it did

`fork` and `execve` together do what fork and exec do anywhere. `__spawn` is
the cheaper way to say the same thing when the child is only ever going to
exec: one process where fork plus execve is two.

A pid is the process handle, the way a file descriptor is a file handle.
`execve` does not replace the running image, because nothing on Windows can:
it starts the program, waits for it and exits with its status, so it does not
return and the process's exit status is the child's. `spawn` beside them is
`__spawn` then `waitpid` in one call, returning what the program exited with,
under the name M2libc's UEFI target gives it, and it is what kaem uses for
every command but `exec`.

The child inherits this process's three standard handles, which is what makes
redirection possible. Each handle is duplicated with `OBJ_INHERIT` and its
number written into the child's parameter block, where the child reads it back
out of its own PEB. Do only that and the child writes, `NtWriteFile` answers
`STATUS_SUCCESS` with a count in the `IO_STATUS_BLOCK`, and nothing arrives
anywhere -- under Wine it works, on Windows it does not.

What happens in between is that the child's own startup replaces those handles.
It copies the parameter block onto its heap and fills the three handle fields
in with console handles of its own before the program's first instruction, so
the numbers the parent wrote are already gone, and writes to what replaced them
are accepted and discarded. Measured, with the child suspended and then asked
from the inside: its `PEB->ProcessParameters` is not the address the parent
poked, the handle it ends up with is not the one it was given, and
`NtQueryInformationFile` on it answers `STATUS_INVALID_DEVICE_REQUEST` where the
parent's own handle names the pipe it really is. The handle the parent
duplicated is still there and still works -- writing to it by number, from
inside the child, reaches the parent's pipe -- so what is lost is the three
fields, not the handles.

The flag that stops it is `STARTF_USESTDHANDLES`, in the parameter block's
`WindowFlags` at `0x68`. ReactOS's `SetUpHandles`
(`dll/win32/kernel32/client/console/init.c`) is the same decision written down:
it assigns the console's handles over the parameter block's only
`if ((dwStartupFlags & STARTF_USESTDHANDLES) == 0)`. A Win32 caller sets that
flag by filling in `STARTUPINFO`'s `hStdInput`, `hStdOutput` and `hStdError`,
and nothing in `RtlCreateUserProcess`'s arguments reaches it, so `__spawn`
writes it into the block directly. With it set the handles survive and a
child's output lands wherever the parent's does -- console, pipe or redirected
file, all three checked on Windows 11.

`NtCreateUserProcess` called directly, rather than through
`RtlCreateUserProcess`, does not fix this either. Its `PS_ATTRIBUTE_LIST` is the
only way to ask for `PsAttributeStdHandleInfo` and `PsAlwaysDuplicate` --
"always duplicate standard handles" -- but the replacement happens in the child
afterwards regardless. It needs every structure 8-aligned, `PS_CREATE_INFO`
holding `ULONGLONG`s and the kernel answering `STATUS_DATATYPE_MISALIGNMENT`
otherwise; with that done it returns `PsCreateSuccess` and the child runs. So
`__spawn` uses `RtlCreateUserProcess`, which is the same call with less to get
wrong. Wine does not have the problem: it does this in kernelbase rather than in
ntdll -- `init_console_std_handles`, called from `dlls/kernelbase/console.c` --
and a program that imports ntdll and nothing else never loads kernelbase, so
there is nothing there to overwrite the three fields and the flag is never
consulted. Every program this bootstrap builds is such a program, so Wine
agreeing is not evidence that Windows will.

Windows hands a child one string rather than a vector,
so `__spawn` joins argv into one and the child splits it again; both halves
follow `CommandLineToArgvW`, so an argument survives whatever is in it.
`C:\dir\` is the case that makes the rule worth following exactly rather than
approximately: quoted naively it ends `...dir\"`, and the reader takes that
backslash to be protecting the closing quote and swallows the rest of the
command line.

`x86/Development/spawn-test.c` starts a program, waits for it, reads back what
it exited with, and ends by calling `execve` and not coming back.

## M1-macro without blood-elf

M1-macro is a fuller assembler than M0: more label and pointer widths, every
architecture stage0 supports in one binary. Upstream also runs this stage's
output through `blood-elf`, and this port does not, which is worth setting out
properly because everything downstream of here -- GNU Mes included -- runs
blood-elf too.

Three things go together, and all three are debugging. `--debug` makes
M2-Planet end its output with `:ELF_data` instead of `:ELF_end`. blood-elf
then reads that output and writes an ELF string table, symbol table and
section headers -- and the `:ELF_end` M2-Planet did not write. The "debug" ELF
header declares five sections and refers to `:ELF_section_headers`, which is
why it needs blood-elf's output to link at all. Drop `--debug`, drop blood-elf
and use the plain ELF header, and M2-Planet emits `:ELF_end` itself; the plain
header wants nothing from outside but that label and `:_start`. Which is
exactly the shape `PE32-i386.hex2` has, with `:PE_end` for `:ELF_end`.

So there is nothing to port, and the symbol table is what `objdump` and `gdb`
read and nothing else does. Checked on GNU Mes: built at
`f244b14` twice with native tools, once as `kaem.run` ships and once with
`--debug` and blood-elf removed and the plain ELF header in place. Both
`bin/mes-m2` binaries run, agree character for character on a program
exercising recursion, `map`, `assq`, strings and `write`, and pass the same ten
of Mes's own tests. The blood-elf one is 232686 bytes and the other 131262:
the whole difference is the debugging information.

## Licence

GNU General Public License version 3 or later, as upstream is. See `LICENSE`.

`LICENSE.EXCEPTION` adds a permission under section 7 for embedding these files
and the binaries built from them in a package repository without the repository
as a whole becoming GPL, so long as these files themselves stay GPL.

## Thanks

To Jeremiah Orians and everyone on #bootstrappable, whose work this is a port
of. The design is theirs; the mistakes in this port are not.
