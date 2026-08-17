"""A small DevOps/cloud explainer agent built on Azure OpenAI (GPT).

It runs a manual agentic loop: the model decides when to call the knowledge-base
tools (OpenAI function calling), we execute them, feed results back, and repeat
until the model produces a final answer. Keeping the loop explicit makes the
"agentic" part easy to follow.
"""

import json
import os

from openai import AzureOpenAI

import websearch

# On Azure OpenAI the "model" is the *deployment name* you chose when you
# deployed the GPT model in your Azure OpenAI resource. Set AZURE_OPENAI_DEPLOYMENT
# to match it. gpt-4o-mini is a good low-cost default.
DEPLOYMENT = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4o-mini")
# Reasoning models (gpt-5, o-series) spend part of this budget on internal
# reasoning before the visible answer, so keep it generous or the answer can
# come back empty.
MAX_TOKENS = int(os.environ.get("OPENAI_MAX_TOKENS", "4000"))
API_VERSION = os.environ.get("AZURE_OPENAI_API_VERSION", "2024-10-21")
# Optional (gpt-5 / o-series only, needs a recent API version): "minimal",
# "low", "medium", or "high". Lower = less reasoning, faster, cheaper.
REASONING_EFFORT = os.environ.get("OPENAI_REASONING_EFFORT")
MAX_TOOL_ROUNDS = 5

SYSTEM_PROMPT = (
    "You are a friendly DevOps and cloud engineering tutor. You explain cloud "
    "computing and DevOps concepts clearly for people who are learning. "
    "Use the web_search tool to find current, accurate information before "
    "answering — especially for anything version-specific, recent, or that you "
    "are unsure about. Base your answer on the search results and mention the "
    "source links when helpful. Keep answers concise, practical, and "
    "beginner-friendly. Use short paragraphs or bullet points, and give a "
    "concrete example when it helps."
)

# OpenAI function-calling tool definitions.
TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": (
                "Search the web for current information on a topic or question. "
                "Use this to ground your explanation in up-to-date sources "
                "before answering."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "The search query.",
                    }
                },
                "required": ["query"],
            },
        },
    },
]

# The client talks to a GPT model hosted on Azure OpenAI — no Anthropic key,
# no AWS. Credentials resolve from the environment:
#   AZURE_OPENAI_ENDPOINT  -> https://<your-resource>.openai.azure.com/
#   AZURE_OPENAI_API_KEY   -> your Azure OpenAI key
# Built lazily so the app still imports (e.g. for /health) before creds are set.
_client: AzureOpenAI | None = None


def _get_client() -> AzureOpenAI:
    global _client
    if _client is None:
        _client = AzureOpenAI(
            azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
            api_key=os.environ["AZURE_OPENAI_API_KEY"],
            api_version=API_VERSION,
        )
    return _client


def _run_tool(name: str, tool_input: dict) -> str:
    """Execute a tool call and return a string result for the model."""
    if name == "web_search":
        try:
            results = websearch.search(tool_input.get("query", ""))
        except Exception as exc:  # network/search failure — let the model cope
            return f"Web search failed: {exc}. Answer from general knowledge."
        if not results:
            return "No results found. Answer from general knowledge."
        return "\n\n".join(
            f"{r['title']}\n{r['snippet']}\nSource: {r['url']}" for r in results
        )
    return f"Unknown tool: {name}"


def ask(question: str) -> str:
    """Answer a single question by running the agentic tool loop."""
    client = _get_client()
    messages: list[dict] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": question},
    ]

    for _ in range(MAX_TOOL_ROUNDS):
        create_kwargs: dict = {
            "model": DEPLOYMENT,
            "messages": messages,
            "tools": TOOLS,
            "max_completion_tokens": MAX_TOKENS,
        }
        if REASONING_EFFORT:
            create_kwargs["reasoning_effort"] = REASONING_EFFORT

        response = client.chat.completions.create(**create_kwargs)
        message = response.choices[0].message

        if not message.tool_calls:
            # The model produced its final answer.
            answer = (message.content or "").strip()
            if not answer:
                return (
                    "The model returned an empty answer — it likely used the "
                    "whole token budget on internal reasoning. Increase "
                    "OPENAI_MAX_TOKENS (or set OPENAI_REASONING_EFFORT=low)."
                )
            return answer

        # Append the assistant turn (with tool_calls), then run each requested
        # tool and send the results back — one "tool" message per call.
        messages.append(message.model_dump(exclude_none=True))
        for call in message.tool_calls:
            try:
                args = json.loads(call.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {}
            result = _run_tool(call.function.name, args)
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result,
                }
            )

    return (
        "I wasn't able to finish answering within the tool-call limit. "
        "Please try rephrasing your question."
    )
