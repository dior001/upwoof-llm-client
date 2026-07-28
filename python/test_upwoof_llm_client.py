import json

import pytest

from upwoof_llm_client import BATCH_QUEUE, INTERACTIVE_QUEUE, BrokerTimeout, Client


class FakeRedis:
    def __init__(self):
        self.lists = {}
        self.kv = {}

    def lpush(self, key, val):
        self.lists.setdefault(key, []).insert(0, val)

    def get(self, key):
        return self.kv.get(key)

    def set(self, key, val, nx=False, ex=None):
        if nx and key in self.kv:
            return False
        self.kv[key] = val
        return True

    def delete(self, key):
        return self.kv.pop(key, None) is not None

    def expire(self, key, _ttl):
        return key in self.kv


@pytest.fixture
def fake():
    return FakeRedis()


@pytest.fixture
def client(fake):
    return Client(redis_client=fake)


def test_enqueue_wire_format_and_default_priority(client, fake):
    job_id = client.enqueue(model="echo", payload={"q": "hi"})
    job = json.loads(fake.lists[INTERACTIVE_QUEUE][0])
    assert job["id"] == job_id
    assert job["model"] == "echo"
    assert job["payload"] == {"q": "hi"}


def test_enqueue_batch_and_unknown_priority(client, fake):
    client.enqueue(model="echo", payload=None, priority="batch")
    assert len(fake.lists[BATCH_QUEUE]) == 1
    with pytest.raises(ValueError):
        client.enqueue(model="echo", payload=None, priority="urgent")


def test_result_none_until_present(client, fake):
    assert client.result("abc") is None
    fake.kv["llm:result:abc"] = '{"status": "ok", "output": 42}'
    assert client.result("abc") == {"status": "ok", "output": 42}


def test_await_result_returns_or_times_out(client, fake):
    fake.kv["llm:result:abc"] = '{"status": "ok"}'
    assert client.await_result("abc", timeout_s=1, poll_interval_s=0) == {"status": "ok"}
    with pytest.raises(BrokerTimeout):
        client.await_result("never", timeout_s=0, poll_interval_s=0)


def test_gpu_lease_holds_then_releases(client, fake):
    from upwoof_llm_client import lease_key

    with client.gpu_lease(holder="hy3d"):
        assert json.loads(fake.kv[lease_key("njord")])["holder"] == "hy3d"
    assert lease_key("njord") not in fake.kv


def test_gpu_lease_releases_on_exception(client, fake):
    from upwoof_llm_client import lease_key

    with pytest.raises(RuntimeError):
        with client.gpu_lease(holder="hy3d"):
            raise RuntimeError("generation failed")
    assert lease_key("njord") not in fake.kv


def test_acquire_gpu_gives_up_when_busy(client):
    from upwoof_llm_client import LeaseUnavailable

    client.acquire_gpu(holder="pcsa-llm")
    with pytest.raises(LeaseUnavailable):
        client.acquire_gpu(holder="hy3d", wait_s=0, poll_interval_s=0)


def test_release_and_heartbeat_reject_foreign_token(client):
    client.acquire_gpu(holder="pcsa-llm")
    assert client.release_gpu(token="not-mine") is False
    assert client.heartbeat_gpu(token="not-mine") is False


def test_leases_are_scoped_per_gpu(client, fake):
    from upwoof_llm_client import lease_key

    client.acquire_gpu(holder="flux1", gpu="njord")
    # odin's 1080 shares nothing with njord's 3090 -- musicgen must not be blocked.
    assert client.acquire_gpu(holder="musicgen", gpu="odin", wait_s=0, poll_interval_s=0)
    assert lease_key("odin") in fake.kv
