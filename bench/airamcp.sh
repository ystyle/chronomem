#!/bin/bash
# Minimal AiraXiv MCP client over raw HTTP.
#
# The MCP bridge in this profile reports "Invalid or expired session" for every
# call, so this talks to the endpoint directly. AiraXiv is session-based: a
# `tools/list` before `initialize` returns "Missing session.", and the session
# id must also be followed by a `notifications/initialized` before the tool list
# is populated (without it, `tools/list` returns zero tools rather than an error).
#
# Usage:  AIRAXIV_API_KEY=... airamcp.sh <tool> '<json args>'
#         AIRAXIV_API_KEY=... airamcp.sh --list-tools
#
# The key is read from the environment; this script never carries one.
set -euo pipefail

ENDPOINT="${AIRAXIV_URL:-https://airaxiv.com/mcp/}"
# The key comes from the environment only. An inline fallback was committed here
# once and reached three remotes, one of them public, before anyone noticed; a
# credential that is convenient to hard-code is a credential that will be.
KEY="${AIRAXIV_API_KEY:?AIRAXIV_API_KEY is not set — export it before running}"
UA='Content-Type: application/json'
AC='Accept: application/json, text/event-stream'

SID=$(curl -s -D - -o /dev/null -m 30 --noproxy '*' -X POST "$ENDPOINT" \
  -H "Authorization: Bearer $KEY" -H "$UA" -H "$AC" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"airamcp","version":"1"}}}' \
  | grep -i 'mcp-session-id' | tr -d '\r' | awk '{print $2}')
if [ -z "$SID" ]; then echo "no session id returned" >&2; exit 1; fi

curl -s -o /dev/null -m 20 --noproxy '*' -X POST "$ENDPOINT" \
  -H "Authorization: Bearer $KEY" -H "mcp-session-id: $SID" -H "$UA" -H "$AC" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

if [ "${1:-}" = "--list-tools" ]; then
  curl -s -m 40 --noproxy '*' -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $KEY" -H "mcp-session-id: $SID" -H "$UA" -H "$AC" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  exit 0
fi

TOOL="$1"; ARGS="${2:-{\}}"
curl -s -m 90 --noproxy '*' -X POST "$ENDPOINT" \
  -H "Authorization: Bearer $KEY" -H "mcp-session-id: $SID" -H "$UA" -H "$AC" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":$ARGS}}"
