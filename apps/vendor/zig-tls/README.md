Zig 0.14.1's TLS client (std/crypto/tls/Client.zig, MIT: LICENSE; docs/COPYING/ZIG.TXT), for
FETCH's HTTPS and IRCZ. Changed for freestanding programs: the time for checking
certificates is the option `now_sec` (std.time.timestamp needs an OS clock),
the key log file is gone (it needs an OS file system), and TLS 1.2 offers
the ECDHE-ECDSA suites too (std's only RSA ones: no TLS 1.2 with ECDSA
certificates), and TLS 1.2's ClientKeyExchange carries the public key of the
group the server picked (std always sent secp256r1's: servers that pick
x25519, as OpenSSL does, refused it). A server's request for a client
certificate (IRC servers ask, for CertFP) gets an empty one, which says there
is none (std ended the handshake with TlsUnexpectedMessage).
