# Real-Time

ZDOS is real-time on the metal and BIOS editions: the highest-priority ready task runs within a bounded delay after its timer or device interrupt, whatever lower-priority tasks do.

The UEFI editions are cooperative, not real-time: without `ExitBootServices` the firmware owns the timer, the interrupts and the drivers, and its disk and network calls run to their end. On UEFI machines the real-time ZDOS is the metal edition, which leaves the firmware and drives the hardware itself.

## Measured

Metal x86-64 on a real PC, RTLAT's (1 ms wake-ups, FIFO, priority 28, a thread per core) alone and under disk copies, DEMO graphics, HTTP over the loopback and all at once: two runs (6 and 14 threads) of five 10-minute phases, 60 million wake-ups ([rt-tests](rt-tests/)).

- Average: 34 µs late.
- Worst: 793 µs; no period missed.

How to measure: `ASH C:\SCRIPTS\realtime.sh [THREADS] [SECONDS] [PRIORITY] [FOLDER]` (defaults: `2 60 28` and its JSON in `C:\RTLAT`). In QEMU: `tests/rte/rt-tests.py`.

## How it works

- **Scheduling:** fixed priorities 0-31, FIFO and RR; earliest deadline first above every priority (a task out of its runtime waits for its next period; admission up to 95% of the cores). Affinity and isolated cores (`ISOLCPUS=`), which get no device interrupts and timer interrupts only for their own tasks. A task becoming ready wakes an idle core, else preempts the lowest priority below it. Nothing is paged to disk.
- **Preemptible kernel:** the timer or an interrupt switches tasks anywhere, in ZDOS's own code too, outside spinlock and interrupts-off sections. Each task has its own kernel state. Time, waits, mutexes, futexes, semaphores, signal masks, timers and `memory->alloc` don't take the kernel lock. File systems and disks have a lock of their own, so a task waiting for its disk doesn't hold up the console, the network or graphics. Lock holders inherit their waiters' priority.
- **Timers:** tickless one-shot deadlines in nanoseconds (the local APIC, TSC-deadline mode where the CPU has it, on x86; the generic timer on ARM64), armed after every switch for the earliest deadline, a time slice's end, and on core 0 every 1 ms for the network.
- **Threaded interrupts:** a handler acknowledges its device and leaves the rest to the task IRQ (FIFO, `IRQPRIO=`, default 30). The network runs on a core of its own (the last, or `NETCPU=`'s), or as the task NET with `NETCORE=false` (`NETPRIO=`, default 20; pinned with `NETCPU=`).
- **Memory:** `RTHEAP=16M` takes a pool at startup from which programs' memory comes first, in constant time.
- **Drivers:** every wait for NVMe, AHCI, xHCI, e1000 and IDE has a timeout; completion and receive loops are bounded by their rings. File systems, sound and the framebuffer run preemptible.
- **Interrupts-off sections** are short and bounded: the scheduler (64 task slots, priority inheritance at most 64 deep), event queues, the real-time heap, the page allocator, device handlers; on BIOS also BIOS calls, which take the BIOS's own time.

## The BIOS edition

Preemptive on every core where the BIOS left the local APIC on, with its one-shot timer (else the PIT's). IDE and SATA (AHCI) disks go through ZDOS's own drivers, not int 13h. BIOS calls remain for floppies, other disks and video modes: they run on core 0 in real mode with interrupts in the BIOS's hands, and are the edition's limit.

## Settings

`CORES=`, `ISOLCPUS=`, `RTHEAP=`, `IRQPRIO=`, `NETCORE=`, `NETCPU=`, `NETPRIO=`, `NETPOLLED=` in `SYSTEM.CFG`; RTPRIO (FIFO, RR, deadline) and CPUSET from the shell; on BIOS `own_ide`, `own_sata`, `lapic_timer` and `tasks_on_all_cores` in `platform/bios/config.zig`.

## Open

- BIOS: the local APIC timer's calibration fix is not yet measured.
- A lock per file system or volume (they share static caches and metal's bounce buffer); the console, the loader and the network's calls apart from the kernel lock.
