# zdos:sqlite and zdos:net

Two of the modules ZDOS adds to QuickJS (`qjs.app`). The third, the web framework `zdos:web`, is described in [ZDOSWEB.md](ZDOSWEB.md).

- [zdos:sqlite](#zdossqlite): SQLite databases, in the manner of Node's better-sqlite3.
- [zdos:net](#zdosnet): TCP server sockets and TLS, the layer under `zdos:web`.

# zdos:sqlite

`zdos:sqlite` gives JavaScript the SQLite database engine (the SQLite port's `C:\LIBS\SQLITE.ZDL`). Its calls return their results directly: there are no callbacks or promises, because SQLite works on a local file and answers quickly. This is the way Node's better-sqlite3 works, and its API is followed here.

```js
import { Database } from "zdos:sqlite";
// or: import Database from "zdos:sqlite";

const db = new Database("C:/DATA/NOTES.DB");
db.exec("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, text TEXT, created TEXT)");

const add = db.prepare("INSERT INTO notes (text, created) VALUES (?, datetime('now'))");
add.run("buy milk");
add.run("call Anna");

for (const note of db.prepare("SELECT * FROM notes ORDER BY id").all()) {
  console.log(note.id, note.text, note.created);
}
db.close();
```

## Opening a database

```js
const db = new Database(path, [options]);
```

`path` is the database file, in any of ZDOS's spellings (`C:/DATA/SHOP.DB`, `C:\\DATA\\SHOP.DB` in a JavaScript string, or relative to the current folder). The file is made if it doesn't exist. `":memory:"` opens a database that lives only in memory and disappears when it is closed.

- `readonly` (default: `false`): opens the file for reading only; it must exist.

Opening fails with an `Error` when the file can't be opened (a folder that doesn't exist, a file that isn't a database ...).

When the database is busy (locked by another connection of the same program), SQLite waits up to 5 seconds before giving up with `database is locked`.

## The database

- `db.exec(sql)`: runs one or more SQL statements separated by `;`, without results: creating tables, several inserts at once, `PRAGMA` settings. Returns `db`.
- `db.prepare(sql)`: compiles one SQL statement and returns a [statement](#statements) that can be run many times.
- `db.transaction(fn)`: returns a function that runs `fn` in a transaction, see [Transactions](#transactions).
- `db.close()`: closes the database. Statements still in use keep it open until they are finalized or collected, but can't be run anymore.
- `db.open`: `true` until `db.close()`.
- `db.inTransaction`: `true` while a transaction is open.
- `db.name`: the path it was opened with.

`db.prepare()` takes exactly one statement: `db.prepare("SELECT 1; SELECT 2")` throws. Use `db.exec()` for several.

## Statements

A statement is SQL compiled once and run as often as needed, with different values each time. Preparing a statement once and keeping it is faster than preparing it for every use.

- `stmt.run(...values)`: returns `{ changes, lastInsertRowid }`, how many rows an `INSERT`, `UPDATE` or `DELETE` changed, and the rowid of the last row inserted. For statements that change things.
- `stmt.get(...values)`: the first row of the result as an object (`{ column: value, ... }`), or `undefined` when there is none.
- `stmt.all(...values)`: all rows of the result, as an array of objects (an empty array when there are none).
- `stmt.columns()`: the names of the result's columns, an array of strings.
- `stmt.finalize()`: frees the statement at once; it can't be run anymore. Statements that are no longer referenced are freed by the garbage collector anyway.

```js
const byName = db.prepare("SELECT id, name, qty FROM items WHERE name = ?");
const row = byName.get("apple");          // { id: 1, name: "apple", qty: 3 } or undefined
const all = db.prepare("SELECT * FROM items WHERE qty > ?").all(0);
const r = db.prepare("UPDATE items SET qty = qty - 1 WHERE id = ?").run(1);
console.log(r.changes);                   // 1
```

Rows are plain objects, keyed by the column names of the result (use `AS` to name computed columns: `SELECT count(*) AS n FROM items`).

## Values

### Giving values: parameters

SQL text never needs values pasted into it, which would open the door to SQL injection. Write placeholders instead and give the values to `run()`, `get()` or `all()`.

**In order.** `?` placeholders (or numbered `?1`, `?2`) take the values in the order given. Arrays given are spread, so these are the same:

```js
stmt.run("apple", 3);
stmt.run(["apple", 3]);
```

The number of values must match the number of placeholders, else the call throws a `RangeError`.

**By name.** `:name`, `@name` or `$name` placeholders take their values from one object, by the name without its sign:

```js
db.prepare("INSERT INTO items (name, qty) VALUES (:name, :qty)").run({ name: "pear", qty: 5 });
```

A missing property gives `NULL`. Named placeholders are numbered as well, so values in order work for them too (by their position in the SQL); an object for `?` placeholders throws, since they have no names.

### Types

- `null` and `undefined` are stored as `NULL`.
- A number without a fraction, up to ±2^53, is stored as an `INTEGER`; any other number as a `REAL`.
- A `BigInt` (within 64 bits) is stored as an `INTEGER`.
- `true` and `false` are stored as the `INTEGER`s 1 and 0.
- A string is stored as `TEXT` (UTF-8).
- An `ArrayBuffer`, `Uint8Array` or other typed array is stored as a `BLOB`.

Other values (objects, dates ...) throw a `TypeError`: give dates as text (`date.toISOString()`) or as numbers (`date.getTime()`), objects as JSON (`JSON.stringify(obj)`).

### Results

- `NULL` comes back as `null`.
- An `INTEGER` comes back as a number, or as a `BigInt` beyond ±2^53, where a number would lose digits.
- A `REAL` comes back as a number.
- `TEXT` comes back as a string.
- A `BLOB` comes back as a `Uint8Array`.

`lastInsertRowid` follows the same rule (a number, or a `BigInt` when very large).

## Transactions

A transaction makes several changes happen together or not at all. `db.transaction(fn)` returns a function: calling it runs `fn` (with the arguments given and the same `this`) between `BEGIN` and `COMMIT`. If `fn` throws, the transaction is rolled back with `ROLLBACK` and the exception goes on to the caller. The function returns what `fn` returns.

```js
const insert = db.prepare("INSERT INTO items (name, qty) VALUES (?, ?)");
const insertMany = db.transaction((rows) => {
  for (const r of rows) insert.run(r.name, r.qty);
  return rows.length;
});

insertMany([{ name: "a", qty: 1 }, { name: "b", qty: 2 }]);   // both, or neither
```

Transactions are also much faster for many changes: SQLite writes to the disk once at the end instead of once per statement.

A transaction function called inside another one uses a savepoint: if the inner one throws, only its own changes are undone, and the outer one decides about the rest.

`db.exec("BEGIN")` and `db.exec("COMMIT")` work too, for code that prefers them.

## Errors

Errors of SQLite are thrown as ordinary `Error`s with SQLite's message (`SQLite: UNIQUE constraint failed: items.name`), and can be caught:

```js
try {
  insert.run("apple", 1);
} catch (e) {
  console.log(e.message);   // SQLite: UNIQUE constraint failed: items.name
}
```

## Limits on ZDOS

These come from the SQLite port (`ports/databases/sqlite`):

- **One program at a time** on a database file: two programs don't see each other's locks. Within one program, any number of `Database` objects and statements work together.
- **No WAL journal** (`PRAGMA journal_mode = WAL`), since it needs shared memory; the default rollback journal is used.
- Temporary tables live in memory unless `PRAGMA temp_store = FILE`.
- Each program has its own copy of SQLite (`SQLITE.ZDL`), so `qjs.app` needs `C:\LIBS\SQLITE.ZDL` to start.

`import { version } from "zdos:sqlite"` gives SQLite's version (`"3.54.0"` ...).

# zdos:net

`zdos:net` is the network layer under `zdos:web`: TCP server sockets and TLS connections, made for QuickJS's own event loop. Most programs use `zdos:web` instead; this module is for servers of other protocols (a line-based chat, a custom binary protocol ...) or for building something like `zdos:web` yourself.

```js
import * as net from "zdos:net";
import * as os from "qjs:os";
```

## How it works: non-blocking calls and the event loop

None of the calls ever waits. A call that would have to wait (no connection yet, no data yet, the network's buffer full) returns at once and says so. The program then asks QuickJS's event loop to call it back when the socket is ready, with `os.setReadHandler(fd, fn)` (data or a connection has arrived) and `os.setWriteHandler(fd, fn)` (there is room to send). `os.setReadHandler(fd, null)` stops the calls. In this way one script serves many connections without threads.

Sockets are numbers (file descriptors), as in C.

## Sockets

- `net.listen(port, [host], [backlog])`: opens a TCP server socket on `port` and returns it. `host` is the IPv4 address to listen on (`"0.0.0.0"`, every address, by default); `backlog` how many connections may wait to be accepted (128). Throws an `Error` when the port is taken or the network is off.
- `net.accept(fd)`: takes a waiting connection of the server socket `fd`: `[socket, address, port]` with the client's IPv4 address and port, or `null` when none is waiting. The new socket is non-blocking.
- `net.read(fd, [max])`: reads up to `max` bytes (65536): an `ArrayBuffer` with the bytes; an empty `ArrayBuffer` when the other side has closed the connection (or it broke); `null` when no data is there yet.
- `net.write(fd, data, [offset], [length])`: sends bytes: `data` is an `ArrayBuffer`, a typed array or a string (sent as UTF-8), from `offset` and `length` bytes of it (all by default). Returns how many bytes were taken, which may be fewer than given; 0 when none could be taken now; -1 when the connection is closed.
- `net.close(fd)`: closes a socket.
- `net.encode(string)`: the string's UTF-8 bytes, an `ArrayBuffer`.
- `net.decode(data, [offset], [length])`: a string from UTF-8 bytes.

### Example: an echo server

Every line a client sends comes back to it:

```js
import * as net from "zdos:net";
import * as os from "qjs:os";

const server = net.listen(7000);
os.setReadHandler(server, () => {
  let c;
  while ((c = net.accept(server))) {
    const [fd, address, port] = c;
    console.log(`connected: ${address}:${port}`);
    os.setReadHandler(fd, () => {
      const data = net.read(fd);
      if (data === null) return;                 // nothing yet
      if (data.byteLength === 0) {               // closed by the client
        os.setReadHandler(fd, null);
        net.close(fd);
        return;
      }
      net.write(fd, data);                       // small: fits at once
    });
  }
});
console.log("echo server on port 7000");
```

A real server keeps what `net.write()` couldn't take and sends it from a write handler (`os.setWriteHandler()`) when the socket has room again; `zdos:web`'s source (`web.js`) shows how.

## TLS

```js
const tls = new net.TlsServer(certPem, keyPem);
```

makes a TLS server configuration from a certificate (PEM text, with any intermediate certificates after it) and its private key (PEM, RSA or EC, without a password). It throws an `Error` when they can't be read. One configuration serves any number of connections.

`tls.accept(fd)` starts a TLS connection on a socket that `net.accept()` returned, and returns a connection object. Its calls work like the socket's, except that when they would wait, they say for what: `"read"` (wait with `os.setReadHandler()`) or `"write"` (wait with `os.setWriteHandler()`). TLS sometimes has to send while the program reads, and read while it writes.

- `conn.handshake()`: continues the TLS handshake: `true` when it is complete, `"read"` or `"write"` when it waits. Throws when it fails (the client doesn't speak TLS, rejects the certificate ...). Call it again when the socket is ready, until it returns `true`.
- `conn.read([max])`: up to `max` decrypted bytes (16384): an `ArrayBuffer`; an empty one when the connection is closed; `"read"` or `"write"` when it waits.
- `conn.write(data, [offset], [length])`: encrypts and sends: the number of bytes taken, `"read"` or `"write"` when it waits, -1 when the connection is broken.
- `conn.close()`: sends TLS's close notice and frees the connection's state. The socket stays open: close it with `net.close()`.

Data may already be decrypted and waiting inside the TLS connection when the socket has nothing more to read, for example right after the handshake. So after `handshake()` returns `true`, and after each wake-up, read until `conn.read()` returns `"read"`.

The protocols are TLS 1.2 and 1.3, by the Mbed TLS port. There is no client side yet (connecting to other servers), no client certificates, and one certificate per configuration (no SNI).
