Gem::Specification.new do |spec|
  spec.name = "upwoof_llm_client"
  spec.version = "0.1.0"
  spec.authors = ["UpWoof Digital"]
  spec.summary = "Client for the upwoof-gpu-broker LLM queue"
  spec.description = "Enqueue LLM jobs onto the home-lab GPU broker and poll for results. " \
                     "See upwoof-gpu-broker for the broker itself."
  spec.homepage = "https://github.com/dior001/upwoof-llm-client"
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "redis", ">= 5.0"
end
