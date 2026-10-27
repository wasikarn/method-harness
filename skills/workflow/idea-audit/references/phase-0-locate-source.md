# idea-audit: Phase 0, locate the source

Load when check 3 has nothing to point at (a topic/tool/practice named with no URL, local file,
or pasted text attached).

1. **`qmd` MCP `query` with `collections: ["llm-wiki"]`, first.**
2. **If nothing usable there:** `firecrawl_developer_search` for a repo/library/tool name (or
   `firecrawl_search`/`WebSearch` for a general article or practice).
3. **Present the top 1-3 candidates** (title, URL, one-line snippet) and require an explicit pick
   from the user — never auto-fetch the top hit and proceed silently.
4. **Once picked,** the chosen URL/file re-enters check 3's URL/Local-file branches in Phase 1
   unchanged.
5. **If Phase 0 finds nothing plausible,** abort with check 3's original message: ask the user for
   the source directly.
