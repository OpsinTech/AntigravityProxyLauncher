#!/usr/bin/env python3
"""
Antigravity Proxy Launcher - Provider Model Prober
===================================================
A standalone CLI tool to test and discover available LLM models for providers 
(e.g., CodeBuddy, DeepSeek, OfoxAI, etc.) and optionally sync them back to 
model_routing.json.

Usage Examples:
    python3 tools/probe_provider_models.py --provider codebuddy
    python3 tools/probe_provider_models.py --provider codebuddy --update
    python3 tools/probe_provider_models.py --endpoint copilot.tencent.com --api-key YOUR_KEY --api-path /v2/chat/completions
"""

import os
import sys
import json
import argparse
import time
import urllib.request
import urllib.error
import concurrent.futures
from pathlib import Path

DEFAULT_CONFIG_PATH = os.path.expanduser("~/.config/antigravity/model_routing.json")

# Built-in search grids per model family
MODEL_CANDIDATE_GRIDS = {
    "glm": [
        f"glm-{maj}.{min_}" for maj in range(3, 6) for min_ in range(0, 10)
    ] + ["glm-4-flash", "glm-4-plus", "glm-4-long", "glm-4-v", "codegeex-4"],

    "kimi": [
        f"kimi-k{maj}.{min_}" for maj in [1, 2, 3] for min_ in range(0, 10)
    ] + [f"kimi-k{maj}" for maj in [1, 2, 3]] + ["moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"],

    "deepseek": [
        f"deepseek-{v}{sub}"
        for v in ["v1", "v2", "v3", "v4"]
        for sub in ["", "-flash", "-pro", "-lite", "-chat", "-coder", "-base"]
    ] + ["deepseek-r1", "deepseek-reasoner"],

    "hunyuan": [
        "hy3", "hy-3", "hunyuan3", "hunyuan-3", "hy3-chat", "hy3-code", "hy3-pro", "hy3-lite",
        "hunyuan-chat", "hunyuan-code", "hunyuan-pro", "hunyuan-lite", "hunyuan-standard", "hunyuan-coder",
        "hy4", "hy-4", "hunyuan4", "hunyuan-4", "hy4-chat", "hy4-pro", "hy4-lite", "hy4-turbo",
        "hy4-preview", "hy4-preview-free", "hy4-preview-lite", "hy4-preview-pro", "hy4-preview-turbo",
        "hunyuan-4-preview", "hunyuan-4.0", "hunyuan-4.0-pro", "hunyuan-4.0-lite", "hunyuan-4.0-turbo",
        "hunyuan-t1", "hunyuan-turbo", "hunyuan-turboS", "hunyuan-2.0-instruct"
    ],

    "qwen": [
        "qwen-turbo", "qwen-plus", "qwen-max", "qwen-long", "qwen-coder-plus",
        "qwen2.5-coder-32b", "qwen2.5-72b-instruct", "qwen2.5-coder-7b", "qwen2.5-14b"
    ],

    "claude": [
        "claude-3-5-sonnet", "claude-3-7-sonnet", "claude-3-opus", "claude-3-5-haiku",
        "claude-sonnet-4-6", "claude-opus-4-6"
    ],

    "openai": [
        "gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-4", "gpt-3.5-turbo", "o1", "o3-mini"
    ]
}

def generate_candidate_list(extra_models=None):
    """Combines all family candidate grids into a deduplicated list."""
    candidates = set()
    for family in MODEL_CANDIDATE_GRIDS.values():
        candidates.update(family)
    if extra_models:
        candidates.update(extra_models)
    return sorted(list(candidates))

def load_provider_config(config_path, provider_id):
    """Loads provider config from model_routing.json."""
    if not os.path.exists(config_path):
        print(f"❌ Error: Config file not found at {config_path}")
        sys.exit(1)

    with open(config_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    providers = data.get("providers", [])
    matching = [p for p in providers if p.get("id") == provider_id]
    if not matching:
        print(f"❌ Error: Provider '{provider_id}' not found in {config_path}")
        available_ids = [p.get("id") for p in providers if p.get("id")]
        print(f"Available provider IDs: {', '.join(available_ids)}")
        sys.exit(1)

    provider = matching[0]
    endpoint = provider.get("api_endpoint", "")
    api_key = provider.get("api_key", "")
    options = provider.get("options", {})
    api_path = options.get("api_path", "/v1/chat/completions")
    existing_models = provider.get("models", [])

    return endpoint, api_key, api_path, existing_models, data

def test_model(model, full_url, api_key, timeout=5):
    """Sends a minimal streaming request to probe model existence."""
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}" if api_key else ""
    }
    body = {
        "model": model,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 1,
        "stream": True
    }
    req = urllib.request.Request(
        full_url,
        data=json.dumps(body).encode("utf-8"),
        headers={k: v for k, v in headers.items() if v},
        method="POST"
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read(250).decode("utf-8", errors="ignore")
            return model, resp.status, True, data[:100]
    except urllib.error.HTTPError as e:
        err_text = e.read().decode("utf-8", errors="ignore")
        return model, e.code, False, err_text[:120]
    except Exception as e:
        return model, -1, False, str(e)[:100]

def main():
    parser = argparse.ArgumentParser(
        description="Probe available models for a provider endpoint and sync config."
    )
    parser.add_argument("-p", "--provider", default="codebuddy", help="Provider ID in model_routing.json (default: codebuddy)")
    parser.add_argument("-c", "--config", default=DEFAULT_CONFIG_PATH, help="Path to model_routing.json")
    parser.add_argument("-e", "--endpoint", help="Override API endpoint (e.g. copilot.tencent.com)")
    parser.add_argument("-k", "--api-key", help="Override API key")
    parser.add_argument("--api-path", help="Override API path (e.g. /v2/chat/completions)")
    parser.add_argument("-u", "--update", action="store_true", help="Auto-update model_routing.json with discovered models")
    parser.add_argument("--concurrency", type=int, default=15, help="Parallel testing threads (default: 15)")
    parser.add_argument("--timeout", type=int, default=5, help="HTTP request timeout in seconds (default: 5)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Print failed model probe details")

    args = parser.parse_args()

    full_config_data = None
    existing_models = []

    if args.endpoint and args.api_key:
        endpoint = args.endpoint
        api_key = args.api_key
        api_path = args.api_path or "/v1/chat/completions"
    else:
        endpoint, api_key, api_path, existing_models, full_config_data = load_provider_config(
            args.config, args.provider
        )

    # Format host URL
    host = endpoint.strip().rstrip("/").removeprefix("https://").removeprefix("http://")
    full_url = f"https://{host}{api_path}"

    print("=" * 60)
    print(f"🔍 Provider Model Prober")
    print(f"   Target URL : {full_url}")
    print(f"   Provider   : {args.provider}")
    print(f"   API Key    : {'*****' + api_key[-6:] if len(api_key) > 6 else ('[SET]' if api_key else '[NONE]')}")
    print("=" * 60)

    candidates = generate_candidate_list(existing_models)
    print(f"⚡ Testing {len(candidates)} candidate model names (concurrency={args.concurrency})...\n")

    start_time = time.time()
    valid_models = []
    failed_models = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        future_map = {
            executor.submit(test_model, m, full_url, api_key, args.timeout): m
            for m in candidates
        }
        for future in concurrent.futures.as_completed(future_map):
            model, status, ok, info = future.result()
            if ok:
                valid_models.append((model, status, info))
                print(f"  ✅ [AVAILABLE]  {model:24s} (HTTP {status})")
            else:
                failed_models.append((model, status, info))
                if args.verbose:
                    print(f"  ❌ [UNAVAILABLE] {model:24s} (HTTP {status}) -> {info}")

    valid_models.sort(key=lambda x: x[0])
    elapsed = time.time() - start_time

    print("\n" + "=" * 60)
    print(f"📊 PROBE SUMMARY (Completed in {elapsed:.2f}s)")
    print(f"   Tested     : {len(candidates)}")
    print(f"   Available  : {len(valid_models)}")
    print(f"   Failed     : {len(failed_models)}")
    print("=" * 60)

    print("\n🌟 Available Models Found:")
    valid_ids = [m for m, _, _ in valid_models]
    for model_id in valid_ids:
        print(f"   - {model_id}")

    if args.update and full_config_data:
        print("\n💾 Updating model_routing.json...")
        for p in full_config_data.get("providers", []):
            if p.get("id") == args.provider:
                p["models"] = valid_ids
                break
        
        with open(args.config, "w", encoding="utf-8") as f:
            json.dump(full_config_data, f, indent=2, ensure_ascii=False)
        print(f"✅ Successfully updated '{args.provider}' models in {args.config}!")

if __name__ == "__main__":
    main()
