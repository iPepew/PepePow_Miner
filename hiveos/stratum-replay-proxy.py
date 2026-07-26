#!/usr/bin/env python3
import argparse
import asyncio
import json
import signal
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


def ts() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def parse_pool(url: str) -> tuple[str, int]:
    parsed = urlparse(url)
    if parsed.scheme != "stratum+tcp" or not parsed.hostname or not parsed.port:
        raise ValueError(f"unsupported upstream URL: {url}")
    return parsed.hostname, parsed.port


def reverse_u32_hex(value: str) -> str:
    if len(value) != 8:
        return value
    try:
        raw = bytes.fromhex(value)
    except ValueError:
        return value
    return raw[::-1].hex()


class Logger:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, kind: str, payload: str) -> None:
        line = f"{ts()} {kind} {payload}"
        print(line, flush=True)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")


async def bridge(reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
                 peer_writer: asyncio.StreamWriter, direction: str,
                 logger: Logger, rewrite_submit_nonce: bool) -> None:
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            text = line.decode("utf-8", errors="replace").rstrip("\r\n")
            out = text
            if direction == "MINER_TX" and rewrite_submit_nonce:
                try:
                    msg = json.loads(text)
                    if msg.get("method") == "mining.submit":
                        params = msg.get("params")
                        if isinstance(params, list) and len(params) >= 5 and isinstance(params[4], str):
                            original = params[4]
                            swapped = reverse_u32_hex(original)
                            params[4] = swapped
                            out = json.dumps(msg, separators=(",", ":"))
                            logger.write("NONCE_REWRITE", f"original={original} rewritten={swapped} id={msg.get('id')}")
                except Exception as exc:
                    logger.write("PROXY_PARSE_ERROR", f"direction={direction} error={exc} raw={text}")
            logger.write(direction, out)
            peer_writer.write((out + "\n").encode("utf-8"))
            await peer_writer.drain()
    finally:
        try:
            peer_writer.close()
            await peer_writer.wait_closed()
        except Exception:
            pass
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def handle_client(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter,
                        upstream_host: str, upstream_port: int, logger: Logger,
                        rewrite_submit_nonce: bool) -> None:
    peer = client_writer.get_extra_info("peername")
    logger.write("PROXY_CONNECT", f"miner={peer} upstream={upstream_host}:{upstream_port} rewrite_nonce={int(rewrite_submit_nonce)}")
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(upstream_host, upstream_port)
    except Exception as exc:
        logger.write("PROXY_UPSTREAM_ERROR", str(exc))
        client_writer.close()
        await client_writer.wait_closed()
        return

    await asyncio.gather(
        bridge(client_reader, client_writer, upstream_writer, "MINER_TX", logger, rewrite_submit_nonce),
        bridge(upstream_reader, upstream_writer, client_writer, "POOL_RX", logger, False),
        return_exceptions=True,
    )
    logger.write("PROXY_DISCONNECT", f"miner={peer}")


async def main_async(args: argparse.Namespace) -> int:
    upstream_host, upstream_port = parse_pool(args.upstream)
    logger = Logger(Path(args.log))
    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, upstream_host, upstream_port, logger, args.rewrite_submit_nonce),
        args.listen_host,
        args.listen_port,
    )
    sockets = ",".join(str(sock.getsockname()) for sock in server.sockets or [])
    logger.write("PROXY_START", f"listen={sockets} upstream={upstream_host}:{upstream_port} rewrite_nonce={int(args.rewrite_submit_nonce)}")

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except NotImplementedError:
            pass

    async with server:
        await stop_event.wait()
    logger.write("PROXY_STOP", "requested")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="PEPEPOW Stratum forensic proxy")
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=49333)
    parser.add_argument("--log", required=True)
    parser.add_argument("--rewrite-submit-nonce", action="store_true")
    args = parser.parse_args()
    try:
        return asyncio.run(main_async(args))
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        print(f"Fatal proxy error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
