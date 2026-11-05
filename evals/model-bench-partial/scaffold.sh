#!/usr/bin/env bash
# Two finished aggregate-result.json files (copied from tests/scripts/fixtures/model-bench/).
mkdir -p bench/haiku bench/sonnet
cat > bench/haiku/aggregate-result.json <<'FIXTURE_EOF'
{
  "schemaVersion": 1,
  "costUsd": 1.25,
  "claudeVersion": "2.1.270",
  "partial": false,
  "suite": {
    "judgeModel": "sonnet",
    "caseFilter": "model-bench-fixture",
    "ablation": "none",
    "plugins": [{"name": "mh", "version": "1.1.94"}]
  },
  "aggregates": {"overallScore": 0.75, "overallPassRate": 0.5, "casesTotal": 3},
  "cases": [
    {
      "name": "shared-skill-case",
      "promptMarkdown": "Run /mh:cost-report and report the total.",
      "aggregates": {"score": 0.9, "passRate": 1.0}
    },
    {
      "name": "shared-agent-case",
      "promptMarkdown": "Dispatch mh:ideate-critic via the Agent tool with subagent_type: \"mh:ideate-critic\".",
      "aggregates": {"score": 0.6, "passRate": 0.5}
    },
    {
      "name": "only-in-a",
      "promptMarkdown": "Skill-only case unique to fixture A.",
      "aggregates": {"score": 0.75, "passRate": 0.5}
    }
  ]
}
FIXTURE_EOF
cat > bench/sonnet/aggregate-result.json <<'FIXTURE_EOF'
{
  "schemaVersion": 1,
  "costUsd": 5.0,
  "claudeVersion": "2.1.270",
  "partial": true,
  "partialReason": "test-interrupted",
  "suite": {
    "judgeModel": "sonnet",
    "caseFilter": "model-bench-fixture",
    "ablation": "none",
    "plugins": [{"name": "mh", "version": "1.1.94"}]
  },
  "aggregates": {"overallScore": 0.5, "overallPassRate": 0.5, "casesTotal": 1},
  "cases": [
    {
      "name": "shared-skill-case",
      "promptMarkdown": "Run /mh:cost-report and report the total.",
      "aggregates": {"score": 0.5, "passRate": 0.5}
    }
  ]
}
FIXTURE_EOF
