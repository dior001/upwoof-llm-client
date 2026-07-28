"""Python mirror of the Ruby upwoof_llm_client gem — same wire format, same semantics.

For the non-Rails consumers (bat-country / fear-and-loathing assetgen tooling, ML scripts).
Deliberately one file with a single dependency (redis) so it can be vendored or pip-installed
straight from the repo.

    client = Client()
    job_id = client.enqueue(model="echo", payload={"q": "hi"}, priority="batch")
    result = client.await_result(job_id, timeout_s=600)
"""
from __future__ import annotations

import json
import time
import uuid

import redis

INTERACTIVE_QUEUE = "llm:queue:interactive"
BATCH_QUEUE = "llm:queue:batch"
PRIORITIES = {"interactive": INTERACTIVE_QUEUE, "batch": BATCH_QUEUE}
DEFAULT_REDIS_URL = "redis://192.168.86.8:6390/0"


class BrokerTimeout(Exception):
    """No result within the deadline — treat as signal-unavailable, not a hot-retry error."""


class Client:
    def __init__(self, redis_client=None, redis_url: str = DEFAULT_REDIS_URL):
        self._redis = redis_client or redis.Redis.from_url(redis_url, decode_responses=True)

    def enqueue(self, *, model: str, payload, priority: str = "interactive",
                timeout_s: int | None = None, job_id: str | None = None) -> str:
        try:
            queue = PRIORITIES[priority]
        except KeyError:
            raise ValueError(f"unknown priority {priority!r}") from None
        job_id = job_id or str(uuid.uuid4())
        self._redis.lpush(queue, json.dumps(
            {"id": job_id, "model": model, "payload": payload, "timeout_s": timeout_s}))
        return job_id

    def result(self, job_id: str):
        raw = self._redis.get(f"llm:result:{job_id}")
        return json.loads(raw) if raw else None

    def await_result(self, job_id: str, timeout_s: int = 600, poll_interval_s: float = 2.0):
        deadline = time.monotonic() + timeout_s
        while True:
            found = self.result(job_id)
            if found is not None:
                return found
            if time.monotonic() > deadline:
                raise BrokerTimeout(f"no result for {job_id} within {timeout_s}s")
            time.sleep(poll_interval_s)

    def call(self, *, model: str, payload, priority: str = "interactive", timeout_s: int = 600):
        job_id = self.enqueue(model=model, payload=payload, priority=priority, timeout_s=timeout_s)
        return self.await_result(job_id, timeout_s=timeout_s + 60)
