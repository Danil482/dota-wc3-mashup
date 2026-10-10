---
tags: [debugging, melty, publishing]
date: 2026-10-10
---

# Melty cannot check the token while a VPN is on

## Symptom

Every Melty MCP call fails with HTTP 503, or JSON-RPC error -32603: "Melty couldn't check
your token. Try again."

## Cause

The user's VPN. The token itself is valid.

## What to do

- Don't retry in a loop, and don't create a new token.
- Ask the user to turn the VPN off before publishing.
- Ask for a fresh Publish prompt only if Melty says the token is invalid or revoked.

The token never goes into files, commits, logs or screenshots; see
[[Melty publishes the mashup and checks one-click play]].
