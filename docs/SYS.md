# Drivers

Each `.zig` file in `sys/` when building ZDOS becomes `NAME.SYS` in `\SYSTEM\DRIVERS` (`sdk/linkers/sys-*.ld`), loaded at startup on the metal and BIOS editions for the PCI devices its `zdos_driver_ids` names (`drv.any_vendor`: a PCI class; `drv.probe_vendor`: no PCI device, ISA cards on BIOS). A driver imports the driver interface as module `drv` (`src/kernel/drv.zig`) and exports:

```zig
export const zdos_driver_ids = [_]drv.PciId{ .{ .vendor = 0x10EC, .device = 0x8139 }, .{ .vendor = 0, .device = 0 } };

export fn zdos_driver_init(api: *const drv.Api, dev: *const drv.Device) callconv(drv.cc) bool {
    // map the registers (api.map_device), set the device up, api.register_net(&card)
}
```

A network card stays polled unless the driver also calls `api.net_interrupts(&card, dev, &control)`: ZDOS then connects the card's interrupt when the network starts and asks `control` to enable, acknowledge (clear and mask the card's causes, in the interrupt) and rearm (unmask once the frames are taken). For a bridge, a driver gives `api.net_promiscuous(&card, &on)`: ZDOS calls `on` when the card becomes a bridge port, and the card takes every frame from then on. Check `api.slots` first, so the driver still loads on an older ZDOS.

Every `sys/*.zig` becomes a driver, so files a driver imports go in a folder of its own (`sys/rtl8169/phy.zig`).

See [API](API.md#drivers-sys).
