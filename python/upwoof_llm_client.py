"""Python mirror of the Ruby upwoof_llm_client gem — same wire format, same semantics.

For the non-Rails consumers (bat-country / fear-and-loathing assetgen tooling, ML scripts).
Deliberately one file with a single dependency (redis) so it can be vendored or pip-installed
straight from the repo.

    client = Client()
    job_id = client.enqueue(model="echo", payload={"q": "hi"}, priority="batch")
    result = client.await_result(job_id, timeout_s=600)
"""
from __future__ import annotations

import contextlib
import datetime
import json
import time
import uuid

import redis

INTERACTIVE_QUEUE = "llm:queue:interactive"
BATCH_QUEUE = "llm:queue:batch"
PRIORITIES = {"interactive": INTERACTIVE_QUEUE, "batch": BATCH_QUEUE}
DEFAULT_REDIS_URL = "redis://192.168.86.8:6390/0"


LEASE_KEY = "llm:gpu:lease"


class BrokerTimeout(Exception):
    """No result within the deadline — treat as signal-unavailable, not a hot-retry error."""


class LeaseUnavailable(Exception):
    """The GPU stayed busy for the whole wait window."""


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

    # --- GPU leases (for services the broker must not launch) ----------------------------
    #
    # hy3d is a long-lived container jobs `docker exec` into; pcsa-llm manages its own model
    # child process. Neither should become a broker-launched container, but both need mutual
    # exclusion against every other GPU workload:
    #
    #     with Client().gpu_lease(holder="hy3d"):
    #         run_the_generation()
    #
    # The broker's queue worker refuses to launch models while the lease is held.

    @contextlib.contextmanager
    def gpu_lease(self, *, holder: str, ttl_s: int = 300, wait_s: int = 900,
                  poll_interval_s: float = 2.0):
        token = self.acquire_gpu(holder=holder, ttl_s=ttl_s, wait_s=wait_s,
                                 poll_interval_s=poll_interval_s)
        try:
            yield token
        finally:
            self.release_gpu(token=token)

    def acquire_gpu(self, *, holder: str, ttl_s: int = 300, wait_s: int = 900,
                    poll_interval_s: float = 2.0) -> str:
        deadline = time.monotonic() + wait_s
        while True:
            token = str(uuid.uuid4())
            payload = json.dumps({
                "holder": holder, "token": token, "ttl_s": ttl_s,
                "acquired_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            })
            if self._redis.set(LEASE_KEY, payload, nx=True, ex=ttl_s):
                return token
            if time.monotonic() > deadline:
                raise LeaseUnavailable(f"GPU still busy after {wait_s}s")
            time.sleep(poll_interval_s)

    def heartbeat_gpu(self, *, token: str, ttl_s: int = 300) -> bool:
        """Extend a held lease. False means it is gone — stop using the GPU."""
        if not self._holding(token):
            return False
        self._redis.expire(LEASE_KEY, ttl_s)
        return True

    def release_gpu(self, *, token: str) -> bool:
        if not self._holding(token):
            return False
        self._redis.delete(LEASE_KEY)
        return True

    def _holding(self, token: str) -> bool:
        raw = self._redis.get(LEASE_KEY)
        if not raw:
            return False
        try:
            return json.loads(raw)["token"] == token
        except (json.JSONDecodeError, KeyError):
            return False
