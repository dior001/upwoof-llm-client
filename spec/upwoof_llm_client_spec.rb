require_relative "../lib/upwoof_llm_client"
require "json"

RSpec.describe UpwoofLlmClient::Client do
  let(:redis) do
    Class.new do
      attr_reader :lists, :kv

      def initialize
        @lists = Hash.new { |h, k| h[k] = [] }
        @kv = {}
      end

      def lpush(key, val) = @lists[key].unshift(val)
      def get(key) = @kv[key]
      def del(key) = @kv.delete(key)
      def expire(key, _ttl) = @kv.key?(key)

      def set(key, val, nx: false, ex: nil)
        return false if nx && @kv.key?(key)

        @kv[key] = val
        true
      end
    end.new
  end
  let(:client) { described_class.new(redis: redis) }

  describe "#enqueue" do
    it "pushes the wire format onto the interactive queue by default and returns the id" do
      id = client.enqueue(model: "echo", payload: { q: "hi" })
      job = JSON.parse(redis.lists[UpwoofLlmClient::INTERACTIVE_QUEUE].first)
      expect(job).to include("id" => id, "model" => "echo", "payload" => { "q" => "hi" })
    end

    it "routes :batch priority to the batch queue and rejects unknown priorities" do
      client.enqueue(model: "echo", payload: {}, priority: :batch)
      expect(redis.lists[UpwoofLlmClient::BATCH_QUEUE].length).to eq(1)
      expect { client.enqueue(model: "echo", payload: {}, priority: :urgent) }
        .to raise_error(ArgumentError, /unknown priority/)
    end
  end

  describe "#result" do
    it "returns nil until the result key exists, then the parsed hash" do
      expect(client.result("abc")).to be_nil
      redis.kv["llm:result:abc"] = '{"status":"ok","output":42}'
      expect(client.result("abc")).to eq("status" => "ok", "output" => 42)
    end
  end

  describe "#await" do
    it "returns as soon as the result lands" do
      redis.kv["llm:result:abc"] = '{"status":"ok"}'
      expect(client.await("abc", timeout_s: 1, poll_interval_s: 0)).to eq("status" => "ok")
    end

    it "raises TimeoutError past the deadline, for callers to treat as signal-unavailable" do
      expect { client.await("never", timeout_s: 0, poll_interval_s: 0) }
        .to raise_error(UpwoofLlmClient::TimeoutError)
    end
  end

  describe "GPU leases" do
    it "runs the block holding the lease and always releases it" do
      seen = nil
      client.with_gpu(holder: "pcsa-llm") { |token| seen = redis.get(UpwoofLlmClient::LEASE_KEY) }

      expect(JSON.parse(seen)["holder"]).to eq("pcsa-llm")
      expect(redis.get(UpwoofLlmClient::LEASE_KEY)).to be_nil
    end

    it "releases the lease even when the block raises" do
      expect { client.with_gpu(holder: "pcsa-llm") { raise "analysis blew up" } }
        .to raise_error("analysis blew up")
      expect(redis.get(UpwoofLlmClient::LEASE_KEY)).to be_nil
    end

    it "gives up after wait_s when another holder will not release" do
      client.acquire_gpu(holder: "hy3d")
      expect { client.acquire_gpu(holder: "pcsa-llm", wait_s: 0, poll_interval_s: 0) }
        .to raise_error(UpwoofLlmClient::LeaseUnavailable)
    end

    it "refuses to release or heartbeat a lease it does not hold" do
      client.acquire_gpu(holder: "hy3d")
      expect(client.release_gpu(token: "not-mine")).to be false
      expect(client.heartbeat_gpu(token: "not-mine")).to be false
    end
  end
end
