/* HttpArena - shared chrome for every page: theme, command palette, keyboard
   shortcuts, toasts, tooltips, and the Knowledge Base furniture (sidebar search,
   "On this page", copy buttons, callouts, sortable tables). No dependencies.
   The board adds its own keys and hooks through window.HA_KEYS / HA_BOARD. */
(function(){
  'use strict';
  var HA = window.HA = window.HA || {};
  var root = document.documentElement;
  // The site is generated for the root of a domain, but a preview serves it
  // below a path: the home URL is wherever this script's folder hangs from.
  var HOME = '/';
  try{ HOME = new URL('../', document.currentScript.src).pathname; }catch(e){}
  var ON_BOARD = !!document.getElementById('grid');

  function esc(s){ return String(s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
  function $(s, el){ return (el||document).querySelector(s); }
  function $all(s, el){ return Array.prototype.slice.call((el||document).querySelectorAll(s)); }
  function typing(e){ var t=e.target, tag=t&&t.tagName; return tag==='INPUT'||tag==='TEXTAREA'||tag==='SELECT'||(t&&t.isContentEditable); }
  function loadScript(src, cb){
    var s=document.createElement('script'); s.src=src;
    s.onload=function(){ cb(true); }; s.onerror=function(){ cb(false); };
    document.head.appendChild(s);
  }

  var I = {
    search:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>',
    view:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 20v-6M12 20V4M18 20V10"/></svg>',
    prof:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 6h16M4 12h16M4 18h10"/></svg>',
    entry:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="m12 3 8 4.5v9L12 21l-8-4.5v-9z"/><path d="m4 7.5 8 4.5 8-4.5M12 12v9"/></svg>',
    lang:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m8 7-5 5 5 5M16 7l5 5-5 5M13.5 4l-3 16"/></svg>',
    cmp:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h13"/><path d="m14 5 3 3-3 3"/><path d="M20 16H7"/><path d="m10 13-3 3 3 3"/></svg>',
    doc:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5M9.5 13h6M9.5 17h4"/></svg>',
    act:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 3 5 13h6l-1 8 8-10h-6z"/></svg>',
    ext:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 5h5v5M19 5l-8 8M11 6H6v12h12v-5"/></svg>',
    copy:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/></svg>',
    check:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>',
    chev:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg>'
  };

  // ── theme ────────────────────────────────────────────────
  function isDark(){ var t=root.getAttribute('data-theme'); return t==='dark' || (t!=='light' && matchMedia('(prefers-color-scheme: dark)').matches); }
  HA.toggleTheme = function(){
    var next=isDark()?'light':'dark';
    root.setAttribute('data-theme', next);
    try{ localStorage.setItem('lb-theme', next); }catch(e){}
    document.dispatchEvent(new CustomEvent('ha:theme', {detail:next}));
  };
  var themeBtn=document.getElementById('theme');
  if(themeBtn) themeBtn.onclick=HA.toggleTheme;

  // ── toast + clipboard ────────────────────────────────────
  var toastEl, toastT;
  HA.toast = function(msg){
    if(!toastEl){ toastEl=document.createElement('div'); toastEl.className='toast'; toastEl.setAttribute('role','status'); toastEl.setAttribute('aria-live','polite'); document.body.appendChild(toastEl); }
    toastEl.innerHTML=I.check+'<span>'+esc(msg)+'</span>';
    toastEl.offsetWidth; toastEl.classList.add('show');
    clearTimeout(toastT); toastT=setTimeout(function(){ toastEl.classList.remove('show'); }, 1900);
  };
  HA.copy = function(text, msg){
    function done(){ HA.toast(msg||'Copied'); }
    function legacy(){
      var ta=document.createElement('textarea'); ta.value=text; ta.setAttribute('readonly',''); ta.style.cssText='position:fixed;top:0;left:0;opacity:0';
      document.body.appendChild(ta); ta.select();
      try{ document.execCommand('copy'); done(); }catch(e){ HA.toast('Copy failed - the address bar has the link'); }
      ta.remove();
    }
    if(navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done, legacy); else legacy();
  };

  // ── tooltips (the board draws its own, with the cell popups) ─
  if(!ON_BOARD){
    var tip=document.createElement('div'); tip.id='tip'; document.body.appendChild(tip);
    var tipPos=function(el){ var r=el.getBoundingClientRect(); tip.style.display='block'; var tw=tip.offsetWidth, th=tip.offsetHeight; var l=r.left+r.width/2-tw/2, t=r.bottom+8; if(t+th>window.innerHeight-6) t=r.top-th-8; l=Math.max(6,Math.min(l,window.innerWidth-tw-6)); tip.style.left=l+'px'; tip.style.top=t+'px'; };
    document.addEventListener('mouseover', function(e){ var el=e.target.closest?e.target.closest('[data-tip]'):null; if(!el) return; tip.textContent=el.getAttribute('data-tip'); tipPos(el); });
    document.addEventListener('mouseout', function(e){ var el=e.target.closest?e.target.closest('[data-tip]'):null; if(el && !el.contains(e.relatedTarget)) tip.style.display='none'; });
    document.addEventListener('scroll', function(){ tip.style.display='none'; }, true);
  }

  // ── overlays ─────────────────────────────────────────────
  var openOv=null, lastFocus=null;
  HA.overlayOpen = function(){ return !!openOv; };
  function showOv(el){
    if(openOv) hideOv();
    lastFocus=document.activeElement; openOv=el; el.classList.add('open');
  }
  function hideOv(){
    if(!openOv) return;
    openOv.classList.remove('open'); openOv=null;
    if(lastFocus && lastFocus.focus) try{ lastFocus.focus(); }catch(e){}
  }
  function makeOv(id, label){
    var o=document.createElement('div'); o.className='ov'; o.id=id; o.setAttribute('role','dialog'); o.setAttribute('aria-modal','true'); o.setAttribute('aria-label',label);
    o.addEventListener('mousedown', function(e){ if(e.target===o) hideOv(); });
    document.body.appendChild(o); return o;
  }

  // ── command palette ──────────────────────────────────────
  var SCOPES=[['all','Overall'],['h1','H/1.1'],['h2','H/2'],['h3','H/3'],['gw','Gateway'],['grpc','gRPC'],['ws','WebSocket']];
  var pal=null, palIn, palList, palItems=[], palSel=0, NAV=null, navState=0, docsState=0, palIdx=null;
  function go(url){ hideOv(); location.href=url; }
  function boardView(kind, id, conns){
    return function(){
      hideOv();
      if(window.HA_BOARD){ if(kind==='scope') HA_BOARD.scope(id); else HA_BOARD.profile(id); window.scrollTo(0,0); return; }
      location.href = HOME + (kind==='scope' ? (id==='h1'?'':'#scope='+id) : '#p='+id+(conns?'&conns='+conns:''));
    };
  }
  function buildIndex(){
    var ix=[];
    function add(g, title, sub, icon, run, extra, kw){ ix.push({g:g, t:title, s:sub||'', ic:icon, run:run, x:extra||'', tl:(title+' '+(kw||'')).toLowerCase(), bl:((sub||'')+' '+(extra||'')).toLowerCase()}); }
    SCOPES.forEach(function(s,i){ add('Rankings', s[1]+' composite', 'Composite ranking', I.view, boardView('scope', s[0]), '', 'board leaderboard ranking '+(s[0]==='h1'?'http1 http/1.1':s[0]==='h2'?'http2 http/2':s[0]==='h3'?'http3 http/3 quic':s[0])); ix[ix.length-1].k=String(i+1); });
    add('Pages', 'Leaderboard', 'The composite ranking', I.view, function(){ go(HOME); }, '', 'home board');
    add('Pages', 'Frameworks', 'Every entry, grouped by language', I.entry, function(){ go('/frameworks/'); }, '', 'entries list index');
    add('Pages', 'Head to head comparison', 'Any two entries, any language', I.cmp, function(){ go('/compare/all/'); }, '', 'compare versus vs');
    add('Pages', 'Comparisons by language', 'One language at a time', I.cmp, function(){ go('/compare/'); }, '', 'compare');
    add('Pages', 'Knowledge Base', 'How the benchmark is run and scored', I.doc, function(){ go('/docs/'); }, '', 'docs documentation methodology');
    if(NAV){
      (NAV.p||[]).forEach(function(p){ add('Test profiles', p[1], p[2]+' · detail view', I.prof, boardView('profile', p[0], p[3]), p[4]||'', p[0]+' '+p[2]); });
      (NAV.e||[]).forEach(function(e){ add('Entries', e[0], [e[2], e[3], e[4]?'tuned':''].filter(Boolean).join(' · '), I.entry, function(){ go('/frameworks/'+e[1]+'/'); }, '', ''); ix[ix.length-1].fw=e[0]; });
      (NAV.l||[]).forEach(function(l){
        add('Languages', l[0], l[2]+(l[2]===1?' entry':' entries')+' · language summary', I.lang, function(){ go('/frameworks/lang/'+l[1]+'/'); }, '', 'language');
        if(l[3]) add('Comparisons', 'Compare '+l[0]+' entries', 'Head to head, '+l[2]+' entries', I.cmp, function(){ go('/compare/'+l[1]+'/'); }, '', 'vs versus head');
      });
    }
    (window.LB_SEARCH||[]).forEach(function(d){
      add('Knowledge Base', d.t||'Knowledge Base', d.c||'', I.doc, function(){ go('/docs/'+(d.u?d.u+'/':'')); }, (d.d?d.d+' ':'')+(d.x||''), '');
      ix[ix.length-1].doc=1;
    });
    add('Actions', 'Toggle light / dark theme', '', I.act, function(){ hideOv(); HA.toggleTheme(); }, '', 'theme dark light mode'); ix[ix.length-1].k='t';
    add('Actions', 'Keyboard shortcuts', '', I.act, function(){ HA.keys(); }, '', 'help keys hotkeys'); ix[ix.length-1].k='?';
    add('Actions', 'Copy link to this page', '', I.act, function(){ hideOv(); HA.copy(location.href, 'Link copied'); }, '', 'share url');
    add('Links', 'GitHub repository', 'github.com/MDA2AV/HttpArena', I.ext, function(){ go('https://github.com/MDA2AV/HttpArena'); }, '', 'source code');
    add('Links', 'Discord', 'Community chat', I.ext, function(){ go('https://discord.gg/H84B5ZqDXR'); }, '', 'chat community');
    add('Links', 'Timeline', 'Results over time', I.ext, function(){ go('https://timeline.http-arena.com'); }, '', 'history');
    add('Links', 'RFC compliance (Http11Probe)', '', I.ext, function(){ go('https://mda2av.github.io/Http11Probe/'); }, '', 'probe spec');
    add('Links', 'Rankings as text (llms.txt)', '', I.ext, function(){ go('/llms.txt'); }, '', 'llm text');
    return ix;
  }
  var CAP={'Rankings':7,'Pages':5,'Test profiles':6,'Entries':8,'Languages':5,'Comparisons':5,'Knowledge Base':8,'Actions':3,'Links':5};
  function searchIndex(q){
    var ql=q.toLowerCase().trim(), terms=ql.split(/\s+/).filter(Boolean), out=[];
    palIdx.forEach(function(e){
      var score=0;
      for(var i=0;i<terms.length;i++){
        var t=terms[i], ti=e.tl.indexOf(t), bi=e.bl.indexOf(t);
        if(ti<0 && bi<0) return;
        score += ti===0 ? 60 : ti>0 ? (/[\s\/\-._]/.test(e.tl.charAt(ti-1))?45:32) : 0;
        if(bi>=0) score+=4;
      }
      if(e.tl.split(' ')[0]===ql || e.t.toLowerCase()===ql) score+=50;
      if(!e.doc) score+=6;
      score-=Math.min(e.t.length,40)/20;
      out.push({e:e, score:score});
    });
    // "a vs b": offer the pair itself
    var vs=ql.split(/\s+vs\.?\s+/);
    if(vs.length===2 && vs[0] && vs[1] && NAV){
      var find=function(x){ var best=null; (NAV.e||[]).forEach(function(en){ var n=en[0].toLowerCase(); if(n===x) best=best&&best.ex?best:{n:en[0],ex:1}; else if(n.indexOf(x)===0 && !best) best={n:en[0]}; }); return best&&best.n; };
      var a=find(vs[0]), b=find(vs[1]);
      if(a && b && a!==b) out.push({score:500, e:{g:'Comparisons', t:a+' vs '+b, s:'Head to head, every shared profile', ic:I.cmp, x:'', run:function(){ go('/compare/all/#'+encodeURIComponent(a)+'-vs-'+encodeURIComponent(b)); }}});
    }
    out.sort(function(x,y){ return y.score-x.score; });
    var groups={}, order=[];
    out.forEach(function(h){ var g=h.e.g; if(!groups[g]){ groups[g]=[]; order.push(g); } if(groups[g].length<(CAP[g]||6)) groups[g].push(h.e); });
    return order.map(function(g){ return [g, groups[g]]; });
  }
  function snippet(body, term){
    if(!body) return '';
    var i=body.toLowerCase().indexOf(term); if(i<0) return '';
    var s=Math.max(0,i-30), e=Math.min(body.length,i+term.length+60);
    return (s>0?'…':'')+esc(body.slice(s,i))+'<mark>'+esc(body.slice(i,i+term.length))+'</mark>'+esc(body.slice(i+term.length,e))+(e<body.length?'…':'');
  }
  function palRender(){
    var q=palIn.value.trim(), groups, h='';
    if(!palIdx || palIdx._n!==navState+'/'+docsState){ palIdx=buildIndex(); palIdx._n=navState+'/'+docsState; }
    if(!q){
      var pick=function(g){ return palIdx.filter(function(e){ return e.g===g; }); };
      groups=[['Rankings',pick('Rankings')],['Pages',pick('Pages')],['Actions',pick('Actions')]];
    } else groups=searchIndex(q);
    palItems=[];
    var term=q.toLowerCase().split(/\s+/)[0]||'';
    groups.forEach(function(g){
      if(!g[1].length) return;
      h+='<div class="pal-g">'+esc(g[0])+'</div>';
      g[1].forEach(function(e){
        var i=palItems.length; palItems.push(e);
        var sub=e.s; if(e.doc && q){ var sn=snippet(e.x, term); if(sn) sub=null, e._sn=sn; else e._sn=''; }
        h+='<button type="button" class="pal-i'+(i===palSel?' sel':'')+'" role="option" aria-selected="'+(i===palSel)+'" data-i="'+i+'">'
          + '<span class="ic">'+e.ic+'</span><span class="tx"><span class="t">'+esc(e.t)+'</span>'
          + (e.doc&&q&&e._sn ? '<span class="s">'+e._sn+'</span>' : (e.s?'<span class="s">'+esc(e.s)+'</span>':''))
          + '</span>'+(e.k?'<span class="k"><kbd>'+esc(e.k)+'</kbd></span>':'')+'</button>';
      });
    });
    if(!palItems.length){
      h = (navState===1||docsState===1) && q
        ? '<div class="pal-skel"><i class="skel" style="width:70%"></i><i class="skel" style="width:52%"></i><i class="skel" style="width:64%"></i></div>'
        : '<div class="pal-empty">No match for <b>'+esc(q)+'</b>. Try an entry name, a language, a profile or a docs topic.</div>';
    } else if(q && (navState===1||docsState===1)) h+='<div class="pal-skel"><i class="skel" style="width:58%"></i></div>';
    palList.innerHTML=h;
    if(palSel>=palItems.length) palSel=Math.max(0,palItems.length-1);
  }
  function palMove(d){
    if(!palItems.length) return;
    palSel=(palSel+d+palItems.length)%palItems.length;
    $all('.pal-i', palList).forEach(function(el,i){ var on=i===palSel; el.classList.toggle('sel',on); el.setAttribute('aria-selected',on); if(on) el.scrollIntoView({block:'nearest'}); });
  }
  function palLoad(){
    if(navState===0){ navState=1; loadScript('/palette.js', function(ok){ NAV=window.HA_NAV||null; navState=ok&&NAV?2:3; if(openOv===pal) palRender(); }); }
    if(docsState===0){
      if(window.LB_SEARCH){ docsState=2; }
      else { docsState=1; loadScript('/search.js', function(ok){ docsState=ok?2:3; if(openOv===pal) palRender(); }); }
    }
  }
  HA.palette = function(prefill){
    if(!pal){
      pal=makeOv('palette', 'Search');
      pal.innerHTML='<div class="pal"><div class="pal-in">'+I.search+'<input type="text" id="palq" placeholder="Search entries, languages, profiles, docs…" autocomplete="off" spellcheck="false" aria-label="Search" role="combobox" aria-expanded="true" aria-controls="palList"><kbd>esc</kbd></div>'
        + '<div class="pal-list" id="palList" role="listbox"></div>'
        + '<div class="pal-foot"><span><kbd>↑</kbd><kbd>↓</kbd> navigate</span><span><kbd>↵</kbd> open</span><span class="sp"></span><span>tip: <kbd>a</kbd> vs <kbd>b</kbd> compares two entries</span></div></div>';
      palIn=$('#palq', pal); palList=$('#palList', pal);
      palIn.addEventListener('input', function(){ palSel=0; palRender(); });
      palIn.addEventListener('keydown', function(e){
        if(e.key==='ArrowDown'){ e.preventDefault(); palMove(1); }
        else if(e.key==='ArrowUp'){ e.preventDefault(); palMove(-1); }
        else if(e.key==='Enter'){ e.preventDefault(); var it=palItems[palSel]; if(it) it.run(); }
        else if(e.key==='Tab'){ e.preventDefault(); palMove(e.shiftKey?-1:1); }
      });
      palList.addEventListener('click', function(e){ var b=e.target.closest('.pal-i'); if(b){ var it=palItems[+b.getAttribute('data-i')]; if(it) it.run(); } });
      palList.addEventListener('mousemove', function(e){ var b=e.target.closest('.pal-i'); if(!b) return; var i=+b.getAttribute('data-i'); if(i!==palSel){ palSel=i; $all('.pal-i', palList).forEach(function(el,j){ el.classList.toggle('sel', j===palSel); }); } });
    }
    palLoad();
    palIn.value=prefill||''; palSel=0; palRender(); showOv(pal);
    setTimeout(function(){ palIn.focus(); }, 0);
  };
  var pb=document.getElementById('paletteBtn'); if(pb) pb.onclick=function(){ HA.palette(); };

  // ── keyboard shortcuts overlay ───────────────────────────
  var keysOv=null;
  HA.keys = function(){
    if(!keysOv) keysOv=makeOv('keysOv', 'Keyboard shortcuts');
    var groups=[['Everywhere', [
      [['/'],'Search and jump anywhere'], [['Ctrl','K'],'The same, from inside a field'], [['?'],'This list'],
      [['t'],'Light / dark theme'], [['g','l'],'Go to the leaderboard'], [['g','f'],'Go to frameworks'],
      [['g','c'],'Go to comparisons'], [['g','d'],'Go to the Knowledge Base']
    ]]].concat(window.HA_KEYS||[]);
    var h='<div class="keys"><h2>Keyboard shortcuts</h2><p>Single keys work whenever you are not typing in a field.</p>';
    groups.forEach(function(g){
      h+='<h3>'+esc(g[0])+'</h3><dl>';
      g[1].forEach(function(r){ h+='<div><dt>'+esc(r[1])+'</dt><dd>'+r[0].map(function(k){ return k==='…'?'<span>…</span>':'<kbd>'+esc(k)+'</kbd>'; }).join('')+'</dd></div>'; });
      h+='</dl>';
    });
    keysOv.innerHTML=h+'</div>'; showOv(keysOv);
  };

  var gT=0;
  document.addEventListener('keydown', function(e){
    if(e.key==='Escape' && openOv){ e.preventDefault(); hideOv(); return; }
    if((e.ctrlKey||e.metaKey) && !e.altKey && (e.key==='k'||e.key==='K')){ e.preventDefault(); if(openOv===pal && pal) hideOv(); else HA.palette(); return; }
    if(e.ctrlKey||e.metaKey||e.altKey||typing(e)||openOv) return;
    var k=e.key;
    if(gT && Date.now()-gT<900){
      gT=0;
      var to={l:HOME, f:'/frameworks/', c:'/compare/', d:'/docs/'}[k];
      if(to){ e.preventDefault(); e.stopImmediatePropagation(); location.href=to; return; }
    }
    if(k==='/'){ e.preventDefault(); HA.palette(); }
    else if(k==='?'){ e.preventDefault(); HA.keys(); }
    else if(k==='t'){ e.preventDefault(); HA.toggleTheme(); }
    else if(k==='g'){ gT=Date.now(); }
  }, true);

  // ── phone menu ───────────────────────────────────────────
  var mb=document.getElementById('menuBtn'), sheet=null;
  if(mb) mb.onclick=function(){
    if(!sheet){
      sheet=document.createElement('nav'); sheet.className='sheet'; sheet.setAttribute('aria-label','Menu');
      var h='';
      $all('.top-nav a').forEach(function(a){ h+='<a href="'+esc(a.getAttribute('href'))+'"'+(a.classList.contains('on')?' class="on"':'')+'>'+esc(a.textContent)+'</a>'; });
      h+='<hr>';
      $all('.top-links a.x-desk').forEach(function(a){ h+='<a class="ext" href="'+esc(a.getAttribute('href'))+'" target="_blank" rel="noopener">'+a.innerHTML+esc(a.getAttribute('aria-label')||'')+'</a>'; });
      sheet.innerHTML=h; document.body.appendChild(sheet);
      document.addEventListener('click', function(e){ if(sheet.classList.contains('open') && !sheet.contains(e.target) && !mb.contains(e.target)){ sheet.classList.remove('open'); mb.setAttribute('aria-expanded','false'); } });
    }
    var on=sheet.classList.toggle('open'); mb.setAttribute('aria-expanded', on?'true':'false');
  };

  if(ON_BOARD) return;   // everything below is for the generated pages

  // ── Knowledge Base sidebar: accordion, phone toggle, page search ─
  $all('.nav-grp-h .caret').forEach(function(c){
    c.onclick=function(e){ e.preventDefault(); e.stopPropagation(); c.closest('.nav-grp').classList.toggle('open'); };
  });
  var navEl=$('.docs-layout .nav'), ntog=$('.nav-toggle');
  if(navEl && ntog) ntog.onclick=function(){ var on=navEl.classList.toggle('tree-open'); ntog.setAttribute('aria-expanded', on?'true':'false'); };
  var act=$('.nav .nav-item.active, .nav .nav-grp-h.active');
  if(act && navEl && navEl.scrollHeight>navEl.clientHeight){ var ar=act.getBoundingClientRect(), nr=navEl.getBoundingClientRect(); if(ar.bottom>nr.bottom-40) navEl.scrollTop+=ar.top-nr.top-nr.height/3; }
  (function(){
    var inp=document.getElementById('navq'), box=document.getElementById('navResults'), tree=document.getElementById('navTree');
    if(!inp||!box||!tree) return;
    var req=0, cb=null, sel=-1;
    function need(f){ if(window.LB_SEARCH){ f(); return; } cb=f; if(req) return; req=1;
      loadScript('/search.js', function(ok){ if(!ok) req=0; var g=cb; cb=null; if(g) g(); }); }
    inp.addEventListener('focus', function(){ need(function(){}); }, {once:true});
    function snip(x,t){ var i=x.toLowerCase().indexOf(t); if(i<0) return esc(x.slice(0,110));
      var a=Math.max(0,i-45), b=Math.min(x.length,i+t.length+75);
      return (a>0?'…':'')+esc(x.slice(a,i))+'<mark>'+esc(x.slice(i,i+t.length))+'</mark>'+esc(x.slice(i+t.length,b))+(b<x.length?'…':''); }
    function run(){
      var q=inp.value.trim().toLowerCase(); sel=-1;
      if(!q){ box.style.display='none'; tree.style.display=''; inp.setAttribute('aria-expanded','false'); return; }
      var terms=q.split(/\s+/).filter(Boolean), hits=[];
      (window.LB_SEARCH||[]).forEach(function(e){ var t=(e.t||'').toLowerCase(), b=((e.d||'')+' '+(e.x||'')).toLowerCase(), sc=0;
        for(var i=0;i<terms.length;i++){ var ti=t.indexOf(terms[i]), bi=b.indexOf(terms[i]); if(ti<0&&bi<0) return; sc+=ti===0?60:ti>0?35:0; if(bi>=0) sc+=5; }
        if(t===q) sc+=50; hits.push({e:e, sc:sc}); });
      hits.sort(function(a,b){ return b.sc-a.sc || a.e.t.length-b.e.t.length; });
      hits=hits.slice(0,25);
      tree.style.display='none'; box.style.display=''; inp.setAttribute('aria-expanded','true');
      if(navEl) navEl.classList.add('tree-open');
      if(!hits.length){ box.innerHTML='<div class="nav-empty">No page matches <b>'+esc(inp.value)+'</b>.</div>'; return; }
      var h='<div class="nav-res-h"><span>Pages</span><span>'+hits.length+'</span></div>';
      hits.forEach(function(hit){ var e=hit.e;
        h+='<a class="nav-res" role="option" href="/docs/'+(e.u?e.u+'/':'')+'"><span class="nav-res-t">'+esc(e.t)+'</span><span class="nav-res-c">'+esc(e.c||'')+'</span><span class="nav-res-s">'+snip((e.d||'')+' '+(e.x||''), terms[0])+'</span></a>'; });
      box.innerHTML=h; move(1);
    }
    function move(d){ var l=$all('.nav-res', box); if(!l.length) return; sel=(sel+d+l.length)%l.length; l.forEach(function(el,i){ el.classList.toggle('sel', i===sel); if(i===sel) el.scrollIntoView({block:'nearest'}); }); }
    var t; inp.addEventListener('input', function(){ clearTimeout(t); t=setTimeout(function(){ if(!inp.value.trim()) run(); else need(run); }, 90); });
    inp.addEventListener('keydown', function(e){
      if(e.key==='Escape'){ inp.value=''; run(); inp.blur(); }
      else if(e.key==='ArrowDown'){ e.preventDefault(); move(1); }
      else if(e.key==='ArrowUp'){ e.preventDefault(); move(-1); }
      else if(e.key==='Enter'){ var l=$all('.nav-res', box); if(l[sel]){ e.preventDefault(); location.href=l[sel].getAttribute('href'); } }
    });
  })();

  // ── prose: heading anchors, code copy buttons, callouts ──
  $all('.doc-body h2[id], .doc-body h3[id], .doc-body h4[id]').forEach(function(h){
    if(h.closest('.lang-sec')) return;
    var a=document.createElement('a'); a.className='h-anchor'; a.href='#'+h.id; a.setAttribute('aria-label','Link to this section');
    a.addEventListener('click', function(e){ e.preventDefault(); history.replaceState(null,'','#'+h.id); h.scrollIntoView({behavior:'smooth', block:'start'}); HA.copy(location.href, 'Section link copied'); });
    h.appendChild(a);
  });
  $all('.doc-body pre').forEach(function(pre){
    var w=document.createElement('div'); w.className='code-wrap'; pre.parentNode.insertBefore(w, pre); w.appendChild(pre);
    var code=$('code', pre), lang=code && (code.className.match(/language-(\w+)/)||[])[1];
    if(lang){ var l=document.createElement('span'); l.className='code-lang'; l.setAttribute('data-l', lang); w.appendChild(l); }
    var b=document.createElement('button'); b.type='button'; b.className='copy-btn'; b.innerHTML=I.copy+'<span data-l="Copy"></span>'; b.setAttribute('aria-label','Copy code');
    b.onclick=function(){
      HA.copy((code||pre).textContent, 'Code copied');
      b.classList.add('done'); b.innerHTML=I.check+'<span data-l="Copied"></span>';
      setTimeout(function(){ b.classList.remove('done'); b.innerHTML=I.copy+'<span data-l="Copy"></span>'; }, 1600);
    };
    w.appendChild(b);
  });
  $all('.doc-body blockquote').forEach(function(q){
    var t=(q.textContent||'').trim().slice(0,24).toLowerCase();
    if(/^(warning|caution|important|danger|careful)\b/.test(t)) q.classList.add('c-warn');
    else if(/^(tip|hint|good to know)\b/.test(t)) q.classList.add('c-tip');
  });

  // ── "On this page" ───────────────────────────────────────
  (function(){
    var toc=document.getElementById('toc'); if(!toc) return;
    var hs=$all('.doc-wrap .doc-body h2[id], .doc-wrap .doc-body h3[id]');
    var h='';
    if(hs.length>=2){
      h+='<div class="toc-h">On this page</div>';
      hs.forEach(function(x){ var txt=x.textContent.replace(/#$/,'').trim(); h+='<a href="#'+esc(x.id)+'" class="'+(x.tagName==='H3'?'l3':'l2')+'">'+esc(txt)+'</a>'; });
    }
    h+='<div class="toc-tools"><button type="button" id="tocCopy">'+I.copy+'Copy page link</button><button type="button" id="tocTop"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m6 14 6-6 6 6"/></svg>Back to top</button></div>';
    toc.innerHTML=h;
    $('#tocCopy', toc).onclick=function(){ HA.copy(location.href, 'Link copied'); };
    $('#tocTop', toc).onclick=function(){ window.scrollTo({top:0, behavior:'smooth'}); };
    var links=$all('a', toc);
    if(!links.length || !('IntersectionObserver' in window)) return;
    var cur=null;
    function spy(){
      var y=72, best=hs[0];
      for(var i=0;i<hs.length;i++){ if(hs[i].getBoundingClientRect().top-y<=8) best=hs[i]; else break; }
      if(window.innerHeight+window.scrollY>=document.body.scrollHeight-4) best=hs[hs.length-1];
      if(best!==cur){ cur=best; links.forEach(function(a){ a.classList.toggle('on', a.getAttribute('href')==='#'+best.id); }); }
    }
    var tick=0; window.addEventListener('scroll', function(){ if(tick) return; tick=requestAnimationFrame(function(){ tick=0; spy(); }); }, {passive:true});
    spy();
  })();

  // ── sortable tables ──────────────────────────────────────
  $all('table.sortable').forEach(function(tb){
    var ths=$all('thead th', tb), body=tb.tBodies[0]; if(!body) return;
    ths.forEach(function(th, ci){
      if(th.hasAttribute('data-nosort')) return;
      th.tabIndex=0; th.setAttribute('role','columnheader');
      function sort(){
        var asc=th.getAttribute('aria-sort')==='descending' || (!th.getAttribute('aria-sort') && !th.classList.contains('n') && !th.hasAttribute('data-desc'));
        ths.forEach(function(x){ x.removeAttribute('aria-sort'); });
        th.setAttribute('aria-sort', asc?'ascending':'descending');
        var rows=$all('tr', body).map(function(tr,i){ var td=tr.cells[ci], v=td?td.getAttribute('data-v'):null, n=v!==null&&v!==''?parseFloat(v):NaN;
          return {tr:tr, i:i, n:n, s:(td?td.textContent:'').trim().toLowerCase()}; });
        var num=rows.some(function(r){ return !isNaN(r.n); });
        rows.sort(function(a,b){
          if(num){ var an=isNaN(a.n), bn=isNaN(b.n); if(an||bn) return an===bn?a.i-b.i:(an?1:-1); return (a.n-b.n)*(asc?1:-1) || a.i-b.i; }
          return (a.s<b.s?-1:a.s>b.s?1:0)*(asc?1:-1) || a.i-b.i;
        });
        rows.forEach(function(r){ body.appendChild(r.tr); });
      }
      th.addEventListener('click', sort);
      th.addEventListener('keydown', function(e){ if(e.key==='Enter'||e.key===' '){ e.preventDefault(); sort(); } });
    });
  });

  // ── filter on the frameworks index ───────────────────────
  (function(){
    var inp=document.getElementById('fwFilter'), cnt=document.getElementById('fwCount'); if(!inp) return;
    var secs=$all('.lang-sec'), empty=null;
    function run(){
      var terms=inp.value.toLowerCase().split(',').map(function(x){ return x.trim(); }).filter(Boolean), shown=0;
      secs.forEach(function(sec){
        var lang=(sec.getAttribute('data-lang')||'').toLowerCase(), any=0;
        $all('li', sec).forEach(function(li){
          var hay=(li.getAttribute('data-n')||'')+' '+lang+' '+(li.getAttribute('data-k')||'');
          var ok=!terms.length || terms.some(function(t){ return hay.indexOf(t)>=0; });
          li.hidden=!ok; if(ok){ any++; shown++; }
        });
        sec.hidden=!any;
      });
      if(cnt) cnt.textContent=terms.length ? shown+(shown===1?' entry':' entries') : '';
      if(!shown && !empty){ empty=document.createElement('p'); empty.className='t-empty'; empty.textContent='No entry matches that filter.'; secs[secs.length-1].insertAdjacentElement('afterend', empty); }
      if(empty) empty.hidden=shown>0;
    }
    inp.addEventListener('input', run);
    inp.addEventListener('keydown', function(e){ if(e.key==='Escape'){ inp.value=''; run(); inp.blur(); } });
    window.HA_KEYS=(window.HA_KEYS||[]).concat([['This page', [[['s'],'Filter entries']]]]);
    document.addEventListener('keydown', function(e){ if(e.key==='s' && !typing(e) && !e.ctrlKey && !e.metaKey && !e.altKey && !HA.overlayOpen()){ e.preventDefault(); inp.focus(); inp.select(); } });
  })();
})();
