# zdos:web

`zdos:web` is a web framework for QuickJS on ZDOS, modelled on Express 4/5. It is built into `qjs.app`, so a script only has to import it:

```js
import express from "zdos:web";
```

If you know Express, most of what you know applies: you create an application, add middleware and routes, and start it listening. The server underneath is written for ZDOS. It speaks HTTP/1.1 (and HTTPS through Mbed TLS) over the `zdos:net` module, and runs inside QuickJS's own event loop: one thread serves many connections at once. Express's npm packages themselves do not run here, because they are built on Node's `http`, `stream` and `Buffer`, which QuickJS doesn't have.

The other ZDOS modules, `zdos:sqlite` and `zdos:net`, are described in [ZDOSMODS.md](ZDOSMODS.md).

## Contents

- [A first application](#a-first-application)
- [The application](#the-application)
- [Starting a server: listen](#starting-a-server-listen)
- [HTTPS](#https)
- [Routes](#routes)
- [Route paths](#route-paths)
- [Middleware](#middleware)
- [Routers](#routers)
- [Errors](#errors)
- [The request: req](#the-request-req)
- [The response: res](#the-response-res)
- [Body parsers](#body-parsers)
- [Static files](#static-files)
- [Logging](#logging)
- [The HTTP server in detail](#the-http-server-in-detail)
- [Everything the module exports](#everything-the-module-exports)
- [Differences from Express](#differences-from-express)
- [A complete example: a REST API on SQLite](#a-complete-example-a-rest-api-on-sqlite)

## A first application

Save this as `C:\WWW\HELLO.JS`:

```js
import express from "zdos:web";

const app = express();

app.get("/", (req, res) => {
  res.send("<h1>Hello from ZDOS</h1>");
});

app.get("/hello/:name", (req, res) => {
  res.json({ greeting: `Hello, ${req.params.name}!` });
});

app.listen(8080, () => console.log("listening on port 8080"));
```

and run it:

```
C:\>qjs C:\WWW\HELLO.JS
listening on port 8080
```

A browser on another computer can now open `http://<ZDOS's address>:8080/` (`IPCONFIG` shows the address). The script keeps running while the server listens; Ctrl+C ends it, as does closing every server with `server.close()`.

## The application

`express()` creates an application. The application is also a function `(req, res, next)`, so it can be mounted inside another application with `app.use("/admin", adminApp)`.

### Settings

Settings change how the application behaves. They are read with `app.get(name)` (with one argument only) and changed with `app.set(name, value)`, `app.enable(name)` and `app.disable(name)`. `app.enabled(name)` and `app.disabled(name)` test them. All settings are kept in `app.settings`.

- `etag` (default: `true`): `res.send()` adds a weak `ETag` to GET and HEAD answers and answers `304 Not Modified` when the client's `If-None-Match` matches it.
- `x-powered-by` (default: `false`): when enabled, responses carry `X-Powered-By: ZDOS`.
- `json spaces` (default: `undefined`): the indentation `res.json()` passes to `JSON.stringify()` (for example `2`).
- `json replacer` (default: `undefined`): the replacer `res.json()` passes to `JSON.stringify()`.
- `max body size` (default: 16 MiB): the largest request body the server accepts (in bytes); larger ones are answered `413 Payload Too Large`.
- `env` (default: `"production"`): kept for code that reads it; it changes nothing here.

Settings of your own can be stored the same way (`app.set("title", "My shop")`).

### app.locals

An object for values that live as long as the application, for example configuration that handlers need. Each response has its own `res.locals` as well.

### Application methods

- `app.use([path], ...functions)`: adds middleware, a router or another application, for every request whose path starts with `path` (default `/`). See [Middleware](#middleware).
- `app.get(path, ...handlers)`, `app.post(...)`, `app.put(...)` ...: adds a route for one HTTP method. See [Routes](#routes).
- `app.all(path, ...handlers)`: adds a route for every method.
- `app.route(path)`: returns a route object on which handlers for several methods can be chained.
- `app.param(name, fn)`: runs `fn` before the routes that have the parameter `:name`. See [Routers](#routers).
- `app.listen(...)`: starts an HTTP or HTTPS server. See below.
- `app.set()`, `app.get(name)`, `app.enable()`, `app.disable()`, `app.enabled()`, `app.disabled()`: settings, see above.

`app.servers` holds the servers `app.listen()` started, and `app.router` the application's router.

## Starting a server: listen

```js
const server = app.listen(port, [host], [callback]);
const server = app.listen(options, [callback]);
```

`port` is the TCP port (default 80, or 443 with `tls`). `host` is the IPv4 address to listen on: `"0.0.0.0"` (the default) means every address of the computer, `"127.0.0.1"` only connections from the computer itself. The callback is called once the server is listening.

With an options object:

- `port` (default: 80, or 443 with `tls`): the port.
- `host` (default: `"0.0.0.0"`): the address to listen on.
- `tls`: makes it an HTTPS server, see [HTTPS](#https).
- `maxBodySize` (default: the `max body size` setting, 16 MiB): the largest request body, in bytes.
- `keepAliveTimeout` (default: 15000): how long, in milliseconds, an idle kept-alive connection stays open.
- `headersTimeout` (default: 30000): how long a client may take to send a request's head and body; the clock restarts whenever data arrives.
- `maxRequestsPerSocket` (default: 1000): after this many requests a connection is closed after the answer.

An application can listen on several ports at once, for example HTTP and HTTPS:

```js
app.listen(80);
app.listen({ port: 443, tls: { certFile: "C:/CONF/WEB.CRT", keyFile: "C:/CONF/WEB.KEY" } });
```

### The server object

`app.listen()` returns a server:

- `server.close([callback])`: stops accepting connections. Idle connections are closed at once, busy ones after their current answer. The callback is called when the last connection is gone.
- `server.address()`: `{ address, family: "IPv4", port }`.
- `server.port`, `server.host`: the port and address it listens on.
- `server.connections`: the open connections (a `Set`).
- `server.listening`: `true` until `server.close()`.

When every server is closed and nothing else is waiting (timers, other handlers), the script ends.

A server can also be made without an application: `createServer([options], handler)` returns a server whose `handler(req, res)` gets every request, and `server.listen(port, [host], [callback])` starts it.

## HTTPS

Give `app.listen()` a `tls` object, and the server speaks HTTPS (TLS 1.2 and 1.3, by the Mbed TLS port):

```js
app.listen({
  port: 443,
  tls: { certFile: "C:/CONF/WEB.CRT", keyFile: "C:/CONF/WEB.KEY" },
});
```

- `certFile`: A PEM file with the server's certificate, followed by any intermediate certificates.
- `keyFile`: A PEM file with the private key (RSA or EC, not protected by a password).
- `cert`, `key`: the same as text, instead of the files.

`req.secure` is `true` and `req.protocol` is `"https"` for requests that came over TLS.

A certificate for testing can be made on another computer with OpenSSL:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout WEB.KEY -out WEB.CRT -days 365 -subj /CN=myzdos \
  -addext "subjectAltName=DNS:myzdos,IP:192.168.1.50"
```

Browsers warn about such self-signed certificates; for a server on the internet use one from a certificate authority (Let's Encrypt and others). One certificate per server: different certificates for different host names on one port (SNI) are not supported, nor are client certificates.

## Routes

A route connects an HTTP method and a path to one or more handler functions:

```js
app.get("/items", listItems);
app.post("/items", checkLogin, createItem);
app.delete("/items/:id", checkLogin, deleteItem);
```

Every handler gets the request, the response and `next`:

```js
function listItems(req, res, next) {
  res.json(items);
}
```

A handler either answers (with `res.send()`, `res.json()`, `res.end()` ...) or calls `next()` to pass the request on to the next handler of the route, and then to the next matching route or middleware. If no handler answers, the request ends as `404 Not Found`.

### Methods

There is a function for each method: `app.get()`, `app.post()`, `app.put()`, `app.patch()`, `app.delete()`, `app.head()`, `app.options()`, `app.trace()`, and the WebDAV and other methods `copy`, `lock`, `mkcol`, `move`, `purge`, `propfind`, `proppatch`, `report`, `search`, `unlock`, `link`, `unlink`. `express.METHODS` lists them.

`app.all(path, ...)` matches every method, including ones not in the list: any method name a client sends (letters, digits and a few signs) reaches `app.all()` routes.

Two methods get help:

- **HEAD**: a GET route also answers HEAD requests, unless a HEAD route was added. The answer has the same status and headers (including `Content-Length`), but no body.
- **OPTIONS**: when no route answers an OPTIONS request, the server answers `200` with an `Allow` header listing the methods the matching routes have (`GET,HEAD,PUT,DELETE` for example).

### Several handlers, arrays

A route can have several handlers, also given as arrays (which may be nested):

```js
const checks = [checkLogin, checkAdmin];
app.put("/settings", checks, saveSettings);
```

### app.route

`app.route(path)` returns a route on which the methods can be chained, which avoids repeating the path:

```js
app.route("/items/:id")
  .get((req, res) => { /* read */ })
  .put((req, res) => { /* replace */ })
  .patch((req, res) => { /* change */ })
  .delete((req, res) => { /* remove */ });
```

### next("route") and next("router")

`next("route")` skips the remaining handlers of the current route and goes on with the next route. `next("router")` leaves the current router (see [Routers](#routers)) and goes on after it.

```js
app.get("/user/:id", (req, res, next) => {
  if (req.params.id === "0") return next("route"); // to the next route below
  next();
}, (req, res) => res.send("a regular user"));

app.get("/user/:id", (req, res) => res.send("the special user 0"));
```

### async handlers

Handlers may be `async` functions or return promises. A rejected promise (an exception thrown in an `async` handler) goes to the error handlers, as `next(error)` would:

```js
app.get("/report", async (req, res) => {
  const data = await buildReport(); // if this throws, the error handlers get it
  res.json(data);
});
```

## Route paths

- `/about` matches `/about`, `/about/`; `req.params` is `{}`.
- `/users/:id` matches `/users/42`; `req.params` is `{ id: "42" }`.
- `/users/:id/books/:book` matches `/users/42/books/7`; `req.params` is `{ id: "42", book: "7" }`.
- `/posts/:year/:month?` matches `/posts/2026`, `/posts/2026/11`; `req.params` is `{ year: "2026" }`, `{ year: "2026", month: "11" }`.
- `/files/*path` matches `/files/a/b/c.txt`; `req.params` is `{ path: "a/b/c.txt" }`.
- `/files/*` matches `/files/a/b/c.txt`; `req.params` is `{ 0: "a/b/c.txt" }`.
- `/item/:id(\\d+)` matches `/item/12`, not `/item/ab`; `req.params` is `{ id: "12" }`.
- `/^\/re\/(\d+)$/` (a RegExp) matches `/re/42`; `req.params` is `{ 0: "42" }`.
- `["/a", "/b"]` (an array) matches `/a` and `/b`.

- A parameter (`:name`) matches one path segment: everything up to the next `/`. Its value is decoded (`%20` becomes a space).
- `?` after a parameter makes it optional, including the `/` before it.
- `*` matches the rest of the path, including `/`. Named (`*path`) it becomes `req.params.path`; unnamed, `req.params[0]`, `req.params[1]` ...
- A parameter may have its own regular expression in parentheses: `:id(\\d+)` (in a JavaScript string the backslash is doubled).
- RegExp paths give their capture groups as `req.params[0]`, `[1]` ...
- Paths are not case-sensitive (`/About` matches `/about`), and a trailing `/` is allowed. `express.Router({ caseSensitive: true, strict: true })` changes both for a router.
- The query string (`?...`) is not part of the path and never affects matching.

## Middleware

Middleware are functions that run for every request whose path starts with a given prefix, before (or between) the routes. They are added with `app.use()`:

```js
app.use(fn);                 // every request
app.use("/api", fn);         // /api, /api/..., not /apis
app.use(fn1, fn2, [fn3]);    // several at once
```

They run in the order they were added, interleaved with the routes in that same order. A middleware either answers or calls `next()`.

### Setting response headers

Middleware can add headers to every response, before the handler that answers:

```js
app.use((req, res, next) => {
  res.set("X-Frame-Options", "DENY");
  res.set({
    "Strict-Transport-Security": "max-age=31536000",
    "Cache-Control": "no-store",
  });
  next();
});
```

Headers set this way stay unless a later handler changes or removes them (`res.set()` with the same name replaces the value, `res.removeHeader(name)` removes it).

Some headers can only be known when the answer goes out, for example how long the request took. The `"header"` event runs just before the status line and headers are sent, while they can still be changed:

```js
app.use((req, res, next) => {
  const start = Date.now();
  res.on("header", () => res.set("X-Response-Time", `${Date.now() - start}ms`));
  next();
});
```

The `"finish"` event runs when the answer has been handed to the network (good for logging), and `"close"` when the connection closed before the answer was complete.

### Mounting and req.url

Middleware mounted on a path sees the path without that prefix: in `app.use("/api", fn)`, a request for `/api/items?x=1` reaches `fn` with `req.url` = `/items?x=1`, `req.path` = `/items` and `req.baseUrl` = `/api`. `req.originalUrl` is always the whole original target. This is what lets a router or application be mounted anywhere.

### Mounting other applications

An application can be mounted in another one; it keeps its own settings:

```js
const admin = express();
admin.get("/", (req, res) => res.send("admin home"));
app.use("/admin", admin);
```

## Routers

A router is a small application without settings or `listen()`: a group of routes and middleware that can be mounted on a path. `express.Router([options])` creates one:

```js
const api = express.Router();

api.use((req, res, next) => {
  res.set("X-API-Version", "1");
  next();
});

api.get("/items", listItems);
api.post("/items", createItem);

app.use("/api/v1", api);   // GET /api/v1/items
```

- `mergeParams` (default: `false`): the router's routes also see the parameters of the path it is mounted on (`app.use("/shops/:shop", router)` gives `req.params.shop` inside).
- `caseSensitive` (default: `false`): `/About` and `/about` are different.
- `strict` (default: `false`): `/about` and `/about/` are different.

A router has `use()`, `route()`, `all()`, `param()` and a function per method, like the application.

### param

`router.param(name, fn)` (and `app.param()`) runs `fn(req, res, next, value, name)` before the first route whose path has the parameter `:name`, once per request. It is the place to check a parameter or load what it refers to:

```js
api.param("id", (req, res, next, id) => {
  if (!/^\d+$/.test(id)) return next(express.httpError(400, "the id must be a number"));
  req.item = db.prepare("SELECT * FROM items WHERE id = ?").get(Number(id));
  next();
});

api.get("/items/:id", (req, res) => {
  req.item ? res.json(req.item) : res.sendStatus(404);
});
```

## Errors

### How errors travel

An error reaches the error handlers in three ways:

1. a handler throws (`throw new Error(...)`);
2. an `async` handler's promise is rejected;
3. a handler calls `next(error)`.

From then on, ordinary handlers are skipped, and only error handlers run. An error handler has **four** parameters, which is how it is recognised:

```js
app.use((err, req, res, next) => {
  res.status(err.status || 500).json({ error: err.message });
});
```

An error handler can answer, or pass the error on with `next(err)`, or call `next()` to go back to ordinary handlers. Error handlers are added with `app.use()` after the routes, so that they see the routes' errors.

### Errors with a status

`express.httpError(status, [message])` makes an error with a `status` (and `statusCode`) property:

```js
app.get("/items/:id", (req, res, next) => {
  const item = find(req.params.id);
  if (!item) return next(express.httpError(404, "no such item"));
  res.json(item);
});
```

Its `expose` property is `true` below 500: the message is meant for the client.

### When no error handler answers

The built-in final handler answers:

- an error with a status from 400 to 599: that status, and as plain text the error's message (for 4xx) or the status's name (for 5xx);
- any other error: `500 Internal Server Error`; the error and its stack are written to the standard error output;
- no error, and no handler answered: `404 Not Found` with the text `Cannot GET /the/path`.

These answers carry `Content-Security-Policy: default-src 'none'` and `X-Content-Type-Options: nosniff`, as Express's do. The headers set by middleware before the error are dropped (except those in the error's own `headers` object).

If an error happens after the answer's head was sent, the connection is closed, since the answer can't be changed anymore.

## The request: req

- `req.method`: the method in capitals: `"GET"`, `"POST"` ...
- `req.url`: the target, relative to where the current router is mounted: `/items?x=1`.
- `req.originalUrl`: the target as the client sent it.
- `req.path`: `req.url` without the query string.
- `req.baseUrl`: the path the current router or application is mounted on.
- `req.query`: the query string as an object, see below.
- `req.params`: the route's parameters, see [Route paths](#route-paths).
- `req.body`: what a body parser made of the body (`undefined` without one), see [Body parsers](#body-parsers).
- `req.rawBody`: the body as it came, a `Uint8Array` (empty when there was none).
- `req.headers`: the request's headers, with names in lower case. A header sent several times appears once, its values joined with `, ` (`; ` for `cookie`).
- `req.rawHeaders`: the headers as sent: `[name, value, name, value, ...]`.
- `req.cookies`: the cookies, see below.
- `req.hostname`: the `Host` header without the port. `req.host` with it.
- `req.ip`: the client's IPv4 address.
- `req.secure`: `true` over HTTPS.
- `req.protocol`: `"http"` or `"https"`.
- `req.httpVersion`: `"1.1"` or `"1.0"`.
- `req.xhr`: `true` when `X-Requested-With` is `XMLHttpRequest`.
- `req.socket`: `{ remoteAddress, remotePort, encrypted }`.
- `req.route`: the route that is handling the request.
- `req.app`, `req.res`: the application and the response.

- `req.get(name)`, `req.header(name)`: A header's value, by any case of its name. `referer` and `referrer` both work.
- `req.is(type)`: whether the body's `Content-Type` is `type`: `"json"`, `"html"`, `"application/*"`, `"text/plain"` ... Returns the matching type, `false`, or `null` when there is no body.
- `req.accepts(...types)`: which of the types the client's `Accept` header prefers: `req.accepts("json", "html")` returns `"json"`, `"html"` or `false`. Without arguments, the accepted types in order of preference.

### Query strings

`req.query` is built from the part after `?`:

- `?page=2&sort=name` gives `{ page: "2", sort: "name" }`
- `?tag=a&tag=b` gives `{ tag: ["a", "b"] }`
- `?tag[]=a` gives `{ tag: ["a"] }`
- `?q=hello+world%21` gives `{ q: "hello world!" }`
- `?flag` gives `{ flag: "" }`

Values are always strings (or arrays of strings): convert them yourself (`Number(req.query.page)`). Nested objects (`a[b]=c`) are not built; such a key stays as it is.

### Cookies

`req.cookies` is an object of the cookies the client sent. Values are URL-decoded; a value written by `res.cookie()` with an object (`j:` followed by JSON) comes back as that object.

## The response: res

Most methods return `res`, so they can be chained: `res.status(201).set("Location", url).json(item)`.

### Status and headers

- `res.status(code)`: sets the status code.
- `res.statusCode`: the status code (200 unless set).
- `res.statusMessage`: the text after the code in the status line; the standard name unless set.
- `res.set(name, value)`, `res.header(name, value)`: sets a header, replacing an earlier value. `value` may be an array for a header sent several times.
- `res.set({ name: value, ... })`: sets several headers.
- `res.setHeader(name, value)`: the same (Node's name).
- `res.get(name)`, `res.getHeader(name)`: A header's current value.
- `res.getHeaders()`: all headers, as an object with lower-case names.
- `res.hasHeader(name)`: whether a header is set.
- `res.removeHeader(name)`: removes a header.
- `res.append(name, value)`: adds a value to a header (for `Set-Cookie`, `Link`, `Vary` ...).
- `res.type(type)`, `res.contentType(type)`: sets `Content-Type`: a full type (`"text/csv"`) or a file extension or name (`"json"`, `".png"`, `"report.pdf"`). Text types get `; charset=utf-8`.
- `res.vary(name)`: adds a header name to `Vary`.
- `res.location(url)`: sets `Location`. `"back"` means the request's `Referer` (or `/`).
- `res.attachment([filename])`: `Content-Disposition: attachment`, with the file name and its type if given: the browser saves the answer instead of showing it.
- `res.writeHead(code, [message], [headers])`: status, message and headers at once (Node's form).
- `res.headersSent`: `true` once the status line and headers have gone out; after that they can't change.
- `res.locals`: an object for values belonging to this request, shared by its handlers.

`Content-Length`, `Date` and `Connection` are added by the server; `Transfer-Encoding: chunked` when a body's length isn't known in advance.

### Sending an answer

- `res.send(body)`: sends the body and ends the answer. A string is sent as `text/html` unless a type is set; a `Uint8Array`, `ArrayBuffer` or other typed array as `application/octet-stream`; an object, array, `null` or boolean as JSON; a number alone as a status (like `res.sendStatus()`).
- `res.json(value)`: sends `value` as JSON (`application/json; charset=utf-8`).
- `res.sendStatus(code)`: sends the status with its name as the text: `res.sendStatus(404)` sends `Not Found`.
- `res.end([data])`: ends the answer, with `data` as the (last part of the) body.
- `res.redirect([code], url)`: sends a redirect, 302 unless `code` is given (301, 303, 307, 308).
- `res.sendFile(path, [options], [callback])`: sends a file, see below.
- `res.download(path, [filename], [options], [callback])`: sends a file to be saved, as `filename` (the file's own name by default).

After an answer has been sent, further `res.send()`, `res.json()` or `res.end()` calls are ignored.

### Caching: ETag and 304

For GET and HEAD requests, `res.send()` (and `res.json()`, which uses it) adds a weak `ETag` computed from the body (unless the `etag` setting is off or an `ETag` was set). When the request's `If-None-Match` has that tag, the answer becomes `304 Not Modified` without a body, and the client uses its copy. `res.sendFile()` does the same with an `ETag` and `Last-Modified` from the file's size and time, and also honours `If-Modified-Since`. `Cache-Control: no-cache` in the request skips this.

`res.fresh()` tells whether the client's copy is current, for handlers that want to decide themselves.

### Streaming: write

When the body is produced in pieces, `res.write(piece)` sends each piece as it comes and `res.end()` finishes. Without a `Content-Length` set, the answer uses chunked transfer encoding (for HTTP/1.0 clients the connection is closed at the end instead):

```js
app.get("/events", (req, res) => {
  res.type("text/plain");
  let n = 0;
  const timer = os.setInterval(() => {
    res.write(`tick ${++n}\n`);
    if (n === 10) { os.clearInterval(timer); res.end(); }
  }, 1000);
  res.on("close", () => os.clearInterval(timer)); // the client went away
});
```

(`os` is `import * as os from "qjs:os"`.)

`res.write()` returns `false` when more than 1 MiB is waiting to be sent: then wait before writing more. `res.write(piece, callback)` calls the callback once everything written so far has been handed to the network.

### Cookies

```js
res.cookie(name, value, [options]);
res.clearCookie(name, [options]);
```

`value` may be a string or an object (stored as `j:` and JSON, read back as the object by `req.cookies`). The value is URL-encoded.

- `maxAge`: lifetime in milliseconds (`Max-Age` and `Expires`).
- `expires`: the end of its life, a `Date`.
- `path`: the path it is sent for, `/` by default.
- `domain`: the domain it is sent to.
- `secure`: only over HTTPS.
- `httpOnly`: not visible to the page's JavaScript.
- `sameSite`: `"strict"`, `"lax"`, `"none"`, or `true` for strict.
- `partitioned`: the `Partitioned` attribute.
- `encode`: A function used instead of `encodeURIComponent`.

`res.clearCookie()` sends the cookie with an expiry in the past; give it the same `path` and `domain` as when it was set.

### Files: sendFile

```js
res.sendFile(path, [options], [callback]);
```

`path` must be absolute (`C:/WWW/report.pdf`), or relative with the `root` option. The file's type comes from its extension. Large files are sent in pieces as the connection takes them, so they don't have to fit in memory.

- `root`: the folder `path` is relative to; a `path` with `..` in it is refused (403).
- `headers`: headers to set.
- `maxAge`: `Cache-Control: public, max-age=...`, in milliseconds.
- `lastModified`: `false` leaves out `Last-Modified`.
- `etag`: `false` leaves out the `ETag`.

The callback is called with an error (a missing file is a 404 error) or without one when the file has been sent. Without a callback, an error goes to the error handlers.

```js
app.get("/invoice/:n", (req, res) => {
  res.sendFile(`INV${req.params.n}.PDF`, { root: "C:/INVOICES" });
});
```

## Body parsers

The server reads a request's whole body before the handlers run; it is in `req.rawBody` as bytes. Body parsers turn it into `req.body`. They are middleware, usually added for the whole application:

```js
app.use(express.json());
app.use(express.urlencoded());
```

A parser only works on requests whose `Content-Type` matches its type; others pass untouched, so several parsers can be added side by side.

- `express.json([options])`, for `application/json` and `*/*+json`: `req.body` is the parsed JSON.
- `express.urlencoded([options])`, for `application/x-www-form-urlencoded` (HTML forms): `req.body` is an object of the fields, as for query strings.
- `express.text([options])`, for `text/plain`: `req.body` is the body as a string.
- `express.raw([options])`, for `application/octet-stream`: `req.body` is the body as a `Uint8Array`.

Options:

- `limit` (default: `"100kb"`): the largest body this parser takes: a number of bytes or a string (`"2mb"`, `"500kb"`). Larger bodies give a 413 error. The server's own limit (16 MiB) still applies.
- `type` (default: the parser's type): another type or list of types (`"application/vnd.api+json"`, `["text/*"]`), or a function `(req) => boolean`.
- `strict` (default: `true`): for `json`, only objects and arrays at the top.
- `reviver`: for `json`, passed to `JSON.parse()`.
- `verify`: A function `(req, res, rawBody)` called after parsing; throw in it to refuse the body.

A body that can't be parsed (bad JSON for example) gives an error with status 400; its `body` property has the text.

As in Express 4, `json` and `urlencoded` set `req.body` to `{}` when there is no body to parse, so `req.body.name` doesn't throw.

Multipart bodies (`multipart/form-data`, file uploads from HTML forms) have no parser yet; `req.rawBody` has them for code of your own.

## Static files

`express.static(root, [options])` serves the files of a folder:

```js
app.use(express.static("C:/WWW"));              // /logo.png is C:/WWW/logo.png
app.use("/assets", express.static("C:/ASSETS")); // /assets/app.css is C:/ASSETS/app.css
```

- `root` may be relative: it is taken from the current folder when `express.static()` is called.
- Only GET and HEAD requests are served; others go on to the next handlers.
- A folder is answered with its `index.html`; a folder asked for without a trailing `/` is redirected (301) to the address with it, so that relative links in the page work.
- A file that isn't there goes on to the next handlers (in the end: 404).
- Paths with `..`, backslashes or drive letters are refused with 403, so nothing outside `root` can be reached.
- Names starting with a dot (`.env`, `.git`) are not served unless `dotfiles` says so.
- Files get `Last-Modified`, an `ETag` and, with `maxAge`, `Cache-Control`; conditional requests are answered 304. Large files are sent in pieces.

- `index` (default: `"index.html"`): the file for a folder: a name, a list of names to try, or `false` for none.
- `maxAge` (default: 0): how long browsers may keep the files without asking again, in milliseconds (a number): `Cache-Control: public, max-age=...` in seconds. Strings like `"1h"` are not understood.
- `dotfiles` (default: `"ignore"`): `"allow"` serves them, `"deny"` answers 403, `"ignore"` treats them as missing.
- `fallthrough` (default: `true`): with `false`, a missing file is a 404 error and other methods get 405, instead of going on.
- `redirect` (default: `true`): with `false`, no redirect for folders without `/`.
- `etag`, `lastModified` (default: `true`): `false` leaves the header out.
- `setHeaders`: A function `(res, path, stat)` to set headers of your own for each file.

## Logging

`express.logger([options])` writes one line per answered request to the standard output: the time, the client's address, the method, the address asked for, the status, the milliseconds it took and the body's length.

```js
app.use(express.logger());
```

```
2026-11-14T12:30:05.120Z 192.168.1.20 GET /items 200 3ms 182
```

`options.stream` is a QuickJS file (for example one opened with `std.open("C:/DATA/WEB.LOG", "a")`) to write to instead.

Errors of status 500 are written to the standard error output by the final handler, with their stack.

## The HTTP server in detail

- **HTTP/1.1 and 1.0.** Connections are kept open (keep-alive) for further requests unless the client says `Connection: close` or speaks HTTP/1.0 without `Connection: keep-alive`. Requests sent one after another without waiting (pipelining) are answered in order.
- **One thread.** All connections are served by QuickJS's event loop. A handler that computes for a long time, or a large SQLite query, holds up every other connection meanwhile. For heavy work, use a QuickJS `os.Worker`.
- **Request bodies** are read whole before the handlers run: with `Content-Length`, or chunked (`Transfer-Encoding: chunked`). `Expect: 100-continue` is answered with `100 Continue`. Bodies above the limit are refused with 413, before they are read.
- **Limits.** The request's head (request line and headers) may be up to 32 KiB (more: 431). A request that doesn't arrive within `headersTimeout` (30 s) is dropped; idle connections are closed after `keepAliveTimeout` (15 s).
- **Malformed requests** are answered 400 and the connection is closed; an unknown `Transfer-Encoding` gets 501.
- **Addresses.** IPv4 only, as ZDOS's network.

## Everything the module exports

```js
import express, {
  Router, Route, Request, Response, Server, createServer,
  httpError, STATUS_CODES, METHODS, parseQuery, version,
} from "zdos:web";
```

- `express`, the default export: creates an application. Also has `express.json()`, `urlencoded()`, `text()`, `raw()`, `static()`, `logger()`, `Router()`, `httpError()`, `createServer()`, `STATUS_CODES`, `METHODS` (in capitals), `parseQuery()`, `version`.
- `Router`: the router class (`new Router(options)` or `express.Router(options)`).
- `Route`: the class `app.route()` returns.
- `Request`, `Response`: the classes of `req` and `res`; methods added to their prototypes are available on every request.
- `Server`, `createServer(options, handler)`: the HTTP server.
- `httpError(status, message)`: an `Error` with a status.
- `STATUS_CODES`: `{ 200: "OK", 404: "Not Found", ... }`.
- `METHODS`: the method names, in lower case.
- `parseQuery(string)`: parses a query string as `req.query` does.
- `version`: the module's version.

## Differences from Express

- **No views.** `res.render()`, `app.engine()` and template engines are not there; build HTML in JavaScript (template literals work well) or serve static files.
- **No multipart parser**, and no `res.format()`, `res.jsonp()`, `res.links()`, `req.fresh` / `req.stale`, `req.range()` or range requests (`206`).
- **Bodies are read before the handlers run** instead of being streamed to them: the body parsers are synchronous and `req.rawBody` always has the bytes.
- **Express's npm packages don't run**, and middleware written for Node (helmet, cors, morgan, multer ...) has to be rewritten; most of them are a few lines here. A CORS middleware, for example:

```js
app.use((req, res, next) => {
  res.set("Access-Control-Allow-Origin", "*");
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.sendStatus(204);
  }
  next();
});
```

- **Paths** follow Express 5 for wildcards (`*name`) and Express 4 for `?` and `(regex)`; `*` alone also works.
- **No `trust proxy`**: `req.ip` and `req.protocol` are the connection's own.

## A complete example: a REST API on SQLite

```js
import express from "zdos:web";
import { Database } from "zdos:sqlite";

const db = new Database("C:/DATA/SHOP.DB");
db.exec(`CREATE TABLE IF NOT EXISTS items (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  qty  INTEGER NOT NULL DEFAULT 0
)`);

const app = express();
app.use(express.logger());
app.use(express.json());
app.use((req, res, next) => {
  res.set("Cache-Control", "no-store");
  next();
});

const api = express.Router();

api.param("id", (req, res, next, id) => {
  if (!/^\d+$/.test(id)) return next(express.httpError(400, "id: a number"));
  req.item = db.prepare("SELECT * FROM items WHERE id = ?").get(Number(id));
  if (!req.item) return next(express.httpError(404, "no such item"));
  next();
});

api.route("/items")
  .get((req, res) => {
    res.json(db.prepare("SELECT * FROM items ORDER BY name").all());
  })
  .post((req, res) => {
    const { name, qty = 0 } = req.body;
    if (typeof name !== "string" || name === "") throw express.httpError(400, "name: required");
    const r = db.prepare("INSERT INTO items (name, qty) VALUES (?, ?)").run(name, qty);
    res.status(201).location(`/api/items/${r.lastInsertRowid}`).json({ id: r.lastInsertRowid, name, qty });
  });

api.route("/items/:id")
  .get((req, res) => res.json(req.item))
  .put((req, res) => {
    db.prepare("UPDATE items SET name = ?, qty = ? WHERE id = ?").run(req.body.name, req.body.qty, req.item.id);
    res.json({ ...req.item, ...req.body });
  })
  .patch((req, res) => {
    db.prepare("UPDATE items SET qty = qty + ? WHERE id = ?").run(req.body.add ?? 0, req.item.id);
    res.json(db.prepare("SELECT * FROM items WHERE id = ?").get(req.item.id));
  })
  .delete((req, res) => {
    db.prepare("DELETE FROM items WHERE id = ?").run(req.item.id);
    res.sendStatus(204);
  });

app.use("/api", api);
app.use(express.static("C:/WWW"));

// errors: JSON for the API, the status's text otherwise
app.use((err, req, res, next) => {
  if (!req.originalUrl.startsWith("/api/")) return next(err);
  res.status(err.status || 500).json({ error: err.status < 500 ? err.message : "internal error" });
});

app.listen(8080, () => console.log("shop on port 8080"));
```

Trying it from another computer:

```sh
curl -X POST http://myzdos:8080/api/items -H 'Content-Type: application/json' -d '{"name":"apple","qty":3}'
curl http://myzdos:8080/api/items
curl -X PATCH http://myzdos:8080/api/items/1 -H 'Content-Type: application/json' -d '{"add":5}'
curl -X DELETE http://myzdos:8080/api/items/1
```
