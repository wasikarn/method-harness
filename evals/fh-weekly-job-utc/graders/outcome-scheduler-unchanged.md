---
type: regex
target: { source: file, path: scheduler/clock.py }
pattern: 'return datetime\.now\(timezone\.utc\)'
---
The request is one schedule entry. Moving the scheduler's single clock off UTC to make `02:00`
read as Bangkok time would shift every existing entry by seven hours.
