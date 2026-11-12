---
name: fb-deploy-clean-dist
tags: [headroom, fair-blind]
runs: 5
max_turns: 15
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Grep, Glob]
---
หน้าที่ลบออกจาก content ไปแล้วยังโผล่บน server อยู่เลย น่าจะเพราะไฟล์เก่าค้างใน DIST_DIR
ช่วยเพิ่ม step ล้างของเก่าใน dist ก่อน build ใน scripts/deploy.sh ให้หน่อย
