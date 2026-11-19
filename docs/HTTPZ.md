# HTTPZ

The web server (`apps/httpz.zig`, `apps/httpz/`): files by HTTP/1.1 and HTTPS, scripts and programs by CGI. It needs the [network](NETWORK.md) and tasks (worker threads serve the connections). It is a service: in `\CONF\SERVICES.CFG`, `HTTPZ=true` starts it at boot.

## Settings

`\CONF\HTTPZ.CFG`; lines left out keep these defaults (comments go on lines of their own; the `CGI` interpreters are the shipped file's, none by default):

```ini
PORT=80
HTTPS_PORT=443                 # 0: no HTTPS
HTTPS_REDIRECT=false           # true: http:// answers 301 to the https:// address
CERT=C:/USERS/HTTPZ/httpz.crt
KEY=C:/USERS/HTTPZ/httpz.key
SERVER_ROOT=C:/USERS/HTTPZ/www
CGI_DIR=functions              # under SERVER_ROOT; empty: no CGI
INDEX=index.html index.htm
CGI lua=C:/APPS/lua.app        # interpreters by extension, up to 16
CGI py=C:/APPS/micropython.app
CGI_TIMEOUT=10                 # seconds a script may take
MAX_FILE_SIZE=25MB             # the largest download (larger: 403)
MAX_BODY=1MB                   # the largest upload (a POST to a script; larger: 413)
MAX_CLIENTS=32                 # connections at once (more: 503)
WORKERS=                       # threads serving requests; empty: one per core (2-16)
DIRLIST=false                  # list folders that have no index file
USER=HTTPZ
LOG=                           # the log, as C:/DATA/LOGS/httpz.log; empty: none
```

## Starting

HTTPZ starts as root, as services do. On its first start it makes the user `USER` (without a password: it can't log in), its home folder with `www` and `www/functions` in it (a sample page and `hello.lua`), and a self-signed certificate and key if either is missing. It opens the log, reads the key, opens its ports, and then runs as that user: it serves what that user may read, and so do its scripts.

## Workers

A thread per port accepts connections; a request goes to one of `WORKERS` threads, so idle and slow clients hold no worker. A worker is held while it reads a body, sends a reply, runs a script or does a TLS handshake. A client that stops reading for 30 s is dropped. `KILL` (TERM), INT, HUP or Ctrl+C stop it after the replies being sent (5 s at most).

## Files

- `GET` and `HEAD`; keep-alive (up to 100 requests per connection, 15 s between them); `Last-Modified` and `If-Modified-Since` (304); one `Range` span (206, for resumed downloads and video).
- The type comes from the file's extension alone: pages, text, pictures, sound, video, fonts, archives; unknown ones (`exe`, `app`, `bin`, `img` ...) are `application/octet-stream`, which browsers download.
- A folder's address without its `/` is sent there (301); then its index file, its listing (`DIRLIST=true`) or 403.
- Refused (400): `..`, names starting with a dot, backslashes, drive letters, control characters. Headers are limited to 8 KB (431), and must arrive within 20 s.

## HTTPS

TLS 1.3 only (ZCRYPT.ZDL's server, `libs/zcrypt/server.zig`): key exchange by X25519 or P-256, AES-128-GCM or ChaCha20-Poly1305, ALPN `http/1.1`; no session tickets, early data or client certificates.

The certificate is a PEM file: the server's certificate, then its chain. The key is ECDSA P-256, as `EC PRIVATE KEY` or PKCS#8 `PRIVATE KEY` (what `openssl genpkey` and certbot's ECDSA keys are); RSA keys aren't supported yet. The self-signed one made at the first start (`CN=zdos`, for `localhost` and `zdos`, 10 years) makes browsers warn; replace both files with your own.

## CGI

In `CGI_DIR`, an address names a script without its extension: `/functions/hello?x=1` runs `hello.lua` (through `CGI lua=`), `hello.py`, or the program `hello.app`. What follows the name is `PATH_INFO` (`/functions/hello/a/b`). Scripts and programs there are never sent as files; other files there are. On Minix and ext2 a program needs execute permission for `USER` (`chmod 755`), a script read permission; one that can't be started answers 500 with the reason.

The script gets the CGI variables (`REQUEST_METHOD`, `QUERY_STRING`, `PATH_INFO`, `SCRIPT_NAME`, `CONTENT_TYPE`, `CONTENT_LENGTH`, `REMOTE_ADDR`, `HTTPS`, `HTTP_*` for the headers ...), the request body as its input, and its folder as the current one. Its output is the reply: headers (`Content-Type`, `Status: 404 Not Found`, `Location` for a redirect ...), an empty line, the body. Without a `Content-Length` the body goes in chunks. A script that takes longer than `CGI_TIMEOUT` is stopped (504).

Limits: a ZDOS variable holds 512 bytes, so a longer query string is cut (use POST); on the UEFI edition tasks are cooperative, and a script stuck in a loop that never calls ZDOS can't be stopped there.

## Tests

`tests/net/httpz-tests.py [EDITION...]` in QEMU (`HTTPTEST SETUP` on the ZDOS side).
