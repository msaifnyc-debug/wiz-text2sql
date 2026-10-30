"""Configuration: Fireworks endpoint, model selection, and pricing.

Everything here is overridable via environment variables (a local `.env` file is
loaded automatically) so the same code works for any database/model without edits.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Dict

from dotenv import load_dotenv

load_dotenv()

# Fireworks exposes an OpenAI-compatible API.
FIREWORKS_BASE_URL = os.getenv(
    "FIREWORKS_BASE_URL", "https://api.fireworks.ai/inference/v1"
)
FIREWORKS_API_KEY = os.getenv("FIREWORKS_API_KEY")

# Primary model: cheapest reliable serverless tier on this account that still
# produces correct grounded SQL. Verified live (Oct 2026): glm-5p3-flash returned
# a clean JSON SELECT in ~0.8s using the fewest tokens of the cheap "flash" models,
# minimizing cost per query for this input-heavy / short-output workload.
# Failover is a different cheap family (deepseek flash, also verified) so the
# fallback ladder actually switches models on an error instead of retrying one.
# Upgrade PRIMARY to gpt-oss-120b (also available, stronger) if accuracy slips.
PRIMARY_MODEL = os.getenv(
    "FIREWORKS_MODEL", "accounts/fireworks/models/glm-5p3-flash"
)
FAST_MODEL = os.getenv(
    "FIREWORKS_FAST_MODEL", "accounts/fireworks/models/deepseek-v4p1-flash"
)

DB_PATH = os.getenv("DB_PATH", "data/Chinook.db")

# Generation defaults. Low temperature => deterministic, reproducible SQL.
TEMPERATURE = float(os.getenv("TEMPERATURE", "0.0"))
MAX_TOKENS = int(os.getenv("MAX_TOKENS", "1024"))
# Optional reasoning effort for reasoning models (e.g. gpt-oss): "low"|"medium"|"high".
# Empty => use the model default. "low" cuts output cost but we found it hurt
# accuracy on the dev set, so we leave it at the model default (quality first).
REASONING_EFFORT = os.getenv("REASONING_EFFORT", "")
MAX_REPAIR_ATTEMPTS = int(os.getenv("MAX_REPAIR_ATTEMPTS", "2"))
REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "30"))

# Cap rows returned to the user / used for verification to keep things snappy.
MAX_RESULT_ROWS = int(os.getenv("MAX_RESULT_ROWS", "100"))

CACHE_DIR = os.getenv("CACHE_DIR", ".cache")


@dataclass(frozen=True)
class ModelPricing:
    """USD per 1M tokens (input / output)."""

    input: float
    output: float


# Published Fireworks serverless pricing (USD / 1M tokens), June 2026.
# Used for the cost analysis. Update freely as pricing changes.
PRICING: Dict[str, ModelPricing] = {
    "accounts/fireworks/models/qwen2p5-coder-32b-instruct": ModelPricing(0.90, 0.90),
    "accounts/fireworks/models/qwen3-coder-480b-a35b-instruct": ModelPricing(0.45, 1.80),
    "accounts/fireworks/models/gpt-oss-120b": ModelPricing(0.15, 0.60),
    "accounts/fireworks/models/gpt-oss-20b": ModelPricing(0.07, 0.30),
    "accounts/fireworks/models/qwen3p7-plus": ModelPricing(0.40, 1.60),
    "accounts/fireworks/models/llama-v3p1-8b-instruct": ModelPricing(0.20, 0.20),
    "accounts/fireworks/models/llama-v3p1-70b-instruct": ModelPricing(0.90, 0.90),
}

# Baseline proprietary model the customer uses today, for cost comparison.
# Approximate GPT-5.4 list pricing (USD / 1M tokens).
BASELINE_MODEL_NAME = os.getenv("BASELINE_MODEL_NAME", "GPT-5.4")
BASELINE_PRICING = ModelPricing(
    input=float(os.getenv("BASELINE_INPUT_PRICE", "1.25")),
    output=float(os.getenv("BASELINE_OUTPUT_PRICE", "10.0")),
)

# Customer's stated scale for the cost model.
USERS = int(os.getenv("USERS", "1000"))
QUERIES_PER_USER_PER_DAY = int(os.getenv("QUERIES_PER_USER_PER_DAY", "30"))


def pricing_for(model: str) -> ModelPricing:
    """Return pricing for a model, defaulting to the >16B tier if unknown."""
    return PRICING.get(model, ModelPricing(0.90, 0.90))


def has_api_key() -> bool:
    return bool(FIREWORKS_API_KEY)
