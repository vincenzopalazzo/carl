#!/usr/bin/env python3
"""Minimal Nostr relay exposed as a Tor onion, for the ws:// onion-relay e2e.

It does three things:
  1. Pulls one real, signature-valid kind-2003 (NIP-35) event for INFOHASH from a
     public relay, so it can replay an event carl will accept (carl verifies
     Schnorr signatures -- a fake event would be rejected).
  2. Creates an ephemeral v3 onion via the Tor ControlPort (ADD_ONION). For ws://
     it forwards onion:80 -> 127.0.0.1:WS_PORT; for wss:// (RELAY_TLS=1) it
     generates a self-signed cert and forwards onion:443.
  3. Serves a tiny relay on 127.0.0.1:WS_PORT that answers every REQ with the
     stored EVENT followed by EOSE.

Prints `ONION <addr>.onion` on stdout once ready. Requires the `websockets`
package and read access to the Tor control cookie. Env overrides:
  WS_PORT, TOR_CONTROL_HOST, TOR_CONTROL_PORT, TOR_COOKIE, INFOHASH, SEED_RELAY,
  RELAY_TLS (set to 1 to serve wss instead of ws)
"""
import asyncio
import binascii
import json
import os
import socket
import ssl
import subprocess

import websockets

WS_PORT = int(os.environ.get("WS_PORT", "18777"))
CONTROL = (os.environ.get("TOR_CONTROL_HOST", "127.0.0.1"),
           int(os.environ.get("TOR_CONTROL_PORT", "9051")))
COOKIE = os.environ.get("TOR_COOKIE", "/var/lib/tor/control_auth_cookie")
INFOHASH = os.environ.get("INFOHASH", "08d72b48f0799bbf62a2dc54cb66cb1ed14f9431")
SEED_RELAY = os.environ.get("SEED_RELAY", "wss://nos.lol")
RELAY_TLS = os.environ.get("RELAY_TLS", "") not in ("", "0")
ONION_PORT = 443 if RELAY_TLS else 80

EVENT = None


async def fetch_event():
    async with websockets.connect(SEED_RELAY) as ws:
        sub = "fetch1"
        await ws.send(json.dumps(["REQ", sub, {"kinds": [2003], "#x": [INFOHASH], "limit": 1}]))
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=20))
            if msg[0] == "EVENT" and msg[1] == sub:
                return msg[2]
            if msg[0] == "EOSE":
                return None


def add_onion(port):
    with open(COOKIE, "rb") as fh:
        cookie = binascii.hexlify(fh.read()).decode()
    s = socket.create_connection(CONTROL)
    f = s.makefile("rw")

    def cmd(c):
        f.write(c + "\r\n")
        f.flush()
        out = []
        while True:
            line = f.readline().rstrip("\r\n")
            out.append(line)
            if len(line) >= 4 and line[3] == " ":
                break
        return out

    cmd("AUTHENTICATE " + cookie)
    res = cmd("ADD_ONION NEW:ED25519-V3 Port=%d,127.0.0.1:%d" % (ONION_PORT, port))
    onion = None
    for line in res:
        if "ServiceID=" in line:
            onion = line.split("ServiceID=")[1].split()[0]
    # Keep the control socket open: the ephemeral onion lives only as long as
    # the connection that created it.
    return onion, s


async def handler(ws):
    async for raw in ws:
        try:
            msg = json.loads(raw)
        except Exception:
            continue
        if isinstance(msg, list) and msg and msg[0] == "REQ":
            sub = msg[1]
            if EVENT is not None:
                await ws.send(json.dumps(["EVENT", sub, EVENT]))
            await ws.send(json.dumps(["EOSE", sub]))


def make_tls_context():
    # carl skips CA verification for .onion hosts (Tor authenticates the
    # address), so a throwaway self-signed cert is fine here.
    cert, key = "/tmp/carl_mock_relay_cert.pem", "/tmp/carl_mock_relay_key.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "ec",
         "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
         "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=carl-mock-relay"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    return ctx


async def main():
    global EVENT
    EVENT = await fetch_event()
    print("EVENT_FETCHED %s" % (EVENT is not None), flush=True)
    onion, _ctrl = add_onion(WS_PORT)
    print("ONION %s.onion" % onion, flush=True)
    ctx = make_tls_context() if RELAY_TLS else None
    async with websockets.serve(handler, "127.0.0.1", WS_PORT, ssl=ctx):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
