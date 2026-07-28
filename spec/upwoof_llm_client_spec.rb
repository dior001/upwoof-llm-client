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
end
