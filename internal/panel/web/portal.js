"use strict";
const $ = (h) => { const t = document.createElement("template"); t.innerHTML = h.trim(); return t.content.firstChild; };
const app = document.getElementById("app");
function esc(s){ return String(s).replace(/[&<>"]/g,(c)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }
function toast(m){ const t=$(`<div class="toast">${esc(m)}</div>`); document.body.appendChild(t); setTimeout(()=>t.remove(),2400); }
async function copy(text){ try{ if(navigator.clipboard) await navigator.clipboard.writeText(text); else{const a=document.createElement("textarea");a.value=text;document.body.appendChild(a);a.select();document.execCommand("copy");a.remove();} toast("Copied"); }catch{ toast("Copy failed"); } }
function fmtBytes(n){ n=Number(n||0); if(!n) return "0 B"; const u=["B","KB","MB","GB","TB","PB"]; let i=0; while(n>=1024&&i<u.length-1){n/=1024;i++;} return n.toFixed(i?(n<10?2:1):0)+" "+u[i]; }
function fmtDate(sec){ return sec? new Date(sec*1000).toLocaleString() : "never"; }
function relDays(sec){ if(!sec) return ""; const d=Math.ceil((sec-Date.now()/1000)/86400); return d<0? `expired ${-d}d ago` : d===0? "expires today" : `${d}d left`; }

async function api(path, opts={}){
  const res = await fetch(path, { headers:{"Content-Type":"application/json"}, ...opts });
  const txt = await res.text(); const data = txt? JSON.parse(txt) : null;
  if(!res.ok) throw new Error((data&&data.error)||res.statusText);
  return data;
}

function renderLogin(msg){
  app.innerHTML = "";
  const box = $(`<div class="wrap"><div class="login">
    <div class="brand"><div class="logo">玄</div><div><b>Xuanwu</b><span>My Account</span></div></div>
    <div class="card">
      <h3>Sign in</h3>
      ${msg? `<div class="banner bad">${esc(msg)}</div>`:""}
      <label>Username</label><input id="u" autocomplete="username" autofocus>
      <label>Password</label><input id="p" type="password" autocomplete="current-password">
      <div style="margin-top:16px"><button class="primary" id="go" style="width:100%">Sign in</button></div>
      <p class="mut" style="font-size:12px;margin:14px 0 0">Ask your administrator for your password.</p>
    </div></div></div>`);
  const submit = async ()=>{
    try{ await api("/api/portal/login",{method:"POST",body:JSON.stringify({username:box.querySelector("#u").value,password:box.querySelector("#p").value})}); load(); }
    catch(e){ toast(e.message); }
  };
  box.querySelector("#go").onclick = submit;
  box.querySelectorAll("input").forEach((i)=>i.addEventListener("keydown",(e)=>{ if(e.key==="Enter") submit(); }));
  app.appendChild(box);
}

function copyField(label, value){
  return `<label>${esc(label)}</label><div class="field"><code>${esc(value)}</code>
    <button class="sm" data-copy="${esc(value)}">Copy</button></div>`;
}

function renderAccount(me){
  app.innerHTML = "";
  const used = Number(me.data_used||0);
  const pct = me.data_limit? Math.min(100, Math.round(used/me.data_limit*100)) : 0;
  const pcls = pct>=100?"bad":pct>=80?"warn":"";
  const statusBanner = !me.active
    ? `<div class="banner ${me.enabled?"warn":"bad"}">${me.enabled? "Your account is over quota or expired — proxies are currently disabled." : "Your account has been disabled by the administrator."}</div>`
    : "";
  const nodesHtml = (me.nodes||[]).map((n)=>`<div class="node">
      <b>${esc(n.name)}</b>
      ${(n.links||[]).map((l)=>`<div class="field"><code>${esc(l)}</code><button class="sm" data-copy="${esc(l)}">Copy</button></div>`).join("")}
    </div>`).join("") || `<div class="mut">No nodes assigned yet.</div>`;

  const el = $(`<div class="wrap">
    <div class="brand"><div class="logo">玄</div><div><b>${esc(me.username)}</b><span>My Account</span></div>
      <div class="grow"></div>
      <span class="pill ${me.active?"on":"off"}">${me.active?"active":me.enabled?"inactive":"disabled"}</span>
      <button class="sm" id="logout">Logout</button></div>
    ${statusBanner}
    <div class="card"><h3>Usage</h3>
      <div class="stats">
        <div class="stat"><div class="k">Traffic used</div><div class="v">${fmtBytes(used)}<small> / ${me.data_limit? fmtBytes(me.data_limit): "∞"}</small></div>
          ${me.data_limit? `<div class="prog ${pcls}"><i style="width:${pct}%"></i></div>`:""}</div>
        <div class="stat"><div class="k">Expires</div><div class="v" style="font-size:16px">${me.expire_at? fmtDate(me.expire_at):"never"}</div>
          <div class="mut" style="font-size:12px;margin-top:4px">${me.expire_at? relDays(me.expire_at):""}</div></div>
        <div class="stat"><div class="k">Nodes</div><div class="v">${(me.nodes||[]).length}</div></div>
      </div></div>

    <div class="card"><h3>Subscription</h3>
      ${copyField("Base64 (v2rayN / sing-box)", me.sub_url)}
      ${copyField("Clash / Mihomo", me.clash_url)}
      <div class="imp">
        <button class="sm" id="imp-clash">Import to Clash</button>
        <button class="sm" id="imp-sb">Import to sing-box</button>
      </div>
      <div class="qr">
        <figure><img alt="subscription QR" src="/api/portal/qr?t=sub"><figcaption>Base64 subscription</figcaption></figure>
        <figure><img alt="clash QR" src="/api/portal/qr?t=clash"><figcaption>Clash subscription</figcaption></figure>
      </div>
    </div>

    <div class="card"><h3>Nodes &amp; direct links</h3>${nodesHtml}</div>
    <p class="mut" style="font-size:12px;text-align:center">Keep these links private — anyone with them can use your account.</p>
  </div>`);
  el.querySelector("#logout").onclick = async ()=>{ try{ await api("/api/portal/logout",{method:"POST"}); }catch{} renderLogin(); };
  el.querySelector("#imp-clash").onclick = ()=>{ location.href = "clash://install-config?url=" + encodeURIComponent(me.clash_url) + "&name=Xuanwu"; };
  el.querySelector("#imp-sb").onclick = ()=>{ location.href = "sing-box://import-remote-profile?url=" + encodeURIComponent(me.sub_url + "/singbox") + "#Xuanwu"; };
  el.querySelectorAll("[data-copy]").forEach((b)=>b.onclick=()=>copy(b.dataset.copy));
  app.appendChild(el);
}

function renderChangePassword(){
  app.innerHTML = "";
  const box = $(`<div class="wrap"><div class="login">
    <div class="brand"><div class="logo">玄</div><div><b>Xuanwu</b><span>My Account</span></div></div>
    <div class="card">
      <h3 style="margin:0 0 4px;font-size:16px;color:var(--fg)">Set a new password</h3>
      <p class="mut" style="font-size:12.5px;margin:0 0 6px">Your password was set by an administrator. Please choose your own before continuing.</p>
      <label>New password (8+ with upper, lower, digit, special)</label><input id="np" type="password" autocomplete="new-password" autofocus>
      <label>Confirm password</label><input id="cp" type="password" autocomplete="new-password">
      <div style="margin-top:16px"><button class="primary" id="save" style="width:100%">Save & continue</button></div>
    </div></div></div>`);
  const submit = async ()=>{
    const np = box.querySelector("#np").value, cp = box.querySelector("#cp").value;
    if(!(np.length>=8 && /[a-z]/.test(np) && /[A-Z]/.test(np) && /[0-9]/.test(np) && /[^A-Za-z0-9]/.test(np))){ toast("Password needs 8+ chars with upper, lower, digit & special"); return; }
    if(np !== cp){ toast("Passwords do not match"); return; }
    try{ await api("/api/portal/change-password",{method:"POST",body:JSON.stringify({new_password:np})}); toast("Password updated"); load(); }
    catch(e){ toast(e.message); }
  };
  box.querySelector("#save").onclick = submit;
  box.querySelectorAll("input").forEach((i)=>i.addEventListener("keydown",(e)=>{ if(e.key==="Enter") submit(); }));
  app.appendChild(box);
}

async function load(){
  try{
    const me = await api("/api/portal/me");
    if(me.must_change){ renderChangePassword(); return; }
    renderAccount(me);
  }
  catch(e){ renderLogin(); }
}
load();
