#!/usr/bin/env python3
"""Independent HTTP/3 probe for the TLS edge.

`curl` on many distros (Ubuntu 22.04 included) is built without HTTP/3, so it
can verify the HTTP/2 fallback but not the QUIC path. This speaks real
HTTP/3 to the edge and prints each response chunk as it arrives — which is the
only way to prove the edge *flushes* the SSE stream over QUIC instead of
buffering it until the response ends.

Setup (once):

    python3 -m venv /tmp/opencode/aioquic-venv
    /tmp/opencode/aioquic-venv/bin/pip install aioquic

Usage:

    # one-shot request, prints status + body over QUIC
    python3 scripts/h3_probe.py /health 5

    # watch the SSE stream pour in (the relay pings every 15 s)
    python3 scripts/h3_probe.py /stream 20

Exits non-zero if no ALPN/status was seen, so it works as a check.
"""

from __future__ import annotations

import asyncio
import ssl
import sys
import time

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated

HOST = "localhost"
PORT = 3443


class Probe(QuicConnectionProtocol):
    """Prints ALPN, the status line and each body chunk with a timestamp."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._h3 = H3Connection(self._quic)
        self._t0 = time.time()
        self.saw_alpn = False
        self.saw_status: str | None = None
        self.body = bytearray()

    def _stamp(self) -> str:
        return f"[{time.time() - self._t0:5.2f}s]"

    def quic_event_received(self, event) -> None:
        if isinstance(event, ProtocolNegotiated):
            self.saw_alpn = True
            print(f"{self._stamp()} QUIC up, ALPN={event.alpn_protocol}", flush=True)

        for http_event in self._h3.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                status = dict(http_event.headers).get(b":status", b"?").decode()
                self.saw_status = status
                print(f"{self._stamp()} status={status}", flush=True)
            elif isinstance(http_event, DataReceived):
                self.body.extend(http_event.data)
                preview = bytes(http_event.data[:70])
                print(
                    f"{self._stamp()} chunk {len(http_event.data):>4}B {preview!r}",
                    flush=True,
                )


async def main(path: str, seconds: float) -> int:
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.verify_mode = ssl.CERT_NONE  # self-signed local CA — see relay/Caddyfile

    async with connect(
        HOST, PORT, configuration=config, create_protocol=Probe
    ) as client:
        stream_id = client._quic.get_next_available_stream_id()
        client._h3.send_headers(
            stream_id=stream_id,
            headers=[
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", f"{HOST}:{PORT}".encode()),
                (b":path", path.encode()),
                (b"accept", b"text/event-stream"),
            ],
        )
        client.transmit()
        await asyncio.sleep(seconds)
        probe: Probe = client  # type: ignore[assignment]
        print(f"\n{probe._stamp()} received {len(probe.body)} bytes total", flush=True)
        return 0 if probe.saw_alpn and probe.saw_status == "200" else 1


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "/health"
    duration = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
    sys.exit(asyncio.run(main(target, duration)))
