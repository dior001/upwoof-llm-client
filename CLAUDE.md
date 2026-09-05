# upwoof-llm-client

Thin clients for the `upwoof-gpu-broker` LLM queue — a Ruby gem and a Python module sharing one
wire format.

## The rule this repo exists to enforce

**All LLM access in the portfolio goes through these clients — never direct HTTP to a model
host.** Jobs are enqueued onto the broker's Redis at `192.168.86.8:6390` and executed strictly
one at a time, which is what guarantees a single model owns the RTX 3090. A caller that bypasses
the queue breaks that guarantee for everyone else on the card.

If a caller seems to need a direct HTTP call, that is a signal the broker is missing a feature —
add it there rather than routing around it.

## Stack

`lib/` the Ruby gem, `python/` the Python module, `spec/` the tests. Both must speak the same
wire format; change them together.

```bash
bundle install && bundle exec rspec
```

## Related

`upwoof-gpu-broker` is the server side. `upwoof-tohora-server-tools/docs/fleet-ports.md` records
the broker's fixed ports.
