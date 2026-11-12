---
name: hr-bugfix-terse-th-pagination
tags: [headroom, bugfix]
runs: 5
max_turns: 20
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
export ออเดอร์ได้ไม่ครบ `python3 export.py orders.json` บอก 100 of 123 ออเดอร์ท้าย ๆ หายไป แก้ทีครับ
