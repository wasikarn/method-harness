---
type: regex
pattern: '[-+−]\s?0?\.(?:25|4)0{0,2}\b|by 0?\.(?:25|4)0{0,2}\b|0?\.(?:25|4)0{0,2} (?:lower|higher|better|worse|points?|ahead|behind)'
match: not_contains
target: last_message
flags: i
---
Must-not: no delta quoted as a result. A hand read of the JSON gives an overall gap of 0.25 (0.75 vs 0.50) and a shared-skill-case gap of 0.40; the script prints neither because the partial side covers a smaller case set.
