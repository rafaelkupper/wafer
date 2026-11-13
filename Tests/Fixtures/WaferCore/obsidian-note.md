---
title: "Obsidian Fixture"
tags:
  - notes
  - markdown
---

This note has metadata, a bare URL https://example.com/vault, a known emoji :rocket:, and ==highlight syntax== that renders in Tier 2.

> A normal blockquote should remain a blockquote, not a GitHub alert.

- Parent item
  - Nested item with `inline code`
  - Nested item with a [reference link][ref]

[ref]: https://example.com/reference

## Vault Links

Wiki links to [[Another Note]] and [[Another Note|an alias]] plus [[Guide#Setup]] should render as unresolved spans in golden renders, and a same-doc [[#Vault Links]] link resolves locally.
