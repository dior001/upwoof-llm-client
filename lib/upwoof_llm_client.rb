require "json"
require "securerandom"

# Client for the upwoof-gpu-broker queue (see that repo's README for the wire format). Deliberately
# tiny: enqueue a job onto the broker's Redis, poll for its result key. No retries, no callbacks —
# callers run this from a background job lane (never inline in a web request) and treat queue wait
# plus model cold-start as the designed cost of uncontested VRAM.
module UpwoofLlmClient
  INTERACTIVE_QUEUE = "llm:queue:interactive".freeze
  BATCH_QUEUE = "llm:queue:batch".freeze
  PRIORITIES = { interactive: INTERACTIVE_QUEUE, batch: BATCH_QUEUE }.freeze

  class TimeoutError < StandardError; end

  class Client
    # redis: any object speaking lpush/get (a Redis instance in production, a fake in specs).
    # Kept injectable so consuming apps' suites never need a live broker.
    def initialize(redis: nil, redis_url: ENV.fetch("LLM_BROKER_REDIS_URL", "redis://192.168.86.8:6390/0"))
      @redis = redis || begin
        require "redis"
        Redis.new(url: redis_url)
      end
    end

    # Returns the job id immediately. priority :interactive for user-facing work, :batch for
    # asset/report generation that can wait behind it.
    def enqueue(model:, payload:, priority: :interactive, timeout_s: nil, id: SecureRandom.uuid)
      queue = PRIORITIES.fetch(priority) { raise ArgumentError, "unknown priority #{priority.inspect}" }
      @redis.lpush(queue, JSON.generate(id: id, model: model, payload: payload, timeout_s: timeout_s))
      id
    end

    # The parsed result hash ({"status" => "ok"|"error", "output" => ..., ...}) or nil if not ready.
    def result(id)
      raw = @redis.get("llm:result:#{id}")
      raw && JSON.parse(raw)
    end

    # Polls until the result lands. Raises UpwoofLlmClient::TimeoutError past the deadline — which
    # callers should treat as "signal unavailable this cycle", not as an error to retry hot.
    def await(id, timeout_s: 600, poll_interval_s: 2)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
      loop do
        found = result(id)
        return found if found
        raise TimeoutError, "no result for #{id} within #{timeout_s}s" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep poll_interval_s
      end
    end

    # Convenience: enqueue + await in one call, for callers already on a slow job lane.
    def call(model:, payload:, priority: :interactive, timeout_s: 600)
      id = enqueue(model: model, payload: payload, priority: priority, timeout_s: timeout_s)
      await(id, timeout_s: timeout_s + 60)
    end
  end
end
