// Front door on PORT, used only when /code is enabled (entrypoint.sh sets CODE_UPSTREAM and WEB_UPSTREAM, the
// loopback ports of code-server and `opencode web`). /code/* goes to code-server with the /code prefix stripped;
// everything else goes to opencode web untouched. HTTP, SSE and WebSockets are both proxied.
const http = require("http");
const net = require("net");
const port = Number(process.env.PORT || 8080);
const codeUp = Number(process.env.CODE_UPSTREAM);
const webUp = Number(process.env.WEB_UPSTREAM);
const defaultFolder = `${process.env.HOME || "/home/node"}/work`;

const isCode = (url) => /^\/code(?:[/?]|$)/.test(url);
// Where a request goes: [upstream port, path to send].
const route = (url) => (isCode(url) ? [codeUp, url.replace(/^\/code/, "") || "/"] : [webUp, url]);

const server = http.createServer((req, res) => {
  // A bare /code opens the default working directory; /code?folder=... and /code/... go through untouched.
  if (req.url === "/code") {
    res.writeHead(302, { location: `/code/?folder=${encodeURIComponent(defaultFolder)}` });
    return res.end();
  }
  const [up, path] = route(req.url);
  const proxied = http.request({ host: "127.0.0.1", port: up, method: req.method, path, headers: req.headers }, (r) => {
    res.writeHead(r.statusCode, r.headers);
    r.pipe(res);
  });
  proxied.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end("upstream is not reachable\n");
  });
  req.pipe(proxied);
});

// Replay the upgrade request on a raw socket to the chosen upstream and pipe both ways.
server.on("upgrade", (req, socket, head) => {
  const [up, path] = route(req.url);
  const out = net.connect(up, "127.0.0.1", () => {
    const lines = [`${req.method} ${path} HTTP/${req.httpVersion}`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
    out.write(lines.join("\r\n") + "\r\n\r\n");
    if (head && head.length) out.write(head);
    socket.pipe(out).pipe(socket);
  });
  out.on("error", () => socket.destroy());
  socket.on("error", () => out.destroy());
});

server.listen(port, "0.0.0.0", () => console.log(`[gateway] listening on ${port}: /code -> ${codeUp}, rest -> ${webUp}`));
