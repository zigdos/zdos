// WEBTEST.JS: the server web-tests.py talks to over HTTP and HTTPS:
// zdos:web's routes, middleware, body parsers, static files,
// cookies, errors, streaming, and a REST API on zdos:sqlite.
//   qjs WEBTEST.JS ROOT DB [CERT KEY]   (ROOT: the static files)
// GET /shutdown ends it: the servers close, the database too.
import express from "zdos:web";
import { Database } from "zdos:sqlite";
import * as std from "qjs:std";

const [, root, dbPath, certFile, keyFile] = scriptArgs;
const db = new Database(dbPath);
db.exec(`CREATE TABLE IF NOT EXISTS items (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, qty INTEGER NOT NULL DEFAULT 0, data BLOB)`);
db.exec("DELETE FROM items");

const app = express();
app.set("json spaces", 0);

// MIDDLEWARE
// headers for every response, the time when they go out
app.use((req, res, next) => {
  const start = Date.now();
  res.set({ "X-Powered-By": "zdos:web", "X-Request-Method": req.method });
  res.on("header", () => res.set("X-Response-Time", `${Date.now() - start}ms`));
  next();
});
app.use(express.json({ limit: "2mb" }));
app.use(express.urlencoded());
app.use(express.text());
app.use(express.raw({ type: "application/octet-stream", limit: "4mb" }));
app.use("/static", express.static(root, { maxAge: 60000 }));

// ECHO
// every method, what came in
const echo = (req, res) => res.json({
  method: req.method, path: req.path, url: req.originalUrl, query: req.query, params: req.params,
  body: req.body instanceof Uint8Array ? { bytes: req.body.length } : req.body,
  type: req.get("Content-Type") ?? null, secure: req.secure, protocol: req.protocol,
});
for (const m of ["get", "post", "put", "patch", "delete", "options", "purge", "search"]) app[m]("/echo", echo);
app.all("/any/*rest", echo);
app.get("/files/:dir/*path", echo);
app.get("/opt/:a/:b?", echo);
app.get(/^\/re\/(\d+)$/, echo);

// a binary body, its length and sum
app.post("/sum", (req, res) => {
  let s = 0;
  for (const b of req.body) s = (s + b) % 65536;
  res.json({ length: req.body.length, sum: s });
});

// COOKIES, REDIRECTS, STATUS
app.get("/cookie/set", (req, res) => {
  res.cookie("plain", "a b;c", { httpOnly: true, sameSite: "lax" });
  res.cookie("obj", { n: 5 }, { maxAge: 60000 });
  res.send("set");
});
app.get("/cookie/read", (req, res) => res.json(req.cookies));
app.get("/cookie/clear", (req, res) => res.clearCookie("plain").send("cleared"));
app.get("/old", (req, res) => res.redirect(301, "/echo?from=old"));
app.get("/temp", (req, res) => res.redirect("/echo"));
app.get("/teapot", (req, res) => res.sendStatus(418));
app.get("/nothing", (req, res) => res.status(204).end());

// ERRORS
app.get("/throw", () => { throw new Error("sync failure"); });
app.get("/reject", async () => { await null; throw express.httpError(409, "async conflict"); });
app.get("/next-error", (req, res, next) => next(express.httpError(422, "bad thing")));

// STREAMING
// pieces of unknown length: chunked
app.get("/stream", (req, res) => {
  res.type("text/plain");
  let i = 0;
  const piece = () => {
    if (i === 5) return res.end("end\n");
    res.write(`piece ${i++}\n`);
    import("qjs:os").then((os) => os.setTimeout(piece, 10));
  };
  piece();
});
// a big body built here
app.get("/big", (req, res) => {
  const n = Number(req.query.n || 1000000), b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = (i * 7) & 255;
  res.type("application/octet-stream").send(b);
});

// THE REST API
const api = express.Router({ mergeParams: true });
api.use((req, res, next) => { res.set("X-Api-Version", req.params.v); next(); });
api.param("id", (req, res, next, id) => {
  if (!/^\d+$/.test(id)) return next(express.httpError(400, "id: digits"));
  req.item = db.prepare("SELECT id, name, qty FROM items WHERE id = ?").get(Number(id));
  next();
});
api.route("/items")
  .get((req, res) => {
    const min = Number(req.query.min ?? -1e9);
    res.json(db.prepare("SELECT id, name, qty FROM items WHERE qty >= ? ORDER BY id").all(min));
  })
  .post((req, res) => {
    const { name, qty = 0 } = req.body ?? {};
    if (typeof name !== "string" || !name) return res.status(400).json({ error: "name" });
    try {
      const r = db.prepare("INSERT INTO items (name, qty) VALUES (:name, :qty)").run({ name, qty });
      res.status(201).location(`${req.baseUrl}/items/${r.lastInsertRowid}`).json({ id: r.lastInsertRowid, name, qty });
    } catch (e) {
      res.status(409).json({ error: e.message });
    }
  });
api.route("/items/:id")
  .get((req, res) => (req.item ? res.json(req.item) : res.status(404).json({ error: "not found" })))
  .put((req, res) => {
    if (!req.item) return res.sendStatus(404);
    db.prepare("UPDATE items SET name = ?, qty = ? WHERE id = ?").run(req.body.name, req.body.qty, req.item.id);
    res.json(db.prepare("SELECT id, name, qty FROM items WHERE id = ?").get(req.item.id));
  })
  .patch((req, res) => {
    if (!req.item) return res.sendStatus(404);
    db.prepare("UPDATE items SET qty = qty + ? WHERE id = ?").run(req.body.add ?? 0, req.item.id);
    res.json(db.prepare("SELECT id, name, qty FROM items WHERE id = ?").get(req.item.id));
  })
  .delete((req, res) => {
    const r = db.prepare("DELETE FROM items WHERE id = ?").run(Number(req.params.id));
    res.sendStatus(r.changes ? 204 : 404);
  });
// many in one transaction: all or none
api.post("/batch", (req, res) => {
  const insert = db.prepare("INSERT INTO items (name, qty) VALUES (?, ?)");
  const many = db.transaction((rows) => { for (const r of rows) insert.run(r.name, r.qty); return rows.length; });
  try {
    res.status(201).json({ inserted: many(req.body) });
  } catch (e) {
    res.status(409).json({ error: e.message, count: db.prepare("SELECT count(*) AS n FROM items").get().n });
  }
});
// a blob in, the same out
api.put("/items/:id/data", (req, res) => {
  db.prepare("UPDATE items SET data = ? WHERE id = ?").run(req.body, req.item.id);
  res.sendStatus(204);
});
api.get("/items/:id/data", (req, res) => {
  const row = db.prepare("SELECT data FROM items WHERE id = ?").get(req.item.id);
  res.type("application/octet-stream").send(row.data);
});
api.get("/types", (req, res) => {
  const r = db.prepare("SELECT 9007199254740993 AS big, 1.5 AS f, 'π' AS t, NULL AS n, x'00ff' AS b").get();
  res.json({ big: typeof r.big + ":" + String(r.big), f: r.f, t: r.t, n: r.n, b: [...r.b] });
});
app.use("/api/:v", api);

// ERROR HANDLER
// JSON for errors with a status, the rest to the default
app.use((err, req, res, next) => {
  if (err.status && err.status < 500) return res.status(err.status).json({ error: err.message });
  next(err);
});

// SERVERS
// (WEBTEST_PORT: another one, for a run on another system)
const port = Number(std.getenv("WEBTEST_PORT") || 8080);
const servers = [app.listen(port)];
if (certFile) servers.push(app.listen({ port: 8443, tls: { certFile, keyFile } }));
app.get("/shutdown", (req, res) => {
  res.send("bye");
  res.on("finish", () => {
    let open = servers.length;
    for (const s of servers) {
      s.close(() => {
        if (--open === 0) {
          db.close();
          console.log("closed");
        }
      });
    }
  });
});
console.log(`listening on ${port}${certFile ? " and 8443" : ""}`);
std.out.flush();
