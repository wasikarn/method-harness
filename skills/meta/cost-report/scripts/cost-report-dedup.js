#!/usr/bin/env node
// cost-report-dedup.js — the mh:cost-report skill's report + CSV logic.
// Lives beside SKILL.md (moved from scripts/workflows/ 2026-09-07) so the skill
// reaches it through ${CLAUDE_SKILL_DIR}, which is set wherever the skill loads;
// tests/skills/test-cost-report.sh runs this same file. Old rows may carry extra
// fields from retired schemas; unknown keys are ignored. Data model and the dedup
// rule: ../references/data-model.md.
// Usage: node cost-report-dedup.js        -> summary report
//        node cost-report-dedup.js csv    -> CSV of the last 100 raw rows
// MH_COSTS_FILE=<path> overrides the log location (tests and evals plant a fixture).
const fs=require("fs"),os=require("os"),path=require("path");
const f=process.env.MH_COSTS_FILE||path.join(os.homedir(),".local","share","kbg","metrics","costs.jsonl");

if(process.argv[2]==="csv"){
  if(!fs.existsSync(f)){console.error("no data");process.exit(0);}
  // Tail-read: double the window until it holds 100 parsable rows or the whole file (was: read
  // the whole log). The window's first line may be cut mid-row, so it is dropped unless len==size.
  const size=fs.statSync(f).size,fd=fs.openSync(f,"r");let n=256*1024,rows;
  for(;;){
    const len=Math.min(n,size),buf=Buffer.alloc(len);fs.readSync(fd,buf,0,len,size-len);
    const lines=buf.toString("utf8").split(/\r?\n/);if(len<size)lines.shift();
    rows=lines.filter(Boolean).map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
    if(rows.length>=100||len>=size)break;n*=2;
  }
  fs.closeSync(fd);rows=rows.slice(-100);
  console.log("timestamp,session_id,model,model_scoped,stream,agent_type,turns,input_tokens,output_tokens,cache_write_tokens,cache_write_tokens_1h,cache_read_tokens,cache_read_per_turn,estimated_cost_usd");
  for(const r of rows)console.log([r.timestamp,r.session_id,r.model,r.model_scoped===true,r.stream||"",r.agent_type||"",r.turns||"",r.input_tokens,r.output_tokens,r.cache_write_tokens,r.cache_write_tokens_1h,r.cache_read_tokens,r.cache_read_per_turn||"",r.estimated_cost_usd].join(","));
  process.exit(0);
}

if(!fs.existsSync(f)){console.log("Cost tracker not set up: "+f+" not found. Enable the stop:cost-tracker hook and finish a session first.");process.exit(0);}
const rows=fs.readFileSync(f,"utf8").split(/\r?\n/).filter(Boolean).map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
// jq_failed sentinel rows (cost-tracker's emit_rows fallback) carry no spend; they used to
// reach `latest` as a $0 row and count as a session (2026-09-21). Tallied per session and
// warned about below instead.
const sentinels=new Map();
const bySession=new Map();
for(const r of rows){if(r.codex_invocations)continue;const k=r.session_id||r.transcript_path||r.timestamp;if(r.error==="jq_failed"){sentinels.set(k,(sentinels.get(k)||0)+1);continue;}if(!bySession.has(k))bySession.set(k,[]);bySession.get(k).push(r);}
const latest=[];
for(const rs of bySession.values()){
  const scoped=rs.filter(r=>r.model_scoped===true);
  if(scoped.length){
    const byModel=new Map();
    for(const r of scoped){const k=(r.stream||"orchestrator")+" "+(r.model||"")+" "+(r.agent_type||"");const p=byModel.get(k);if(!p||String(r.timestamp)>String(p.timestamp))byModel.set(k,r);}
    latest.push(...byModel.values());
  }else{
    let best=null;
    for(const r of rs){if(!best||String(r.timestamp)>String(best.timestamp))best=r;}
    if(best)latest.push(best);
  }
}
const cost=r=>Number(r.estimated_cost_usd)||0;
const fmtLocal=dt=>dt.getFullYear()+"-"+String(dt.getMonth()+1).padStart(2,"0")+"-"+String(dt.getDate()).padStart(2,"0");
const day=r=>fmtLocal(new Date(r.timestamp));
const today=fmtLocal(new Date());
const d=fmtLocal(new Date(Date.now()-864e5));
const sum=a=>a.reduce((s,r)=>s+cost(r),0);
const f4=n=>"$"+n.toFixed(4);
console.log("=== Cost summary ===");
for(const [k,n] of sentinels)console.log("warning: "+n+" jq_failed sentinel rows for session "+String(k).slice(0,8)+" — that session's spend is unknown, not zero (see hooks/stop/cost-tracker.sh emit_rows)");
// Two eras (2026-09-04): rows without dedup_usage summed one line per content block, ~2.4x high on
// turns/tokens; dedup_usage rows without usage_pick:"last" (v0.68.639) kept the first line per
// message.id, whose output_tokens is a streaming placeholder — ~39% low on output_tokens.
const inflated=latest.filter(r=>r.dedup_usage!==true).length;
const outLow=latest.filter(r=>r.dedup_usage===true&&r.usage_pick!=="last").length;
if(inflated)console.log("note: "+inflated+" of "+latest.length+" rows predate dedup_usage (2026-09-04) — their turns, tokens, and cost run ~2.4x high (summed per line, not per response)");
if(outLow)console.log("note: "+outLow+" of "+latest.length+" rows predate usage_pick:\"last\" (v0.68.641) — their output_tokens (and cost) run ~39% low (first line per response, not last)");
// Third era (#162, 1.1.118, 2026-09-25 deep-audit F7): a row this old always priced
// cache_write_tokens entirely at the 5-minute rate. ~99% of real cache writes are
// 1-hour-TTL (full-corpus measurement, same date), so these rows' cost likely runs low.
// cache_write_tokens_1h===undefined (not 0) is the discriminator: a post-fix row with
// genuinely zero 1h writes still carries the field, set to 0.
const preTTLSplit=latest.filter(r=>r.cache_write_tokens_1h===undefined&&(Number(r.cache_write_tokens)||0)>0).length;
if(preTTLSplit)console.log("note: "+preTTLSplit+" of "+latest.length+" rows predate the 1h/5m cache-write split (#162, 1.1.118) — cache_write_tokens was priced entirely at the 5-minute rate; cost on these rows likely runs low");
// Fourth era (issue #163, mh:blind-spot-hunter follow-up on #162): before the
// 1.1.116 fix (which added the missing opus-5-5 branch to rate()), claude-opus-5-5
// matched the old bare "opus" branch and got rate_verified:true at the wrong
// (Opus 5) rate -- rate_verified reads as confirmed-correct with no way to tell
// these rows are stale. mh_version is compared numerically (not string-lexically,
// so "1.1.9" < "1.1.10" sorts right); a missing mh_version can't be placed on
// either side of the boundary and is not flagged.
const verLt=(a,b)=>{
  if(!a)return false;
  const pa=String(a).split(".").map(Number),pb=String(b).split(".").map(Number);
  for(let i=0;i<3;i++){const x=pa[i]||0,y=pb[i]||0;if(x!==y)return x<y;}
  return false;
};
const staleOpus55=latest.filter(r=>/opus-5-5/i.test(r.model||"")&&verLt(r.mh_version,"1.1.116")).length;
if(staleOpus55)console.log("note: "+staleOpus55+" of "+latest.length+" rows are claude-opus-5-5 from before the missing rate-table branch was added (1.1.116) — rate_verified:true is misleading here; these were priced at the old Opus 5 rate ($5/$25) instead of the correct Opus 5.5 rate ($4/$20)");
console.log("today:     "+f4(sum(latest.filter(r=>day(r)===today))));
console.log("yesterday: "+f4(sum(latest.filter(r=>day(r)===d))));
const sessionIds=new Set(latest.map(r=>r.session_id||r.transcript_path||r.timestamp));
console.log("total:     "+f4(sum(latest))+"  ("+sessionIds.size+" sessions)");
// Ledger cross-check (GH #334): cost-ledger.jsonl beside the costs file holds Claude Code's own
// cumulative ledger per main-loop turn (hooks/mod/cost-ledger.ts). Each session's ledger total is
// recomputed from the `usd` sequence in file order, a drop restarting the count (a new process);
// the stored `delta` is ignored because a module reload resets it. Only sessions on both sides
// are compared. The transcript total stays the authoritative number above.
{
  const lf=path.join(path.dirname(f),"cost-ledger.jsonl");
  const led=new Map();let lerr=0,lbad=0;
  // Load markers (GH #444): one `loaded` row per module load, carrying no usd.
  const marked=new Set();let firstMark;
  if(fs.existsSync(lf))for(const l of fs.readFileSync(lf,"utf8").split(/\r?\n/)){
    let r;try{r=JSON.parse(l)}catch{continue}
    if(!r||!r.session_id)continue;
    if(r.loaded===true){marked.add(r.session_id);if(!firstMark||String(r.t)<firstMark)firstMark=String(r.t);continue;}
    if(r.error!==undefined){lerr++;continue;}
    // A finite number only (Number.isFinite never coerces): Number(null) and Number("") are 0,
    // which would read as a reset and add the next reading whole.
    const usd=r.usd;if(!Number.isFinite(usd)){lbad++;continue;}
    const p=led.get(r.session_id)||{prev:undefined,total:0};
    p.total+=p.prev===undefined||usd>=p.prev?usd-(p.prev??0):usd;p.prev=usd;led.set(r.session_id,p);
  }
  // Load rate: sessions with spend since the first marker that carry one. A session without one ran
  // with modules off (kill switch, --bare, an old CLI); older sessions predate the marker.
  if(!firstMark)console.log("module loaded: no load marker (modules off since the marker shipped, or an mh older than it)");
  else{
    const lastTs=new Map();for(const r of latest){const k=r.session_id||r.transcript_path||r.timestamp,ts=String(r.timestamp);if(!lastTs.has(k)||ts>lastTs.get(k))lastTs.set(k,ts);}
    const since=[...lastTs].filter(([,ts])=>ts>=firstMark).map(([k])=>k);
    console.log("module loaded: "+since.filter(k=>marked.has(k)).length+" of "+since.length+" sessions since the first load marker ("+firstMark.slice(0,10)+"); one without ran with modules off");
  }
  if(lerr)console.log("warning: "+lerr+" cost-ledger error rows (the module could not read or write the ledger on those turns) — the ledger total below may run low");
  if(lbad)console.log("warning: "+lbad+" cost-ledger rows with no finite usd were skipped (not read as $0) — the ledger total below may run low");
  if(!led.size)console.log("ledger cross-check: no ledger data (the mh cost-ledger module writes it; it is off when modules are, on CLIs before 2.1.287, or before a session's first turn ends)");
  else{
    const tBy=new Map();for(const r of latest){const k=r.session_id||r.transcript_path||r.timestamp;tBy.set(k,(tBy.get(k)||0)+cost(r));}
    let t=0,lg=0,n=0;for(const [k,v] of led)if(tBy.has(k)){t+=tBy.get(k);lg+=v.total;n++;}
    const tOnly=[...tBy.keys()].filter(k=>!led.has(k)).length,lOnly=led.size-n;
    const gap=lg-t;
    console.log("ledger cross-check: "+(n?"transcript "+f4(t)+" vs ledger "+f4(lg)+" over "+n+" sessions; unattributed "+f4(gap)+" ("+(lg?(100*gap/lg).toFixed(1):"0.0")+"% of ledger)":"no session on both sides")+(tOnly||lOnly?"; left out: "+tOnly+" transcript-only, "+lOnly+" ledger-only":""));
  }
}
const by=(key)=>{const m=new Map();for(const r of latest){const k=key(r)||"(unknown)";m.set(k,(m.get(k)||0)+cost(r));}return [...m.entries()].sort((a,b)=>b[1]-a[1]);};
const unverified=new Set(latest.filter(r=>r.rate_verified===false).map(r=>r.model||"(unknown)"));
console.log("\n=== By model ===");for(const [k,v] of by(r=>r.model))console.log(f4(v).padStart(12)+"  "+k+(unverified.has(k)?"  (rate unverified)":""));
const tagged=latest.filter(r=>r.stream);
if(tagged.length){
  console.log("\n=== By stream (rows tagged 2026-08-07+; older rows are orchestrator-only and excluded) ===");
  for(const [k,v] of by(r=>r.stream)){if(k==="(unknown)")continue;console.log(f4(v).padStart(12)+"  "+k);}
  const orch=tagged.filter(r=>r.stream==="orchestrator");
  const turns=orch.reduce((s,r)=>s+(Number(r.turns)||0),0);
  const cr=orch.reduce((s,r)=>s+(Number(r.cache_read_tokens)||0),0);
  if(turns)console.log("\norchestrator context carried per turn: "+Math.round(cr/turns).toLocaleString()+" tokens  (re-read every turn — the rent meter)");
}
const typed=latest.filter(r=>r.stream==="subagent");
if(typed.length){
  console.log("\n=== By agent type (subagent spend only; rows tagged 2026-08-07+; tok = input+output, rank by it when rate unverified) ===");
  const m=new Map();for(const r of typed){const k=r.agent_type||"(unknown)";const p=m.get(k)||{c:0,t:0};p.c+=cost(r);p.t+=(Number(r.input_tokens)||0)+(Number(r.output_tokens)||0);m.set(k,p);}
  for(const [k,v] of [...m.entries()].sort((a,b)=>b[1].c-a[1].c||b[1].t-a[1].t))console.log(f4(v.c).padStart(12)+"  "+String(v.t).padStart(10)+" tok  "+k);
}
// Handoff cost (restored 2026-09-20 from 6603c384; role breakdown stays excluded — that
// tag was removed separately and is not part of this restore): main's own tokens between
// a subagent's return and the next dispatch, per return. Rows without verify_per_return
// are skipped here, not crashed.
const withVerify=latest.filter(r=>Array.isArray(r.verify_per_return)&&r.verify_per_return.length);
if(withVerify.length){
  const q=(a,p)=>{const s=[...a].sort((x,y)=>x-y);return s[Math.min(s.length-1,Math.floor(p*(s.length-1)+0.5))];};
  const line=(k,a)=>console.log(String(Math.round(q(a,0.5))).padStart(10)+" med  "+String(Math.round(q(a,0.9))).padStart(10)+" p90  "+String(a.length).padStart(4)+" returns  "+k);
  console.log("\n=== Handoff cost (main tokens per subagent return: read result + re-verify + decide, until next dispatch; rows tagged 2026-09-20+) ===");
  // Denominator: every orchestrator row that tracks returns (verify_per_return present,
  // even empty) — a zero-return session's turns count too (2026-09-21).
  const orchV=latest.filter(r=>r.stream==="orchestrator"&&Array.isArray(r.verify_per_return));
  const oTurns=orchV.reduce((s,r)=>s+(Number(r.turns)||0),0),oRet=orchV.reduce((s,r)=>s+(Number(r.returns)||0),0);
  if(oRet&&oTurns)console.log("returns per orchestrator turn: "+(oRet/oTurns).toFixed(2)+"  ("+oRet+" returns / "+oTurns+" turns)");
  const subV=withVerify.filter(r=>r.stream==="subagent");
  if(subV.length)line("all subagents",subV.flatMap(r=>r.verify_per_return));
}
console.log("\n=== Last 7 days ===");
const days=new Map();for(const r of latest){const k=day(r);days.set(k,(days.get(k)||0)+cost(r));}
[...days.entries()].sort((a,b)=>b[0]<a[0]?-1:1).slice(0,7).forEach(([k,v])=>console.log(k+"  "+f4(v)));

// Codex invocations: a count, not a cost (Codex exposes no local per-call price).
// cost-tracker re-derives cumulative counts from the full transcript on every stop,
// so only the latest such row per session matters -- same "latest wins" rule as the
// cost rows above, summed independently since these rows carry no model to key by.
const codexBySession=new Map();
for(const r of rows){
  if(!r.codex_invocations)continue;
  const k=r.session_id||r.transcript_path||r.timestamp;
  const p=codexBySession.get(k);
  if(!p||String(r.timestamp)>String(p.timestamp))codexBySession.set(k,r);
}
const codexTotals=new Map();
for(const r of codexBySession.values())for(const [name,n] of Object.entries(r.codex_invocations||{}))codexTotals.set(name,(codexTotals.get(name)||0)+(Number(n)||0));
if(codexTotals.size){
  console.log("\n=== Codex invocations ===");
  for(const [k,v] of [...codexTotals.entries()].sort((a,b)=>b[1]-a[1]))console.log(String(v).padStart(6)+"  "+k);
}
