# Drivers

The hardware ZDOS drives itself, on the metal editions (x86-64, ARM64) and the BIOS edition. The UEFI editions use the firmware's drivers instead. A driver is either built into the kernel or a `.SYS` file in `\SYSTEM\DRIVERS`, loaded at startup for the PCI devices it names ([SYS.md](SYS.md), [API](API.md#drivers-sys)). Interrupts means MSI-X or MSI on metal, the device's PCI line on BIOS. Polled drivers are asked by ZDOS at short intervals.

**Disks**  
[ATA](#ata)  
[AHCI](#ahci)  
[NVMe](#nvme)  
[virtio-blk](#virtio-blk)  

**USB**  
[xHCI](#xhci)  
[USB keyboard](#usb-keyboard)  
[USB mouse](#usb-mouse)  
[USB mass storage](#usb-mass-storage)  

**PS/2**  
[PS/2 keyboard](#ps2-keyboard)  
[PS/2 mouse](#ps2-mouse)  

**NICs**  
[e1000 / e1000e](#e1000--e1000e)  
[RTL8139.SYS](#rtl8139sys)  
[RTL8169.SYS](#rtl8169sys)  
[virtio-net](#virtio-net)  
[Amazon ENA](#amazon-ena)  

**Audio**  
[HDA.SYS](#hdasys)  
[AC97.SYS](#ac97sys)  
[SB16.SYS](#sb16sys)  
[PC speaker](#pc-speaker)  

## Disks

On the BIOS edition every disk the BIOS sees also works through int 13h (floppies, USB sticks through the BIOS's emulation); the drivers below take over the disks they find, without real mode.

### ATA

ATA hard disks on the legacy IDE ports (primary and secondary channel), built into the kernel, BIOS edition only. LBA28 and LBA48, bus-master DMA where controller and drive have it, else PIO. Interrupt-driven (IRQ 14 and 15). ATAPI drives and SATA disks are left to other drivers.

### AHCI

SATA controllers in AHCI mode, built into the kernel. On metal: several ports, NCQ and ATAPI optical drives, with interrupts once tasks run. On BIOS: only the SATA disks the BIOS also reports, polled while a transfer runs (nothing between them); the firmware keeps the other ports.

### NVMe

NVMe SSDs, built into the kernel, metal editions only. Several namespaces and I/O queues, with interrupts once tasks run.

### virtio-blk

The disks of virtual machines (QEMU, KVM, cloud VMs), built into the kernel, metal editions only. virtio 1.x ("modern"); devices with only the legacy interface aren't driven. Interrupts once tasks run.

## USB

USB works on the metal editions only, through xHCI controllers; the BIOS edition has the BIOS's emulation of USB keyboards and disks. Devices may be plugged in and pulled out while ZDOS runs.

### xHCI

USB 3 host controllers (they also drive USB 1 and 2 devices), and hubs on them, built into the kernel. Polled during startup, until tasks run; interrupt-driven from then on. Older controllers (UHCI, OHCI, EHCI) aren't driven.

### USB keyboard

HID keyboards in the boot protocol, with their LEDs, built into the kernel; the layout is ZDOS's (`KEYB`).

### USB mouse

HID mice with up to 5 buttons and a wheel, read through their report descriptor, built into the kernel; mice whose descriptor can't be read fall back to the boot protocol (usually without the wheel).

### USB mass storage

USB sticks, card readers and disks speaking Bulk-Only Transport (SCSI commands), built into the kernel. A disk pulled out keeps its entry, for when it comes back.

## PS/2

### PS/2 keyboard

The keyboard on the 8042 controller, built into the kernel, BIOS edition and metal on x86-64 PCs. BIOS: interrupt-driven (IRQ 1) while a program waits for keys, otherwise read when a program asks; metal: polled at 1 ms while a program waits for keys, otherwise when a program asks.

### PS/2 mouse

The mouse on the 8042's second port, with a wheel where the mouse has one, built into the kernel, BIOS edition and metal on x86-64. BIOS: interrupt-driven (IRQ 12) while a program waits for keys, otherwise read when a program asks; metal: polled when a program asks for the mouse (and at each look for keys).

## NICs

The network runs on a CPU core of its own where there are several ([NETWORK.md](NETWORK.md)); interrupts are sent to that core (on BIOS, core 0 takes them and wakes it). `NETPOLLED=true` polls every card instead. In QEMU's user network the first UDP datagrams to a new socket can come late or be lost: not the drivers ([NETWORK.md](NETWORK.md#programs)).

### e1000 / e1000e

Intel's 8254x gigabit cards (82540, 82541, 82543, 82544, 82545, 82546, 82547) and the 82574 (e1000e), built into the kernel, metal and BIOS editions. Metal: interrupts where the card has MSI-X or MSI (the 82574 does; the older PCI cards mostly don't, and are polled at 2 ms); BIOS: interrupts.

### RTL8139.SYS

Realtek RTL8139 and RTL8129, 10/100 Mbit/s, and their clones (D-Link, SMC, Accton, Allied Telesyn, Planex, Edimax and others), a `.SYS` driver for metal and BIOS. Metal: polled at 2 ms (the card has no MSI, and metal has no wired interrupts yet); BIOS: interrupts.

### RTL8169.SYS

Realtek's gigabit and 2.5 gigabit PCIe cards: RTL8168 / 8111 (most onboard LAN), 8411B and 8125A / B, set up after Realtek's FreeBSD driver; other members of the family are recognized but left alone. A `.SYS` driver for metal and BIOS. Metal: interrupts (MSI-X or MSI), polled at 2 ms if they can't be connected; BIOS: interrupts, likewise. Run on a real RTL8111/8168 card, polled; its interrupts not yet tried there.

### virtio-net

The network card of virtual machines (QEMU, KVM, cloud VMs), built into the kernel, metal editions only. virtio 1.x ("modern") only. Interrupts (MSI-X).

### Amazon ENA

The Elastic Network Adapter of AWS's Nitro instances (x86-64 and Graviton), built into the kernel, metal editions only. One receive and one transmit queue, polled at 2 ms. Not yet run on AWS.

## Audio

Programs play 16-bit stereo; ZDOS converts and resamples what they give. One card is used, the first a driver registers.

### HDA.SYS

High Definition Audio controllers (any vendor), a `.SYS` driver for metal and BIOS. Plays on every connected output pin of the first codec (line out, speakers, headphones). Polled at 10 ms while something plays, not at all otherwise.

### AC97.SYS

AC'97 on Intel's ICH chipsets (82801AA up to ICH7, 440MX) and compatibles from NVIDIA (nForce, CK804, MCP) and AMD (8111, 768), a `.SYS` driver for x86 only. 48000 Hz, other rates where the codec has variable rate audio. Polled at 10 ms while something plays, like HDA.

### SB16.SYS

The ISA Sound Blaster 16 at port 0x220 or 0x240, a `.SYS` driver for the BIOS edition only (it looks for the card itself). 16-bit stereo by DMA, 5000 to 44100 Hz. Polled at 10 ms while something plays, like HDA.

### PC speaker

The PC's speaker, built into the kernel, the x86 editions (BIOS, UEFI, metal): tones and beeps (PIT channel 2), for programs without a sound card.
