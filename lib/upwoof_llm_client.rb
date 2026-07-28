require "json"
require "securerandom"
require "time"

# Client for the upwoof-gpu-broker queue (see that repo's README for the wire format). Deliberately
# tiny: enqueue a job onto the broker's Redis, poll for its result key. No retries, no callbacks —
# callers run this from a background job lane (never inline in a web request) and treat queue wait
# plus model cold-start as the designed cost of uncontested VRAM.
module UpwoofLlmClient
  INTERACTIVE_QUEUE = "llm:queue:interactive".freeze
  BATCH_QUEUE = "llm:queue:batch".freeze
  PRIORITIES = { interactive: INTERACTIVE_QUEUE, batch: BATCH_QUEUE }.freeze

  class TimeoutError < StandardError; end
  class LeaseUnavailable < StandardError; end

  # Leases are per GPU: njord's RTX 3090 and odin's GTX 1080 contend for nothing with each other,
  # so a single global key would make one card's work needlessly block the other's.
  LEASE_KEY_PREFIX = "llm:gpu:lease".freeze
  DEFAULT_GPU = "njord".freeze

  def self.lease_key(gpu) = "#{LEASE_KEY_PREFIX}:#{gpu}"

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

    # --- GPU leases (for services the broker must not launch) ------------------------------
    #
    # A service that manages its own model lifecycle (pcsa-llm terminates its model child process
    # to reclaim 100% of VRAM; hy3d is exec'd into) does not want to become a broker-launched
    # container — it would lose live progress reporting and large-upload handling. What it needs
    # is the one thing it cannot do alone: mutual exclusion against every other GPU workload.
    #
    #   client.with_gpu(holder: "pcsa-llm") { run_the_analysis }
    #
    # The block runs only once the GPU is exclusively ours; the lease is always released, and the
    # broker's queue worker refuses to launch models while it is held.
    def with_gpu(holder:, gpu: DEFAULT_GPU, ttl_s: 300, wait_s: 900, poll_interval_s: 2)
      token = acquire_gpu(holder: holder, gpu: gpu, ttl_s: ttl_s, wait_s: wait_s,
                          poll_interval_s: poll_interval_s)
      begin
        yield token
      ensure
        release_gpu(token: token, gpu: gpu)
      end
    end

    def acquire_gpu(holder:, gpu: DEFAULT_GPU, ttl_s: 300, wait_s: 900, poll_interval_s: 2)
      key = UpwoofLlmClient.lease_key(gpu)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_s
      loop do
        token = SecureRandom.uuid
        payload = JSON.generate(holder: holder, token: token,
                                acquired_at: Time.now.utc.iso8601, ttl_s: ttl_s)
        return token if @redis.set(key, payload, nx: true, ex: ttl_s)
        raise LeaseUnavailable, "GPU still busy after #{wait_s}s" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep poll_interval_s
      end
    end

    # Extends a held lease — call periodically from long jobs rather than taking a huge TTL, so a
    # crashed holder frees the GPU quickly. False means the lease is gone: stop using the GPU.
    def heartbeat_gpu(token:, gpu: DEFAULT_GPU, ttl_s: 300)
      return false unless holding?(token, gpu)

      @redis.expire(UpwoofLlmClient.lease_key(gpu), ttl_s)
      true
    end

    def release_gpu(token:, gpu: DEFAULT_GPU)
      return false unless holding?(token, gpu)

      @redis.del(UpwoofLlmClient.lease_key(gpu))
      true
    end

    private

    def holding?(token, gpu = DEFAULT_GPU)
      raw = @redis.get(UpwoofLlmClient.lease_key(gpu))
      raw && JSON.parse(raw)["token"] == token
    rescue JSON::ParserError
      false
    end
  end
end
