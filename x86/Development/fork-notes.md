<!--
SPDX-FileCopyrightText: (C) 2026 Gavin John
SPDX-FileCopyrightText: (C) 2026 Novavero AI Inc.

SPDX-License-Identifier: GPL-3.0-or-later
-->

# fork under WOW64: research notes

## Windows' own fork primitive

Windows does have a fork primitive. `NtCreateProcessEx` given a parent and no
section handle clones the parent's address space instead of mapping an image --
ReactOS's own `PspCreateProcess` reaches that branch and says *"This is a
clone!"* before declining to implement it. An earlier version of this section
said `RtlCloneUserProcess` wraps that call. It does not: disassembling
`ntdll32.dll` shows it calling a private helper that ends in
`ZwCreateUserProcess`, the same syscall behind ordinary process creation, not
`NtCreateProcessEx`. Two unrelated clone paths through the kernel, not one
built on the other -- so a defect found in one says nothing about the other.
`RtlCloneUserProcess` makes
a thread in the result and is meant to return in both processes, handing the
child `STATUS_PROCESS_CLONED` where the parent gets `STATUS_SUCCESS`.

Called plainly, it does not work, by any of the four routes in, all measured
on Windows 11 22621:

| | |
| --- | --- |
| `RtlCloneUserProcess` | clones, and under WOW64 the clone's child runs with no FS base |
| `NtCreateProcessEx` | clones, and the clone cannot be given a thread |
| `NtCreateProcess` | the same, by the older name |
| `NtCreateUserProcess` | the supported one, which does not clone at all |

The first of those was measured again from a native 64-bit caller on the same
machine, and there the clone's child does come back, and runs. So the defect is
WOW64's rather than cloning's -- no help at all to a 32-bit bootstrap, but it
says where to look in an x86_64 one.

The parent gets success and a genuine cloned process -- two in `tasklist`, the
child reported `STATUS_PENDING` -- and the child's one thread, which is not
suspended, never reaches the first statement after the call. It is not this
port's doing: the identical call from 64-bit and from 32-bit PowerShell clones
the process and never returns in the child either -- though see below for what
that observation does and does not establish.

How it stops depends on the flags. Without `NO_SYNCHRONIZE` the child
**deadlocks**; with it the child **runs and dies** of an access violation. Two
earlier versions of this section got this wrong in opposite directions -- one
said the outcome was the same for every flag combination, the next said the
child stopped in a different *place* depending on them. It stops in the same
place either way; what the flags change is whether it can say so. The deadlock is an
inherited lock. `RtlCloneUserProcess` holds the SRW lock at `ntdll+0x12d7a4`
exclusively across the clone -- disassembling it shows that address four times
inside the one routine -- so the child's address space is a snapshot in which it
is held, and anything on the child's side that wants it shared waits in
`NtWaitForAlertByThreadId` to be alerted by a thread that does not exist on this
side of the fork. Read out of the child: EIP in `ZwWaitForAlertByThreadId`, the
lock's address twice on the stack, and `LdrInitializeThunk` further up it.

An earlier version of this section called that "now understood" and put the
deadlock first, with the `fs:0x18` fault below as a second, later failure that
only shows up once the lock is out of the way. That is backwards, and the same
stack that settled the `LdrInitializeThunk` question says so. Without touching
the lock at all, the deadlocked child's stack holds, above the frames it is
currently in:

    0x85ff300   an EXCEPTION_RECORD: ExceptionCode 0xc0000005,
                ExceptionAddress ntdll+0x8c5d6, NumberParameters 2,
                ExceptionInformation 0 (a read) and 0x18
    0x85ff350   the CONTEXT paired with it: ContextFlags 0x1007f,
                Eip ntdll+0x8c5d6, Cs 0x23, Esp 0x85ff7b8, SegFs 0x53
    0x85ff2ec   a return address in KiUserExceptionDispatcher+0x26

and below that nothing but exception dispatch -- `RtlUnwind`,
`_except_handler4_common`, `_local_unwind4` -- ending in
`RtlAcquireSRWLockShared+0x148` with `ntdll+0x12d7a4` as its argument, at
`ZwWaitForAlertByThreadId`.

So the fault comes first, every time, lock or no lock. What waits on the
inherited lock is the *exception dispatcher*, trying to report a fault that has
already happened. The child is not stopped short of the fault by a lock; it is
stopped short of ever saying so. Zeroing the lock does not let the child get
further, it lets the fault be reported, so the process dies instead of hanging.
One defect, not two, and the second symptom was only ever the first one being
unable to speak.

That "like any new thread" is worth checking rather than assuming, since the
clone's own thread was a real, running thread before the clone -- it had a
working FS base once, or it could not have gotten anywhere, so something
about the clone loses what it already had. Whether the clone is dispatched
exactly like a brand-new thread (EIP set to 32-bit `LdrInitializeThunk` from
the start, the same place a genuinely new WOW64 thread's native bring-up
hands off to) or instead resumes wherever the parent was -- inside
`RtlCloneUserProcess` itself, the way POSIX `fork` resumes both sides from
the same program counter -- is answerable without running anything: clone
with `CREATE_SUSPENDED`, never resume, and read `NtGetContextThread` before
the thread has executed a single instruction. Measured: `Eip` is
`ZwCreateUserProcess+0xc`, `Cs` is `0x23`. Not `LdrInitializeThunk`.
`ZwCreateUserProcess+0xc` is inside that syscall's own stub, right where `mov
eax,<number>; mov edx,[Wow64Transition]; call edx` returns -- so the clone's
saved context is not "start a new thread", it is "come back from this same
system call", exactly the way a POSIX fork's child continues from the same
program counter as its parent. `Cs` already being `0x23` says the mode
switch back to 32-bit was already done by whoever built this context, same
as everywhere else in this section.

That sat in tension with "the child's new thread then runs
`LdrInitializeThunk`" above, which was read off the stack of an actually
resumed, actually deadlocked child rather than off its context before running,
and the tension is now settled: both readings are right, and neither of the two
guesses about which one described the entry point was. Clone with
`CREATE_SUSPENDED`, read the context, resume, wait, read the context again and
read the stack it deadlocked on. Before resuming, `Eip` is
`ZwCreateUserProcess+0xc` and `Esp` is `0x85ffce8`. After, `Eip` is
`ZwWaitForAlertByThreadId+0xc`, and on the stack, from the top down:

    0x85ffce8                the Esp the context before resuming had
    0x85ffa1c..0x85ffce8     a whole 716-byte i386 CONTEXT, ContextFlags
                             0x1003f, Eip ZwCreateUserProcess+0xc,
                             Cs 0x23, Esp 0x85ffce8
    0x85ffa10                a pointer to 0x85ffa1c
    0x85ffa00                a return address in LdrInitializeThunk+0x11
    0x85ff9ec                another, LdrInitializeThunk+0x70

So the thread's first 32-bit instruction is 32-bit `LdrInitializeThunk`,
entered with a pointer to a `CONTEXT` written immediately beneath the parent's
stack pointer -- 716 bytes of it, ending exactly at `0x85ffce8` -- and that
`CONTEXT` is precisely what `NtGetContextThread` reported before the thread
ran. The pre-resume context is the *destination*, not the entry point: loader
init runs first and is meant to continue into it when it is done, which is the
same shape as a genuinely new WOW64 thread, whose 32-bit side also begins in
`LdrInitializeThunk` with a context to resume. Nothing detours; the detour
**is** the start, and the "true" context is where it was always going to end
up.

Which is a nicer answer than either guess. The clone is dispatched like a
brand-new thread *and* it resumes from the same program counter as its parent
-- the first describes where it begins, the second where loader init would hand
it off to, and there was never a contradiction between them. No debug port was
needed for this after all; the stack said it.

Zeroing that lock in the child before letting it go therefore turns the hang
into what `NO_SYNCHRONIZE` already showed: an access violation at
`ntdll+0x8c5d6`, which is `mov eax, fs:0x18`, inside a function whose only
caller in the whole DLL is `LdrInitializeThunk`. The same fault either way --
only its reporting differs.

Loader init is the wrong thing for a fork's child to run at all, and there is a
flag for that -- `THREAD_CREATE_FLAGS_SKIP_LOADER_INIT` -- which
`NtCreateUserProcess` will not take, answering `STATUS_INVALID_PARAMETER`;
that is what "NtCreateThreadEx only" in the public headers means.
`NtCreateThreadEx` does take it, and against a clone that already has a thread
it returns `STATUS_SUCCESS`. The older claim that it always answers
`STATUS_PROCESS_IS_TERMINATING` holds only for the thread-less clones
`NtCreateProcessEx` and `NtCreateProcess` make.

That road is closed anyway, for a reason that has nothing to do with cloning:
**`SKIP_LOADER_INIT` cannot be used by a 32-bit process on a 64-bit Windows at
all.** Make such a thread in an ordinary process -- no clone anywhere near it --
point it at a function whose first act is one system call, and the process dies
of `STATUS_ACCESS_VIOLATION` at `ntdll+0x98800`, which is
`jmp dword ptr [Wow64Transition]`.

Why it dies there is the reason it cannot be worked around. Every 32-bit system
call is `mov eax,<number>; mov edx,[Wow64Transition]; call edx`, and what that
reaches is seven bytes in `wow64cpu.dll`:

    jmp  far 0x33:<next>          ; put the CPU in 64-bit mode
    jmp  qword ptr [r15+0xf8]     ; and dispatch through r15

The stub never loads `r15`. It is a register the 64-bit dispatch loop leaves
live when it hands control down to 32-bit code -- `BTCpuSimulate` sets `r12`
from `gs:0x30`, the 64-bit TEB, `r13` from the thread's WOW64 CPU area at
`TEB+0x1488`, and `r15` to wow64cpu's dispatch table, and then runs 32-bit code
with those still in registers. A thread enters that loop as part of its
startup, which is exactly what `SKIP_LOADER_INIT` skips, so its first system
call far-jumps into 64-bit mode with `r15` holding whatever was there and
dereferences it. The fault is reported against the last 32-bit instruction,
which is why the event log points at `ntdll` rather than at `wow64cpu`.

There is nothing to poke: `r15` is live register state, not memory. And the
whole problem is a 32-bit-on-64-bit one -- a native x86_64 program makes system
calls with the `syscall` instruction and has no dispatch loop to be thrown out
of, so this particular objection would not arise in an x86_64 port.

Worth tracing further than "nothing to poke", because the actual question is
whether that setup can be run again, later, from user mode -- and the answer
is no, for a reason worth having by name rather than by symptom. A new WOW64
thread's real first instruction is not 32-bit at all: the kernel
(`nt!PspAllocateThread` / `PspWow64InitThread`) hands it a synthetic exception
whose address is the **64-bit** ntdll's own `LdrInitializeThunk`.
Disassembling that export in `ntdll64.dll` shows exactly the gate this
predicts: a bit test against a flag word in the 64-bit TEB (`test word
[rax+0x17ee], 0x4000`, `rax` from `mov rax, gs:0x30`) that skips a call when
already set and takes it on a fresh thread -- the call being the one-time
WOW64 bring-up. Public research on this exact sequence -- [wbenny, "WoW64
internals",
2018](https://wbenny.github.io/2018/11/04/wow64-internals.html) -- names
every step the disassembly only shows the shape of: `LdrInitializeThunk` ->
`LdrpInitialize` -> `LdrpLoadWow64`, which loads `wow64.dll` and hands off to
`Wow64LdrpInitialize`, which calls `ProcessInit` and `ThreadInit` (this is
where `r12` and `r13` come from, via `RtlWow64GetCpuAreaInfo`) and then
`RunCpuSimulation`, which calls `wow64cpu!BTCpuSimulate`, which sets `r15` and
enters `RunSimulatedCode` -- the loop that never returns and is what finally
executes a 32-bit instruction for this thread, for the first time. Every part
of that chain runs in 64-bit mode, reached only by the kernel choosing
`LdrInitializeThunk` as where a new thread starts. `SKIP_LOADER_INIT` is
exactly the kernel choosing something else instead -- the caller's 32-bit
`StartRoutine`, directly -- which is why the fault above is a clean 32-bit
instruction at a sensible ntdll address rather than garbage: the mode switch
to `CS=0x23` did happen, correctly, by whatever set up the thread's context
in the first place. What did not happen is everything upstream of it. There
is no way from the 32-bit side to reach that chain after the fact: the only
sanctioned 32-to-64 transition a WOW64 thread has is the one at the top of
this section, and it needs `r15` to work -- which is exactly what is
missing. Asking it to bootstrap itself is circular, not merely hard.

It is not a missing page either: the pointer holds the same value in the
clone as in the parent, the code it points at reads in both, and
`NtQueryVirtualMemory` reports the same `State`, the same `Protect`
(`PAGE_EXECUTE_READ`) and the same `Type`.

So the child has to run loader init, and with the lock cleared it does, and
dies inside it at `mov eax, fs:0x18`. Attaching a debug port to the clone --
`NtCreateDebugObject` and `NtDebugActiveProcess`, so it stops at the fault
instead of dying of it -- says what that is:

    ExceptionCode     0xc0000005
    ExceptionAddress  ntdll+0x8c5d6      ; mov eax, fs:0x18
    access            0                  ; a read
    faulting address  0x18
    SegFs             0x53
    SegCs             0x23
    TebBaseAddress    0x21e000

It reads `fs:0x18` and faults on linear address `0x18`, so **the base behind FS
is zero**. Not the selector -- `0x53` is the right one -- and not the TEB, which
exists and can be read from the parent. The descriptor that selector names
simply has no base.

Which *looks* like the same illness as the `r15` one. A 32-bit process on a
64-bit Windows runs inside a WOW64 layer: the kernel programs the
compatibility-mode TEB base for each thread, and the 64-bit dispatch loop keeps
`r12`, `r13` and `r15` live for it. Both are established when a process and its
threads are made the ordinary way, and a clone is not made the ordinary way.

That is as far as the evidence goes, and it is worth being careful about how far
that is. What is measured is that **this** clone's child has an FS with no base.
What is **not** established is the tempting generalisation -- that a cloned
32-bit process can never have WOW64 state -- because something in ntdll says
otherwise, loudly. `RtlCreateProcessReflection`, the only caller
`RtlCloneUserProcess` has in the whole 32-bit ntdll, does this in its child on
getting `STATUS_PROCESS_CLONED` back:

    ba979:  mov eax, fs:0x30      ; reads FS straight away
    ba9c9:  call esi              ; then calls a caller's start routine

So Windows expects a clone's child to have a working FS and to run ordinary
code. Either reflection is broken here for every 32-bit process on the machine,
or reflection does something this code does not and the direct use of
`RtlCloneUserProcess` is what is wrong. Trying to settle it did not settle it:
called on a spawned copy of this program, both with a start routine and with
none at all -- the plain passive snapshot reflection is actually for --
`RtlCreateProcessReflection` does not return, and the calling process
disappears without so much as a fault record. That is not understood either, and
a conclusion built on top of it would not be worth having.

One check does not depend on any of the above, and is worth doing on its own:
whether this machine can clone a 32-bit process by *any* in-box route at all,
which would rule the whole failure in or out as a platform limit rather than a
misuse of one specific call.
[`PssCaptureSnapshot`](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/nf-processsnapshot-psscapturesnapshot),
the documented Windows 8.1+ snapshotting API, says yes: called against a real
32-bit `cmd.exe` with
[`PSS_CAPTURE_VA_CLONE`](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/ne-processsnapshot-pss_capture_flags)
it returns `ERROR_SUCCESS`, and
[`PssQuerySnapshot`](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/api/processsnapshot/nf-processsnapshot-pssquerysnapshot)`(PSS_QUERY_VA_CLONE_INFORMATION)`
hands back a clone process handle that `GetExitCodeProcess` reports
`STILL_ACTIVE` and `IsWow64Process` reports genuinely 32-bit. So this machine,
this hypervisor, this WOW64 -- none of them are categorically incapable of a
working 32-bit clone.

That does not settle the question above, though, and claiming it did would be
the same mistake again. `PssCaptureSnapshot` is not `RtlCloneUserProcess` by
another name: internally it calls `PssNtCaptureSnapshot`, which -- per
[Hunt & Hackett's write-up of process cloning on
Windows](https://www.huntandhackett.com/blog/the-definitive-guide-to-process-cloning-on-windows)
-- relies on `NtCreateProcessEx`-based cloning: the very call
`PspCreateProcess` was seen declining to implement, and, per the correction
above, a different syscall from the one `RtlCloneUserProcess` actually uses.
What is confirmed is narrower than "cloning works here": the
`NtCreateProcessEx` clone path works, completely, for a 32-bit target, with
whatever WOW64 setup that path does that `RtlCloneUserProcess`'s does not.
Whether `RtlCloneUserProcess`'s own path -- through `ZwCreateUserProcess` --
shares that defect, has a different one, or has none at all under different
handling is exactly as open as it was. What this does rule out is the
broadest excuse available: "this VM just can't do it." Something here can.
Whether the thing `__clone_process` calls is that something remains unknown.

One question about `RtlCloneUserProcess`'s own clone can be answered without
running anything on the side that is broken: is the FS-with-no-base defect a
property of the one thread the clone hands back, or of the clone process
itself? Clone with `CREATE_SUSPENDED` and never resume that thread -- so
neither the lock deadlock nor the FS fault above can happen -- and ask
`NtQueryInformationProcess(ProcessWow64Information, class 26)` about the
child's process handle. It answers with a real PEB32 address, not zero and
not a failing status. So the clone's process-level WOW64 association came
through intact; what is missing is scoped to the one thread, not the process.
That keeps open a narrower question than the one above: whether a thread made
the ordinary way afterwards -- fresh, with `NtCreateThreadEx`, never touching
the cloned thread at all -- would get the segment setup that thread did not.

Tried, and inconclusive rather than answered. `RtlExitUserThread` needs no
hand-written assembly to satisfy "never returns through an ordinary call
frame": it is documented `DECLSPEC_NORETURN`, and handed to
`NtCreateThreadEx` directly as `StartRoutine` with a distinctive `NTSTATUS`
as `Argument`, it ends the (single) thread -- and so the process -- with that
value if it ever gets there. Against the clone: `STATUS_ACCESS_DENIED`, even
from a handle freshly opened with `NtOpenProcess` asking for
`PROCESS_ALL_ACCESS` -- which is not a DACL problem, since `NtOpenProcess`
granting that access is itself proof the security check already passed, and
`NtCreateThreadEx` failed anyway with the same already-granted handle. So
this was not going to settle the clone question either way, which running the
identical sequence against an ordinary `__spawn` child instead of a clone
confirmed: `STATUS_ACCESS_DENIED` there too. The conclusion drawn from that --
that cross-process thread creation is refused here as a matter of the caller's
privileges, `SeDebugPrivilege` not being enabled -- is wrong, and wrong in both
halves.

`SeDebugPrivilege` does not need `advapi32` to reach.
[`RtlAdjustPrivilege`](https://ntdoc.m417z.com/rtladjustprivilege) is an
`ntdll` export, and it takes the privilege as a plain `ULONG` LUID rather than
the `LUID_AND_ATTRIBUTES` that
[`LookupPrivilegeValue`](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-lookupprivilegevaluew)
exists to fill in, so the objection about it being out of reach of an
ntdll-only port was simply mistaken. The number is 20, which is what phnt's
`ntseapi.h` calls
[`SE_DEBUG_PRIVILEGE`](https://ntdoc.m417z.com/se_debug_privilege) -- and
rather than take that on faith,
`LookupPrivilegeValue("SeDebugPrivilege")` was asked on this machine and
answers 20 as well.

And the privilege was never missing. `RtlAdjustPrivilege(20, TRUE, FALSE,
&was)` from inside the probe returns `STATUS_SUCCESS` with `WasEnabled`
already 1: this token has had `SeDebugPrivilege` enabled the whole time, which
`whoami /priv` agrees with. So the denial had some other cause, and the
likeliest is a handle asked for too little rather than a caller granted too
little. A missing access right is indistinguishable from a missing privilege
from the outside -- both are `STATUS_ACCESS_DENIED` -- and this port walked
into that again while writing the probes below: `NtGetContextThread` on a
thread handle created without
[`THREAD_GET_CONTEXT`](https://learn.microsoft.com/en-us/windows/win32/procthread/thread-security-and-access-rights)
answers `STATUS_ACCESS_DENIED` and nothing else.

Written again and measured, cross-process thread creation is not refused here
at all. [`NtCreateThreadEx`](https://ntdoc.m417z.com/ntcreatethreadex) into an
ordinary `__spawn` child, with a `DesiredAccess` made of bits that are written
down -- `SYNCHRONIZE`, `THREAD_TERMINATE`, `THREAD_SUSPEND_RESUME`,
`THREAD_QUERY_INFORMATION` -- and `RtlExitUserProcess` as `StartRoutine` with
`0x5a5a` as its `Argument`, returns `STATUS_SUCCESS`, and the child exits with
`0x5a5a`. A fresh thread in another process runs, and runs ordinary code that
reaches the system. `THREAD_ALL_ACCESS` is deliberately not used for this: its
value is not written down anywhere authoritative, and those four bits are.

The same injection with `CreateFlags = THREAD_CREATE_FLAGS_SKIP_LOADER_INIT`
also returns `STATUS_SUCCESS`, and the child then dies of
`STATUS_ACCESS_VIOLATION` -- the `r15` finding above, reproduced across a
process boundary rather than within one.

Which finally makes the fresh-thread question above answerable, and the answer
is no. Clone with `CREATE_SUSPENDED`, never resume the clone's own thread at
all, and inject the same `RtlExitUserProcess` thread into the clone:
`NtCreateThreadEx` returns `STATUS_SUCCESS`. Two seconds later the clone has not
exited -- `NtWaitForSingleObject` times out, `ExitStatus` is still
`STATUS_PENDING` -- and
[`NtGetContextThread`](https://ntdoc.m417z.com/ntgetcontextthread) on the thread
just made reports `Eip` `RtlUserThreadStart`, `Cs` `0x23`, `SegFs` `0x53` and
`Esp` `0x8a7fff0`, the very top of its own fresh stack. That is its initial
context, unchanged: the thread has not executed one 32-bit instruction.

Zeroing the inherited loader lock first makes no difference to that, which
places whatever holds it up upstream of any 32-bit code at all -- in the native
bring-up, or in the kernel, not in the 32-bit loader. And the control says the
call itself is sound: the identical injection into an ordinary `__spawn` child
runs and exits with the value it was handed.

So a thread made the ordinary way in a clone does not get the segment setup the
cloned thread lacked, because it never gets as far as needing it. Not refused,
not faulting, not deadlocked in the 32-bit loader: it never starts. The clone
has a PEB32 and a process-level WOW64 association, and still no thread of any
provenance runs 32-bit code in it. Where in the 64-bit bring-up that stops is
what anyone picking this up would have to find next, and it cannot be found from
the 32-bit side -- the same wall the `r15` finding ends at.

Which was written as an open question, and is now answered -- in the negative,
and not for want of asking properly. **No flag makes an `NtCreateProcessEx`
clone take a thread.** Against a real 32-bit target, every
[`PROCESS_CREATE_FLAGS_`](https://github.com/winsiderss/phnt/blob/master/ntpsapi.h)
value that could mean anything to a clone was tried -- `NONE`,
`INHERIT_HANDLES` (`4`), `INHERIT_FROM_PARENT` (`0x100`), both together, and
`CREATE_SUSPENDED` (`0x200`) -- and all five clone successfully, each answering
[`NtQueryInformationProcess`](https://ntdoc.m417z.com/ntqueryinformationprocess)`(ProcessBasicInformation)`
with `ExitStatus` `STILL_ACTIVE`, so each is a live process by every measure
available from outside it. `CLONE_MINIMAL` (`0x2000`) is refused outright with
`STATUS_INVALID_PARAMETER`, so it is not a clone flag for this at all. Into
every one of the five, `NtCreateThreadEx` answers
`STATUS_PROCESS_IS_TERMINATING` -- with `CreateFlags` `0` and with
`CREATE_SUSPENDED` alike, from a 32-bit caller and from a 64-bit one: the same
`0xc000010a` in all ten attempts.

Published research says why, and says it is deliberate: the kernel marks a
threadless clone as awaiting deletion, so thread creation is refused the way it
would be for a process already on its way out -- and has been since Windows 8.1,
before which such clones *could* be given threads
([Hunt & Hackett, "The Definitive Guide To Process Cloning on
Windows"](https://www.huntandhackett.com/blog/the-definitive-guide-to-process-cloning-on-windows)).
So this is not a gap in what this port knows about the call. It is the call not
being for this.

Which closes the loose end left above, and closes it the other way from the way
it was hoped. **The clone this machine demonstrably *can* make is the same clone
that cannot run.**
[`PssCaptureSnapshot`](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/nf-processsnapshot-psscapturesnapshot)
with
[`PSS_CAPTURE_VA_CLONE`](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/ne-processsnapshot-pss_capture_flags)
against that same 32-bit target returns `ERROR_SUCCESS`;
[`PssQuerySnapshot`](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/api/processsnapshot/nf-processsnapshot-pssquerysnapshot)`(`[`PSS_QUERY_VA_CLONE_INFORMATION`](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/ne-processsnapshot-pss_query_information_class)`)`
hands back a live clone handle whose `ExitStatus` is `STILL_ACTIVE` too; and
`NtCreateThreadEx` into it answers `STATUS_PROCESS_IS_TERMINATING`, the
identical `0xc000010a`, for `CreateFlags` `0` and for `CREATE_SUSPENDED`.

So "something here can clone; whether the thing `__clone_process` calls is that
something remains unknown" was the right caution attached to the wrong hope. The
documented API is a wrapper over the very call already known to make unrunnable
clones, and being documented does not make its clone runnable. Nothing in the
box runs code in a VA clone, and the reason is not that nobody wrote the code
to: the kernel will not have it.

That is both roads shut for `NtCreateProcessEx`. The other road --
`RtlCloneUserProcess`, through `ZwCreateUserProcess` -- turns out not to be shut
at all. **It is shut under WOW64, and only there.**

The same script, run twice within a minute on this machine, differing in nothing
but which PowerShell ran it, cloning itself with
`CREATE_SUSPENDED|NO_SYNCHRONIZE` so the inherited lock cannot be the story,
reading the new thread's context before it runs and its exit status after:

| caller | initial context | on resume |
| --- | --- | --- |
| 32-bit | `Eip` `ZwCreateUserProcess+0xc`, `Cs` `0x23`, `Fs` `0x53` | dies, exit status `0xc0000409` |
| 64-bit | `Rip` `ZwCreateUserProcess+0x14`, `Cs` `0x33` | **runs** |

Runs, and not a little. The 64-bit clone comes back from the call, compares the
returned status against `STATUS_PROCESS_CLONED`, takes that branch, calls out
through `kernel32` into the kernel, finds that call failed, and exits with the
value its own code picks for a failed call rather than the one it picks for a
successful one. Choosing correctly between two exit codes is the proof: that is
a comparison, a call, a system call and a return, all after the clone.

Both entry points are the return from the same system call -- number `0xcf`
either way. `ZwCreateUserProcess+0xc` is the `ret 0x2c` after `call edx` in the
32-bit stub; `ZwCreateUserProcess+0x14` is the `ret` after `syscall` in the
64-bit one. Same call, same kernel, same minute; one clone runs and the other
cannot.

Which finally puts a name on the `fs:0x18` fault, and it is not this port's name
and not this machine's. A 64-bit thread reaches its TEB through `GS`, whose base
is a model-specific register the kernel reloads on every switch to the thread,
out of the thread object itself -- nothing per-process to arrange, so nothing
for a clone to lose. A 32-bit thread on the same machine reaches its TEB through
`FS`, whose base lives in a descriptor the kernel programs from that thread's
32-bit TEB, and that is the piece a cloned thread does not get. The defect is in
the WOW64 half of process cloning. The suggestion above that an x86_64 port
should ask this question again now rests on a measurement instead of on hope.

So for a 32-bit program on a 64-bit Windows, the `NtCreateProcessEx` clone is
refused a thread as a matter of kernel policy, and nothing a caller does
changes that. The `ZwCreateUserProcess` clone, the one `RtlCloneUserProcess`
makes, is given a thread with no `FS` base, and that one a caller can reach
past. `wow64cpu!RunSimulatedCode`, the loop that runs 32-bit code, does not
take `r13` and `r15` as arguments: it loads them itself, from the thread's own
TEB and CPU area, on every entry. So the cloned thread can be started at its
exported entry, `BTCpuSimulate`, from user mode, with a native
`NtSetContextThread` called through a 32-to-64-to-32 trampoline (the
WOW64-thunked one reaches only the 32-bit CPU-area `CONTEXT`), and with the
ordinary `NtSetContextThread` setting `Eax` to `STATUS_PROCESS_CLONED`. That
alone deadlocks on a second lock: `RtlCloneUserProcess` holds an internal
`ntdll` lock across the clone system call, and the branch its child takes never
releases it. Zeroing that lock's four bytes in the child before resuming it is
the rest. With both, the clone was measured running ordinary 32-bit code and
returning `STATUS_PROCESS_CLONED`. That is `__clone_process_wow64fix`, which is
`fork`; `__clone_process` beside it is the unfixed clone.

The `r15` finding does not depend on any of this. It was measured with no clone
anywhere near it, and it is why `SKIP_LOADER_INIT` is no way to a 32-bit fork.
A native x86_64 program has no WOW64 layer (`syscall` for system calls, and its
TEB through `GS`, whose base the kernel programs for every thread), so an
x86_64 port would have to ask the whole question again from scratch.
