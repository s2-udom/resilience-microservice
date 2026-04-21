from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os
import time
import threading
import logging
import json
import pybreaker
from datetime import datetime, timezone
from typing import Optional

logging.basicConfig(format="%(message)s", level=logging.INFO)
logger = logging.getLogger("resilience-service")

def log(level: int, event: str, **kwargs):
    entry = {
        "event": event,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        **kwargs
    }
    logger.log(level, json.dumps(entry))

app = FastAPI(
    title="Resilience Target Service",
    description="A self-healing microservice demonstrating the MAPE-K autonomic loop.",
    version="2.0.0"
)

_inventory: dict[str, dict] = {
    "item-001": {"id": "item-001", "name": "Widget A", "quantity": 100, "price": 9.99},
    "item-002": {"id": "item-002", "name": "Widget B", "quantity": 50, "price": 14.99},
}

_service_state = {
    "healthy": True,
    "start_time": time.time(),
    "request_count": 0,
    "error_count": 0,
    "leak_thread_active": False,
}

_leak_store: list = []

circuit_breaker = pybreaker.CircuitBreaker(
    fail_max=3,
    reset_timeout=30,
    name="downstream-pricing-api"
)

cb_call_count = 0
cb_rejected_count = 0
cb_latency_samples: list[float] = []


@circuit_breaker
def _call_downstream_pricing(item_id: str) -> dict:
    start = time.time()
    time.sleep(0.15)
    if not _service_state["healthy"]:
        raise Exception("Downstream pricing service unavailable")
    elapsed = time.time() - start
    cb_latency_samples.append(elapsed)
    return {"item_id": item_id, "price_usd": 9.99, "source": "pricing-api", "latency_ms": round(elapsed * 1000, 2)}


class InventoryItem(BaseModel):
    name: str
    quantity: int
    price: float


@app.get("/health")
def health_check():
    _service_state["request_count"] += 1
    if not _service_state["healthy"]:
        log(logging.WARNING, "HEALTH_CHECK_UNHEALTHY")
        raise HTTPException(status_code=503, detail="Service degraded")
    uptime = round(time.time() - _service_state["start_time"], 2)
    log(logging.INFO, "HEALTH_CHECK_OK", uptime_seconds=uptime)
    return {
        "status": "healthy",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "uptime_seconds": uptime,
        "version": "2.0.0"
    }


@app.get("/metrics")
def get_metrics():
    avg_latency = (
        round(sum(cb_latency_samples) / len(cb_latency_samples) * 1000, 2)
        if cb_latency_samples else 0
    )
    return {
        "service": "resilience-target",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "request_count": _service_state["request_count"],
        "error_count": _service_state["error_count"],
        "circuit_breaker": {
            "state": circuit_breaker.current_state,
            "total_calls": cb_call_count,
            "rejected_calls": cb_rejected_count,
            "avg_latency_ms": avg_latency,
            "fail_count": circuit_breaker.fail_counter,
        },
        "memory_leak_active": _service_state["leak_thread_active"],
    }


@app.get("/inventory")
def list_inventory():
    _service_state["request_count"] += 1
    log(logging.INFO, "LIST_INVENTORY", item_count=len(_inventory))
    return {"items": list(_inventory.values()), "count": len(_inventory)}


@app.get("/inventory/{item_id}")
def get_item(item_id: str):
    global cb_call_count, cb_rejected_count
    _service_state["request_count"] += 1
    if item_id not in _inventory:
        raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
    item = _inventory[item_id].copy()
    cb_call_count += 1
    cb_state_before = circuit_breaker.current_state
    try:
        pricing = _call_downstream_pricing(item_id)
        item["live_price"] = pricing
        item["pricing_source"] = "live"
        log(logging.INFO, "ITEM_FETCHED_WITH_PRICING",
            item_id=item_id, cb_state=cb_state_before)
    except pybreaker.CircuitBreakerError:
        cb_rejected_count += 1
        item["live_price"] = None
        item["pricing_source"] = "cached-circuit-open"
        log(logging.WARNING, "CIRCUIT_BREAKER_OPEN",
            item_id=item_id, rejected_total=cb_rejected_count)
    except Exception as e:
        _service_state["error_count"] += 1
        item["live_price"] = None
        item["pricing_source"] = "error"
        log(logging.ERROR, "PRICING_CALL_FAILED", item_id=item_id, error=str(e))
    return item


@app.post("/inventory", status_code=201)
def create_item(item: InventoryItem):
    _service_state["request_count"] += 1
    item_id = f"item-{len(_inventory) + 1:03d}"
    _inventory[item_id] = {"id": item_id, **item.model_dump()}
    log(logging.INFO, "ITEM_CREATED", item_id=item_id)
    return _inventory[item_id]


@app.delete("/inventory/{item_id}")
def delete_item(item_id: str):
    _service_state["request_count"] += 1
    if item_id not in _inventory:
        raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
    del _inventory[item_id]
    log(logging.INFO, "ITEM_DELETED", item_id=item_id)
    return {"deleted": item_id}


@app.get("/")
def read_root():
    _service_state["request_count"] += 1
    return {
        "service": "Resilience Target Service",
        "version": "2.0.0",
        "endpoints": ["/health", "/metrics", "/inventory", "/simulate-failure"],
        "docs": "/docs"
    }


@app.get("/simulate-failure")
def simulate_failure(type: str = "crash"):
    log(logging.WARNING, "CHAOS_INJECTED", failure_type=type)
    if type == "crash":
        log(logging.CRITICAL, "CHAOS_CRASH_INITIATED")
        os._exit(1)
    elif type == "cpu":
        def waste_cpu():
            while _service_state["healthy"]:
                pass
        threading.Thread(target=waste_cpu, daemon=True).start()
        log(logging.WARNING, "CHAOS_CPU_SPIKE_STARTED")
        return {"message": "CPU spike initiated", "type": "cpu"}
    elif type == "memory":
        if not _service_state["leak_thread_active"]:
            _service_state["leak_thread_active"] = True
            def leak():
                while _service_state["leak_thread_active"]:
                    _leak_store.append(" " * 10_000)
                    time.sleep(0.05)
            threading.Thread(target=leak, daemon=True).start()
            log(logging.WARNING, "CHAOS_MEMORY_LEAK_STARTED")
        return {"message": "Memory leak initiated", "leak_store_size": len(_leak_store)}
    elif type == "unhealthy":
        _service_state["healthy"] = False
        log(logging.WARNING, "CHAOS_UNHEALTHY_STATE_SET")
        return {"message": "Service marked unhealthy — /health will return 503"}
    elif type == "recover":
        _service_state["healthy"] = True
        _service_state["leak_thread_active"] = False
        _leak_store.clear()
        recovery_ts = datetime.now(timezone.utc).isoformat()
        log(logging.INFO, "MANUAL_RECOVERY_APPLIED", recovery_ts=recovery_ts)
        return {"message": "Service manually recovered", "recovery_ts": recovery_ts}
    else:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown failure type '{type}'. Valid: crash, cpu, memory, unhealthy, recover"
        )