{ config, pkgs, lib, ... }:

let
  STATE_DIR = "/var/lib/claude-os";
  ollamaSkill = pkgs.writeText "ollama.skill.md" ''
    ---
    package: ollama
    version: auto
    capabilities: [local-inference, llm, embeddings, vision, code-generation]
    requires: []
    ---

    # ollama

    ## What it does
    Run large language models locally on this machine. Supports LLaMA, Mistral,
    CodeLlama, Phi, Gemma, and many others. Models run on GPU (CUDA/Vulkan) or CPU.

    ## Common tasks

    ### List available models
    ```bash
    ollama list
    ```

    ### Pull a model
    ```bash
    ollama pull llama3.2          # 3B general purpose
    ollama pull codellama:13b     # Code generation
    ollama pull nomic-embed-text  # Embeddings
    ollama pull llava             # Vision (image understanding)
    ollama pull mistral           # 7B general purpose
    ollama pull phi3:mini         # 3.8B, fast, good for small tasks
    ```

    ### Run interactive chat
    ```bash
    ollama run llama3.2
    ollama run codellama "Write a Python function to parse CSV"
    ```

    ### API usage (for programmatic access)
    ```bash
    # Generate
    curl http://localhost:11434/api/generate -d '{
      "model": "llama3.2",
      "prompt": "Explain recursion",
      "stream": false
    }'

    # Chat
    curl http://localhost:11434/api/chat -d '{
      "model": "llama3.2",
      "messages": [{"role": "user", "content": "Hello"}],
      "stream": false
    }'

    # Embeddings
    curl http://localhost:11434/api/embed -d '{
      "model": "nomic-embed-text",
      "input": "text to embed"
    }'
    ```

    ### List running models
    ```bash
    ollama ps
    ```

    ## When to use
    - User needs local/private LLM inference (no API key needed)
    - Generating embeddings for semantic search
    - Code generation assistance
    - Image understanding (with llava)
    - When offline or API-limited
    - Batch processing text (summarization, extraction, classification)

    ## Model selection guide
    | Model | Size | Best for |
    |-------|------|----------|
    | phi3:mini | 3.8B | Fast tasks, limited VRAM |
    | llama3.2 | 3B | General purpose, balanced |
    | llama3.2:70b | 70B | Best quality (needs lots of VRAM) |
    | codellama:13b | 13B | Code generation |
    | mistral | 7B | General, good quality/speed ratio |
    | nomic-embed-text | 137M | Embeddings only |
    | llava | 7B | Vision + text |

    ## Gotchas
    - First `ollama pull` downloads the model (can be several GB)
    - Models are stored in /var/lib/ollama/models/
    - GPU acceleration is automatic if CUDA/Vulkan is available
    - Check GPU usage: `nvidia-smi` (NVIDIA) or `ollama ps`
    - API runs on localhost:11434 — not exposed externally by default
    - For large models, ensure sufficient VRAM or RAM
  '';

in
{
  # Enable ollama as a systemd service
  services.ollama = {
    enable = true;
    host = "127.0.0.1";
    port = 11434;

    # Models stored in persistent state
    home = "/var/lib/ollama";

    # Default to CPU package (nvidia.nix overrides to ollama-cuda)
    package = lib.mkDefault pkgs.ollama;

    # Environment
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "5m";
    };
  };

  # Install the skill file on boot
  systemd.services.claude-os-ollama-skill = {
    description = "Install Ollama skill file";
    wantedBy = [ "multi-user.target" ];
    after = [ "claude-os-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "claude";
      Group = "users";
    };
    script = ''
      mkdir -p ${STATE_DIR}/skills
      cp ${ollamaSkill} ${STATE_DIR}/skills/ollama.skill.md

      # Register ollama as a capability in the genome
      if [ -f ${STATE_DIR}/genome/manifest.json ]; then
        # Add local-inference capability if not present
        if ! ${pkgs.jq}/bin/jq -e '.capabilities | index("local-inference")' ${STATE_DIR}/genome/manifest.json >/dev/null 2>&1; then
          tmp=$(mktemp)
          ${pkgs.jq}/bin/jq '.capabilities += ["local-inference","llm","embeddings"]' \
            ${STATE_DIR}/genome/manifest.json > "$tmp" && mv "$tmp" ${STATE_DIR}/genome/manifest.json
        fi
        # Add ollama to skills
        if ! ${pkgs.jq}/bin/jq -e '.skills | index("ollama")' ${STATE_DIR}/genome/manifest.json >/dev/null 2>&1; then
          tmp=$(mktemp)
          ${pkgs.jq}/bin/jq '.skills += ["ollama"]' \
            ${STATE_DIR}/genome/manifest.json > "$tmp" && mv "$tmp" ${STATE_DIR}/genome/manifest.json
        fi
      fi
    '';
  };

}
