---
title: Add a Framework
weight: 1
---

Adding a framework to HttpArena takes a few steps: create a Dockerfile, add metadata, implement the required endpoints, and open a PR.

{{< cards >}}
  {{< card link="directory-structure" title="Directory Structure" subtitle="How to organize your framework's files — Dockerfile, meta.json, and source code." icon="folder" >}}
  {{< card link="test-profiles" title="Test Profiles" subtitle="All HTTP endpoints your framework must implement, organized by test profile." icon="code" >}}
  {{< card link="meta-json" title="meta.json" subtitle="Framework metadata — display name, language, type, and which tests to participate in." icon="document-text" >}}
  {{< card link="implementation-rules" title="Implementation Rules" subtitle="Rules for keeping benchmarks realistic — use framework APIs, production settings only, standard libraries." icon="shield-check" >}}
  {{< card link="testing" title="Testing & Submitting" subtitle="How to validate your implementation locally and submit a pull request." icon="check-circle" >}}
  {{< card link="ci" title="CI & Runner" subtitle="GitHub Actions workflows and the self-hosted benchmark runner." icon="cog" >}}
{{< /cards >}}
