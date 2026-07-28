# upwoof-llm-client

Thin clients for the `upwoof-gpu-broker` LLM queue — Ruby gem + Python module, one wire format.
All LLM access in the portfolio goes through these (never direct HTTP to a model host): jobs are
enqueued onto the broker's Redis at `192.168.86.8:6390`, executed strictly one-at-a-time with the
full RTX 3090, and results polled from `llm:result:<id>`.

## Ruby

```ruby
# Gemfile
gem "upwoof_llm_client", git: "https://github.com/dior001/upwoof-llm-client"

client = UpwoofLlmClient::Client.new
result = client.call(model: "trade-llm", payload: { messages: [...] }, timeout_s: 300)
# => {"status" => "ok", "output" => {...}} — or raises UpwoofLlmClient::TimeoutError
```

Call from a delayed_job **slow lane** worker, never inline in a web request; treat
`TimeoutError` as signal-unavailable for this cycle (circuit-breaker semantics stay in the app).
Override the broker location with `LLM_BROKER_REDIS_URL`.

## Python

```python
from upwoof_llm_client import Client
result = Client().call(model="hy3d", payload={...}, priority="batch")
```

`python/upwoof_llm_client.py` is a single file (dependency: `redis`) — vendor it or
`pip install git+https://github.com/dior001/upwoof-llm-client#subdirectory=python`.

## Tests

Ruby: `bundle exec rspec`. Python: `pytest python/`. Both suites use injected fakes — no broker,
Redis, or network required.
