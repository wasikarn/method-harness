---
name: fx
description: Fixture.
when_to_use: never
disable-model-invocation: true
disable-model-invocation-reason: fixture
model_limitation: fixture
allowed-tools: Read
context: fork
agent: Explore
metadata:
  paths: nested keys are not top-level
  owner: fixture
---
Body line that looks like a key:
notakey: body text after the closing marker is not frontmatter
