---
type: regex
pattern: '\bnot just\b|in conclusion|hope this helps|let me know'
match: not_contains
flags: i
target: last_message
---
The planted "It's not just X" parallelism, the "In conclusion" closer and the chatbot sign-offs are
gone. Replaces part of the llm `criteria` grader (GH #921), which failed a clean reply 3/3.
Limit: a reworded closer ("To sum up") is not caught.
