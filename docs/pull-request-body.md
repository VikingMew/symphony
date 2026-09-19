---
title: Pull Request Body Contract
genre: reference
domain: [governance, github]
status: current
language: en
owner: Mix.Tasks.PrBody.Check
updated: 2026-09-19
---

# Pull Request Body Contract

This file owns the repository's pull request body contract. `Summary` and `Test Plan` are the only
required sections. Optional context or alternatives belong before `Summary` or between `Summary`
and `Test Plan`, respectively, and should be omitted when they add no information.

The content between the template markers is the canonical GitHub entry template. Summary entries
MUST be bullets, Test Plan entries MUST be checkboxes, and both sections MUST be non-empty after
replacing the comments. The body MUST end with an independent, exact Linear closing-reference line
in the form `Fixes SYM-123`.

For implementation handoff, Codex supplies the completed title and body to the restricted
`create_pull_request` tool after commit, validation, and branch push. Symphony owns the tool backend,
credential isolation, exact repository/base/head lookup, and gh-first/REST-fallback creation.

An optional `#### Docs Drift Exemption` section is permitted between `Summary` and `Test Plan`.
Its heading must be exactly that line, without leading or trailing spaces. The next non-empty line
must be `Reason: <non-empty text>` with a non-whitespace reason. This section is optional and is
intentionally absent from the required template below. The advisory check and exact exemption
semantics belong to [the documentation-system design](documentation-system-design.md#pr-change-linkage-signal).

<!-- pr-body-template:start -->
#### Summary

- <!-- Describe a completed change. -->

#### Test Plan

- [ ] <!-- Record a validation command or check. -->

Fixes SYM-XX
<!-- pr-body-template:end -->
