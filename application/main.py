import asyncio
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

TARGET_HOST = os.getenv("TARGET_HOST", "10.0.2.133")  
TCP_PORT = int(os.getenv("TCP_PORT", "22"))         
MEASURE_INTERVAL = int(os.getenv("MEASURE_INTERVAL", "30")) 
latest: dict = {}


async def measureTcp(host: str, port: int) -> dict:
    start = time.perf_counter()
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port),
            timeout=5.0,
        )
        elapsed_ms = round((time.perf_counter() - start) * 1000, 3)
        writer.close()
        await writer.wait_closed()
        return {"status": "ok", "port": port, "latency_ms": elapsed_ms}

    except asyncio.TimeoutError:
        return {"status": "timeout", "port": port}
    except ConnectionRefusedError:
        return {"status": "connection_refused", "port": port}
    except OSError as e:
        return {"status": "error", "port": port, "detail": str(e)}

async def collectMetrics():
    global latest
    while True:
        result = await measureTcp(TARGET_HOST, TCP_PORT)
        latest = {
            "collected_at": datetime.now(timezone.utc).isoformat(),
            "target_host": TARGET_HOST,
            "tcp_port": TCP_PORT,
            "interval_seconds": MEASURE_INTERVAL,
            "tcp": result,
        }
        await asyncio.sleep(MEASURE_INTERVAL)


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(collectMetrics())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass

app = FastAPI(title="Latency Monitor", version="1.0.0", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/latency")
async def getLatency():
    if not latest:
        return {
            "status": "warming_up",
            "message": f"App not ready yet. Retry in {MEASURE_INTERVAL}s.",
        }
    return latest


@app.get("/metrics", response_class=PlainTextResponse)
async def getMetrics():

    if not latest:
        return "# App not ready yet\n"

    target = latest["target_host"]
    tcp = latest["tcp"]
    lines = [
        "# HELP tcp_latency_ms TCP handshake latency to the target host (milliseconds)",
        "# TYPE tcp_latency_ms gauge",
    ]

    if tcp["status"] == "ok":
        lines.append(
            f'tcp_latency_ms{{host="{target}",port="{tcp["port"]}"}} {tcp["latency_ms"]}'
        )
    else:
        lines.append(f'# tcp status={tcp["status"]} port={tcp["port"]} target={target}')

    lines += [
        "",
        "# HELP tcp_up 1 if the TCP port is reachable, 0 otherwise",
        "# TYPE tcp_up gauge",
        f'tcp_up{{host="{target}",port="{tcp["port"]}"}} {1 if tcp["status"] == "ok" else 0}',
    ]

    return "\n".join(lines) + "\n"
