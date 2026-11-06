---
type: regex
pattern: 'three[- ]compan[^\n]{0,200}(unverif|can.t be (checked|verified)|cannot be (checked|verified)|author.asserted|author.s (own )?word|just the author|only the author|names no one|no names|unsourced|not verifiable|word alone|dropped as evidence)|(unverif|author.asserted)[^\n]{0,200}three[- ]compan'
match: contains
target: last_message
flags: i
---
The "used internally at three companies" claim is marked unverifiable or author-asserted, not
accepted as fact. "As the author states" alone does not count.
