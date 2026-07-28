/* Die Tracker shared core. Used by index.html (operator) and manager.html.
   Edit config here once and both pages pick it up. */
/* ============================ CONFIG ============================ */
const SUPABASE_URL = "https://kgeetkuzfiynqrwlqesd.supabase.co";
const SUPABASE_KEY = "sb_publishable_rGaZg0I9HlkrExM1Q-_c3A_s2Y-_BIM";
const HISTORY_DAYS = 120;

/* ============================ LOCAL STORE ============================ */
const LS = (()=>{ let mem={};
  const ok=(()=>{try{localStorage.setItem("_t","1");localStorage.removeItem("_t");return true}catch(e){return false}})();
  return { get:k=>{try{return ok?localStorage.getItem(k):mem[k]}catch(e){return mem[k]}},
           set:(k,v)=>{try{ok?localStorage.setItem(k,v):mem[k]=v}catch(e){mem[k]=v}} };})();
const uuid=()=>(crypto.randomUUID?crypto.randomUUID():"x"+Date.now()+Math.random().toString(36).slice(2));
let DEVICE_ID = LS.get("dt:device") || (()=>{const v="dev-"+uuid().slice(0,8);LS.set("dt:device",v);return v})();

/* ============================ STATE ============================ */
let sb=null, STAGES=[], MACHINES=[], DIES=[], EVENTS=[], QUEUE=[];
let online=navigator.onLine, ready=false, dbErr=null;
let lang=LS.get("dt:lang")||"en", side="floor", operator=LS.get("dt:op")||"Team";
let V={view:"home",target:null,mach:null,die:null,pad:"",flash:null,tab:"machines",err:null,showOthers:false,pickN:null};
let track=null, zx=null, detector=null, scanLoop=null, camTried=false;

const REASONS=[{id:"H01",en:"No machine",hi:"मशीन नहीं"},{id:"H02",en:"Crane / shifting",hi:"क्रेन"},
{id:"H03",en:"No program",hi:"प्रोग्राम नहीं"},{id:"H04",en:"No tooling",hi:"टूल नहीं"},
{id:"H07",en:"Press busy",hi:"प्रेस व्यस्त"},{id:"H09",en:"Customer hold",hi:"ग्राहक"}];
const OPERATORS=["Team","OP01Ramesh","OP02 Suresh","OP03 Anil","OP04 Vikram","OP05 Dinesh"];
const T={scan:{en:"Scan",hi:"स्कैन करें"},scanAny:{en:"Scan die or machine",hi:"डाई या मशीन स्कैन करें"},
start:{en:"Start",hi:"शुरू करें"},end:{en:"Finish",hi:"पूरा हुआ"},pause:{en:"Hold",hi:"रोकें"},
resume:{en:"Resume",hi:"फिर शुरू"},running:{en:"Running now",hi:"चल रहा है"},
nothing:{en:"Nothing running",hi:"कुछ नहीं चल रहा"},keypad:{en:"Type code",hi:"कोड लिखें"},
cancel:{en:"Cancel",hi:"रद्द करें"},needDie:{en:"Now scan the die",hi:"अब डाई स्कैन करें"},
needMach:{en:"Now scan the machine",hi:"अब मशीन स्कैन करें"},why:{en:"Why has it stopped?",hi:"क्यों रुका है?"},
onhold:{en:"On hold",hi:"रुका हुआ"},whichOp:{en:"Which operation?",hi:"कौन सा काम?"},
others:{en:"Others",hi:"अन्य"},back:{en:"Back",hi:"वापस"}};
const t=k=>T[k]?(T[k][lang]||T[k].en):k;
const esc=s=>String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const norm=v=>String(v||"").trim().toUpperCase();

const S=p=>`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${p}</svg>`;
const ICON={scan:S('<path d="M3 7V5a2 2 0 0 1 2-2h2M17 3h2a2 2 0 0 1 2 2v2M21 17v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2"/><path d="M7 12h10"/>'),
play:S('<path d="M7 4l13 8-13 8z" fill="currentColor" stroke="none"/>'),
stop:S('<rect x="5" y="5" width="14" height="14" rx="2" fill="currentColor" stroke="none"/>'),
pause:S('<rect x="7" y="4" width="3.5" height="16" rx="1" fill="currentColor" stroke="none"/><rect x="13.5" y="4" width="3.5" height="16" rx="1" fill="currentColor" stroke="none"/>'),
tick:S('<circle cx="12" cy="12" r="10"/><path d="M7.5 12.5l3 3 6-6"/>'),
back:S('<path d="M15 18l-6-6 6-6"/>'),key:S('<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h4"/>')};

/* ============================ DATA LAYER ============================ */
const rowToEvent=r=>({id:r.id,cid:r.client_event_id,ts:new Date(r.ts).getTime(),type:r.type,
  die:r.die_code,machine:r.machine_code,stage:r.stage_no,sug:r.suggested_stage_no,
  reason:r.reason,by:r.operator,dev:r.device_id});

async function connect(){
  try{
    sb=window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY,{realtime:{params:{eventsPerSecond:5}}});
    const since=new Date(Date.now()-HISTORY_DAYS*864e5).toISOString();
    const [st,mc,di,ev]=await Promise.all([
      sb.from("stages").select("*").order("no"),
      sb.from("machines").select("*").order("code"),
      sb.from("dies").select("*").order("code"),
      sb.from("events").select("*").gte("ts",since).order("ts")]);
    for(const r of [st,mc,di,ev]) if(r.error) throw r.error;
    STAGES=st.data.map(s=>({n:s.no,name:s.name,other:!!s.is_other}));
    MACHINES=mc.data; DIES=di.data; EVENTS=ev.data.map(rowToEvent);
    LS.set("dt:cache",JSON.stringify({STAGES,MACHINES,DIES,EVENTS}));
    sb.channel("ev").on("postgres_changes",
      {event:"INSERT",schema:"public",table:"events"},p=>{
        const e=rowToEvent(p.new);
        if(!EVENTS.some(x=>x.id===e.id||(e.cid&&x.cid===e.cid))){EVENTS.push(e);render();}
      }).subscribe();
    dbErr=null; ready=true;
  }catch(e){
    dbErr=e.message||String(e);
    const c=LS.get("dt:cache");
    if(c){const d=JSON.parse(c);STAGES=d.STAGES;MACHINES=d.MACHINES;DIES=d.DIES;EVENTS=d.EVENTS;ready=true;}
  }
  QUEUE=JSON.parse(LS.get("dt:queue")||"[]");
  flush(); render();
}
const saveQueue=()=>LS.set("dt:queue",JSON.stringify(QUEUE));

async function pushEvent(o){
  const cid=uuid();
  const row={type:o.type,die_code:o.die,machine_code:o.machine,stage_no:o.stage,
    suggested_stage_no:o.sug??null,reason:o.reason??null,operator:operator,
    device_id:DEVICE_ID,client_event_id:cid,device_ts:new Date().toISOString()};
  EVENTS.push({id:"local-"+cid,cid,ts:Date.now(),type:o.type,die:o.die,machine:o.machine,
    stage:o.stage,sug:o.sug,reason:o.reason,by:operator,dev:DEVICE_ID});
  QUEUE.push(row); saveQueue(); flush();
}
let flushing=false;
async function flush(){
  if(flushing||!sb||!QUEUE.length||!navigator.onLine) return;
  flushing=true;
  while(QUEUE.length){
    const row=QUEUE[0];
    try{
      const {error}=await sb.from("events").insert(row);
      if(error && error.code!=="23505") throw error;
      QUEUE.shift(); saveQueue();
    }catch(e){ dbErr=e.message||String(e); break; }
  }
  flushing=false; paintNet();
}
window.addEventListener("online",()=>{online=true;flush();paintNet()});
window.addEventListener("offline",()=>{online=false;paintNet()});
setInterval(flush,15000);

function paintNet(){
  const dot=document.getElementById("netdot"),tx=document.getElementById("nettext"),
        chip=document.getElementById("netchip");
  if(!dot) return;
  if(QUEUE.length){dot.className="dot wait";tx.textContent="QUEUE "+QUEUE.length;chip.className="chip";}
  else if(!navigator.onLine){dot.className="dot off";tx.textContent="OFFLINE";chip.className="chip bad";}
  else if(dbErr){dot.className="dot off";tx.textContent="DB ERROR";chip.className="chip bad";}
  else {dot.className="dot";tx.textContent="LIVE";chip.className="chip";}
}

/* ============================ DOMAIN ============================ */
const stageName=n=>{const s=STAGES.find(x=>x.n===n);return s?s.name:""};
const PRIMARY=()=>STAGES.filter(s=>!s.other);
const OTHERS=()=>STAGES.filter(s=>s.other);
/* ---------------- machine rules per operation ----------------
   Edit here. Codes, with names in the comment so they stay readable.
   101 H16 · 102 H22 · 103 OK1 · 104 OK2 · 105 OK3 · 106 OK4
   107 RAD1 · 108 RAD2 · 109 RAD3 · 110 200T · 111 500T · 112 800T · 100 NA        */
const NA_MACHINE = "100";                       // auto-used where no machine applies
const NO_MACHINE_STAGES = [1,3,5,8];            // Raw Casting, Fitting, Heat Treatment, Assembly
const MACHINING = ["101","102","103","104","105","106"];   // H16 H22 OK1-4
const PRESSES   = ["110","111","112"];                     // 200T 500T 800T
const IDEAL_MACHINES = {
  2:MACHINING,   // P1/P2
  4:MACHINING,   // P3 Machining
  6:MACHINING,   // P4 Machining
  7:MACHINING,   // P5 Machining
  9:PRESSES,     // Spotting
 10:PRESSES,     // Trial
 13:PRESSES      // Part Production
  // 11 Surface Correction, 12 Trim Correction, 14 ECN Machining, 15 Drilling:
  // no rule set, so any machine is accepted without warning.
};
const needsMachine = n => !NO_MACHINE_STAGES.includes(Number(n));
const idealFor     = n => IDEAL_MACHINES[Number(n)] || [];
const isIdeal      = (n,code) => { const l=idealFor(n); return !l.length || l.includes(String(code)); };

const dieSetOf=c=>{const m=String(c||"").match(/^(FG-\d+|\d+)/i);return m?m[1].toUpperCase():norm(c)};
const diesInSet=s=>DIES.filter(d=>dieSetOf(d.code)===norm(s));
const machineBy=v=>MACHINES.find(m=>norm(m.code)===norm(v));
const dieBy=v=>DIES.find(d=>norm(d.code)===norm(v));
function runOf(mCode){
  const evs=EVENTS.filter(e=>e.machine===mCode).sort((a,b)=>a.ts-b.ts);
  let r=null;
  for(const e of evs){
    if(e.type==="START")r={die:e.die,stage:e.stage,ts:e.ts,by:e.by,paused:false,reason:null};
    else if(e.type==="END")r=null;
    else if(e.type==="PAUSE"&&r){r.paused=true;r.reason=e.reason}
    else if(e.type==="RESUME"&&r){r.paused=false;r.reason=null}
  }
  return r;
}
const openRuns=()=>MACHINES.map(m=>({m,r:runOf(m.code)})).filter(x=>x.r);
const stageDone=(die,n)=>EVENTS.some(e=>e.type==="END"&&e.die===die&&e.stage===n);
const runningElsewhere=die=>openRuns().find(x=>x.r.die===die);
function suggestStage(d){const s=PRIMARY().find(st=>!stageDone(d,st.n));return s?s.n:null}
function dieState(code){
  const run=runningElsewhere(code);
  if(run)return{state:run.r.paused?"paused":"running",mach:run.m,stage:run.r.stage,ts:run.r.ts,next:suggestStage(code)};
  const done=STAGES.filter(s=>stageDone(code,s.n));
  const evs=EVENTS.filter(e=>e.die===code).sort((a,b)=>b.ts-a.ts);
  return{state:evs.length?"waiting":"new",stage:done.length?done[done.length-1].n:null,
    next:suggestStage(code),last:evs[0]?evs[0].ts:null};
}
function el(ms){const s=Math.max(0,Math.floor(ms/1000)),d=Math.floor(s/86400),
  h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);
  if(d)return d+"d "+h+"h"; if(h)return h+"h "+m+"m"; return m+"m"}
const stamp=ts=>new Date(ts).toLocaleString("en-GB",{day:"2-digit",month:"short",hour:"2-digit",minute:"2-digit",hour12:false});

