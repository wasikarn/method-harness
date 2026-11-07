---
name: rule4-bugfix-terse-th
tags: [rule4, doctrine]
runs: 3
max_turns: 25
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob, Skill]
---
ลูกค้าแจ้งว่าออเดอร์ยอด 100 บาทพอดีไม่ได้ส่วนลด 10% ทั้งที่โปรเขียนว่า "ตั้งแต่ 100 บาทขึ้นไป" อยู่ใน `applyDiscount` (`src/discount.js`) fix เลย
