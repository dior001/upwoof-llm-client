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
