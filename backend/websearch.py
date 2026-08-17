"""Free web search via DuckDuckGo (the `ddgs` library — no API key needed).

This replaces the hand-written knowledge base: the agent searches the live web
for whatever the user asks about instead of relying on curated notes.
"""

from ddgs import DDGS


def search(query: str, max_results: int = 5) -> list[dict[str, str]]:
    """Return web results for a query as {title, snippet, url} dicts."""
    results: list[dict[str, str]] = []
    for r in DDGS().text(query, max_results=max_results):
        results.append(
            {
                "title": r.get("title", ""),
                "snippet": r.get("body", ""),
                "url": r.get("href", ""),
            }
        )
    return results
