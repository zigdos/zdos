# Network

TCP/IP over IPv4, with lwIP 2.0.2 in the kernel (`src/net`), on one network card or several (routing and bridging between them: below). The cards:

- **Metal**: ZDOS's own drivers for Intel e1000 (8254x) and e1000e (82574), virtio-net and Amazon ENA (untested, polled), interrupt-driven where the card has MSI or MSI-X (QEMU's e1000 hasn't and is polled); Realtek cards through drivers (interrupts where ZDOS connects them, else polled): `RTL8139.SYS` and `RTL8169.SYS` (RTL8168/8111 G to FP, RTL8125A/B), see [API](API.md#drivers-sys). Up to eight cards.
- **BIOS**: the e1000 / e1000e and Realtek drivers as on metal, with interrupts on the card's PCI line.
- **Metal and BIOS, two or more cores**: the network runs on a core of its own, the last one or `NETCPU=`'s, which tasks don't get; the tasks' calls only copy their data in and out, so programs don't feel network traffic. `NETCORE=false` runs it as a task instead (below).
- **UEFI**: the firmware's Simple Network Protocol, so any card the firmware has a driver for (often only with "Network Stack" or PXE on in the firmware setup); polled every 2 ms; one card only.
- **The loopback**: `127.0.0.1` (`localhost`) and the machine's own addresses reach its own programs. `NETWORK=true` without a card starts the loopback alone; without `NETWORK=true` there is no network, not even 127.0.0.1.

## Settings

In `\CONF\SYSTEM.CFG`, read once at boot:

```ini
[Network]
NETWORK=true
IPV4=DHCP
# IPV4=192.168.1.50
# NETMASK=255.255.255.0
# ROUTER=192.168.1.1
# DNS=1.1.1.1,8.8.8.8
```

`IPV4=DHCP` or no `IPV4=`: the address comes from DHCP.

`NETCORE=true` (or none; metal, BIOS, two or more cores): the network gets a core of its own. `NETCORE=false`, a single core or UEFI: it runs as the task NET instead, at priority `NETPRIO=` (0-31, default 20). `NETCPU=N` picks the core in both cases: the network's own (1 and up; the last without it) or the one the task NET is pinned to (0 and up, a core that runs tasks; any without it).

`NETPOLLED=true`: the cards are polled every 2 ms instead of interrupting, on every edition (default `false`: interrupts where card and platform have them; UEFI's cards are always polled).

`DNS=` names up to 8 DNS servers, separated by commas; they replace DHCP's. `\CONF\HOSTS.CFG` (`ADDRESS NAME [ALIASES]` per line, `#` comments) is looked up before DNS; it is read at startup (the first 8 KiB).

### Several cards

Cards are numbered from 0: `NET0=` is the first card, `NET1=` the second, and every other setting that names a card (`BRIDGE=`, `NAT=`, and `DHCPD.CFG`'s and `DNSD.CFG`'s, below) and what IPCONFIG and NETSTAT show count the same way. Every card ZDOS drives gets a number, 0 to 7: the drivers' cards first (in the order they were loaded), then the built-in ones. Card 0 takes the settings above; card *n* takes `NETn=` and is left unused without it (startup says so, and also of a `NETn=` past the last card). `NET0=` may stand for `IPV4=` and the rest. A `NETn=` value is words in any order:

- `DHCP`, or an address with its network: `192.168.50.1/24` (or `/255.255.255.0`; a bare address is a `/24`), then the router of that network if it has one;
- the card's MAC (`52-54-00-12-34-56` or with `:`): that card becomes number *n*, whatever its place (the rest keep their order);
- `OFF`: the card isn't used.

```ini
NET0=DHCP
NET1=192.168.50.1/24
NET2=10.9.0.2/16 10.9.0.1 00-1B-21-0A-0B-0C
```

The default route goes through the first interface that has a router (`ROUTER=`, a `NETn=` router, or DHCP's). `DNS=` is for all of them; with DHCP on several, the last one's DNS servers count.

### Routing

`ROUTING=true` forwards IPv4 packets between the interfaces. `ROUTE=` adds routes: a network and the router there, separated by commas; the longest match wins, after the interfaces' own networks. Routes work without `ROUTING=` too, for ZDOS's own packets. A packet with no route is dropped without an ICMP answer.

A router between the network of a DSL box (DHCP) and a network of its own:

```ini
[Network]
NETWORK=true
NET0=DHCP
NET1=192.168.50.1/24
ROUTING=true
ROUTE=10.1.0.0/16 192.168.50.2, 10.2.0.0/16 192.168.50.3
```

The machines on 192.168.50.0/24 take 192.168.50.1 as their router. Without NAT the DSL box must know a route back to 192.168.50.0/24 (via ZDOS's address on its network), else answers from the internet don't find their way; with `NAT=0` (below) it needn't.

### Bridging

`BRIDGE=0,1` joins those cards into one Ethernet segment. The bridge is one interface with the settings of the first card listed (`NET0=` here) and that card's MAC; the others' `NETn=` aren't read. There is no spanning tree: two bridge ports on the same segment make a loop.

```ini
[Network]
NETWORK=true
NET0=192.168.60.1/24 192.168.60.254
BRIDGE=0,1
```

A port must take every frame on its wire: ZDOS's own e1000 and virtio-net cards (not ENA) and UEFI's card (where the firmware can) do; a driver's card hears only its own MAC and broadcasts (startup says so).

### NAT

`NAT=0` masquerades behind card 0 (several: `NAT=0,2`): packets forwarded out of it take its address and a port of ZDOS's (32768 to 49151; ICMP echo: an identifier), and the answers go back to the machine that sent them. `NAT=` turns forwarding on unless `ROUTING=false`. TCP, UDP and ping are mapped, with their ICMP errors; other protocols only get the address. The table holds 1024 connections; idle ones expire. The router's own programs (SSHD, HTTPZ ...) keep their ports on that address.

`FORWARD=` sends ports of the NAT card's address to inside machines: `tcp|udp PORT ADDRESS[:PORT]`, separated by commas, up to 16. It is not a firewall: outside machines that know a route to the inside network still reach it directly.

```ini
[Network]
NETWORK=true
NET0=DHCP
NET1=192.168.50.1/24
NAT=0
FORWARD=tcp 8080 192.168.50.5:80, udp 27015 192.168.50.6
```

With the DHCP and DNS servers below for the machines on card 1 (`DHCPD=true` and `DNSD=true` in `\CONF\SERVICES.CFG`, `RANGE=1 192.168.50.100-192.168.50.199` in `\CONF\DHCPD.CFG`).

NAT on a bridge works on the whole bridge (`NAT=` names its first card). Fragments sent to a NAT address are put together first, then forwarded.

### DHCP server

`DHCPD` (`apps/dhcpd.zig`) is a service: `DHCPD=true` in `\CONF\SERVICES.CFG` starts it at boot. It hands out addresses on the networks of cards with a fixed address (not DHCP); the machines get the network's mask, the card's address as their router, and a DNS server. Its settings are in `\CONF\DHCPD.CFG` (a commented sample comes with ZDOS):

```ini
# Addresses for card 1's machines (cards numbered from 0, as NETn=), leases of 1440 minutes (the default)
RANGE=1 192.168.50.100-192.168.50.199 1440
# The DNS server they get: ROUTER (the card's address) or up to 4 addresses
# DNS=ROUTER
# A machine's own address: MAC ADDRESS (- or :), inside or outside a range
52-54-00-12-34-56 192.168.50.7
```

Up to 32 `RANGE=` lines and 256 fixed hosts. Without `DNS=` the machines get the card's address if `DNSD` runs here, else ZDOS's own DNS servers. `LOG=` names its log, as `C:\DATA\LOGS\dhcpd.log` (none without it).

The file is reread when it changes (it is looked at every 2 seconds), on SIGHUP, or with `DHCPD -reload`; `DHCPD -stop` (or `KILL`, SIGTERM) ends it, closing its port. Up to 1024 leases, in memory, kept across rereads.

### DNS server

`DNSD` (`apps/dnsd.zig`) is a service: `DNSD=true` in `\CONF\SERVICES.CFG`. It answers the DNS queries of the machines on its cards' networks: names in `\CONF\HOSTS.CFG` itself (A and PTR records), others asked of the DNS servers. UDP only, up to 64 queries under way. Its settings are in `\CONF\DNSD.CFG`:

```ini
# The cards whose machines it answers: true (all but NAT='s outside cards) or numbers: CARDS=1,2
CARDS=true
# The DNS servers asked (up to 8); left out: ZDOS's own (DNS=, or DHCP's)
# SERVERS=1.1.1.1, 8.8.8.8
# Answers kept (0: none); the TTL of HOSTS.CFG's answers
CACHE=128
TTL=60
```

`LOG=` names its log, as `C:\DATA\LOGS\dnsd.log` (none without it). `DNSD.CFG` and `HOSTS.CFG` are reread when they change (looked at every 2 seconds), on SIGHUP, or with `DNSD -reload` (the cache stays, unless its size changes); `DNSD -stop` ends it.

Answers are cached for their TTL, at most a day (negative ones at most 3 hours).

## Tools

- `IPCONFIG [-RENEW | -RELEASE]`: each interface's card (or bridge), address, mask, router, DHCP lease, whether its interrupts arrive; the DNS servers, whether the network has its own core and routes.
- `PING [-n COUNT] [-t] [-l SIZE] [-w TIMEOUT] HOST`
- `NSLOOKUP NAME`
- `NETSTAT [-i | -r]`: the TCP connections and listeners, the UDP sockets; `-i` the interfaces (address, frames), `-r` the routes.
- `ARP [-a]`, `ARP -s ADDRESS MAC`, `ARP -d ADDRESS | *` (`-s`, `-d`: admins).
- `FETCH [-o FILE] [-k] URL`: an HTTP or HTTPS GET, redirects followed. HTTPS is TLS 1.2 / 1.3, checking the server's certificate against `\CONF\CACERT.PEM` (`-k` doesn't check); the clock must be about right.

[SSH](SSH.md): `SSH`, `SCP`, `SSHKEY` and the server `SSHD`. [HTTPZ](HTTPZ.md): the web server.

Tests: `tests/net/net-tests.py`, `route-tests.py` and `nat-tests.py` in QEMU; `netspeed.py` measures (`NETSPEED_PCAP=1`: the card's frames into a capture).

## Programs

Sockets are handles (`read`, `write`, `poll`, `dup`, `close`): group `net` and `apps/zdos/net.zig` ([API](API.md#network-netzig)); C programs use `sys/socket.h` and `netdb.h`. In QEMU (`-netdev user`) the host is 10.0.2.2 and the DNS server 10.0.2.3; the run scripts attach a card.

QEMU's user network opens a host socket for a program's first UDP datagram to a new peer, but reads it only at its next wake-up: after TCP traffic up to ~500 ms later. Until then the host's answers wait in that socket, and at high rates the rest are dropped (seen as ~5% loss in NETSPEED's UDP test, before any of it reached the card). NETSPEED sends one datagram first and waits; a tap network or real hardware doesn't go through the user network.
