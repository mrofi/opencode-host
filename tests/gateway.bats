#!/usr/bin/env bats
# gateway.js: /code goes to code-server, everything else to opencode web (stub upstreams here).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export PORT=$((20000 + RANDOM % 5000))
  CODE=$((26000 + RANDOM % 2000)); WEB=$((28000 + RANDOM % 2000))
  # Stub upstream: echoes "<name>:<path>", answers WebSocket upgrades with 101 and "<name>-ws:<path>".
  for spec in "code $CODE" "web $WEB"; do
    set -- $spec
    node -e '
      const http=require("http"),n=process.argv[1];
      const s=http.createServer((q,r)=>r.end(n+":"+q.url));
      s.on("upgrade",(q,so)=>{so.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"+n+"-ws:"+q.url);so.end()});
      s.listen(+process.argv[2],"127.0.0.1")' "$1" "$2" &
    echo $! >> "$BATS_TEST_TMPDIR/pids"
  done
  CODE_UPSTREAM=$CODE WEB_UPSTREAM=$WEB node "$BATS_TEST_DIRNAME/../scripts/gateway.js" >/dev/null &
  echo $! >> "$BATS_TEST_TMPDIR/pids"
  for _ in $(seq 30); do curl -s -o /dev/null "localhost:$PORT/" && break; sleep 0.1; done
}
teardown() { xargs -r kill < "$BATS_TEST_TMPDIR/pids" 2>/dev/null || true; }

@test "everything but /code goes to opencode web, path and query untouched" {
  [ "$(curl -s "localhost:$PORT/session/x?a=1")" = "web:/session/x?a=1" ]
  [ "$(curl -s localhost:$PORT/codeish)" = "web:/codeish" ]
}

@test "/code/* goes to code-server with the prefix stripped, query kept" {
  [ "$(curl -s "localhost:$PORT/code/?folder=/home/node/work/x")" = "code:/?folder=/home/node/work/x" ]
  [ "$(curl -s localhost:$PORT/code/static/a.js)" = "code:/static/a.js" ]
}

@test "bare /code redirects to the default working directory" {
  run curl -s -o /dev/null -w '%{http_code} %{redirect_url}' localhost:$PORT/code
  [ "$output" = "302 http://localhost:$PORT/code/?folder=$(node -p "encodeURIComponent('$HOME/work')")" ]
}

@test "WebSocket upgrades are routed by path" {
  ws() { curl -s --max-time 3 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' "localhost:$PORT$1"; }
  [[ "$(ws /code/stable-abc/)" == *"code-ws:/stable-abc/"* ]]
  [[ "$(ws /pty/1)" == *"web-ws:/pty/1"* ]]
}

@test "a dead upstream gives 502, not a crash" {
  kill "$(head -1 "$BATS_TEST_TMPDIR/pids")"; sleep 0.3
  [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:$PORT/code/)" = "502" ]
  [ "$(curl -s localhost:$PORT/x)" = "web:/x" ]
}
