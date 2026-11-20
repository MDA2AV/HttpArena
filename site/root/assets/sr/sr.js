/* HttpArena "Server Room": the script every generated page shares.
   Theme toggle (localStorage key lb-theme, the board's own), the data-tip
   tooltips of the header, and the hardware's motion: LEDs and fans carry
   .live only while they are on screen, and the stylesheet runs their
   animation only then. */
(function(){
  "use strict";
  var d=document.documentElement;
  var b=document.getElementById('theme');
  if(b) b.onclick=function(){
    var c=d.getAttribute('data-theme')==='dark'||(d.getAttribute('data-theme')!=='light'&&matchMedia('(prefers-color-scheme: dark)').matches);
    var n=c?'light':'dark'; d.setAttribute('data-theme',n);
    try{ localStorage.setItem('lb-theme',n); }catch(e){}
  };
  // tooltips
  var tip=document.createElement('div'); tip.id='tip'; document.body.appendChild(tip);
  function pos(el){ var r=el.getBoundingClientRect(); tip.style.display='block'; var tw=tip.offsetWidth, th=tip.offsetHeight;
    var l=r.left+r.width/2-tw/2, t=r.top-th-8; if(t<6) t=r.bottom+8;
    l=Math.max(6,Math.min(l,window.innerWidth-tw-6)); tip.style.left=l+'px'; tip.style.top=t+'px'; }
  document.addEventListener('mouseover', function(e){ var el=e.target.closest?e.target.closest('[data-tip]'):null; if(!el) return; tip.textContent=el.getAttribute('data-tip'); pos(el); });
  document.addEventListener('mouseout', function(e){ var el=e.target.closest?e.target.closest('[data-tip]'):null; if(el && !el.contains(e.relatedTarget)) tip.style.display='none'; });
  document.addEventListener('scroll', function(){ tip.style.display='none'; }, true);
  // motion only while on screen
  var live=document.querySelectorAll('[data-live]');
  if('IntersectionObserver' in window){
    var io=new IntersectionObserver(function(es){ es.forEach(function(x){ x.target.classList.toggle('live', x.isIntersecting); }); }, {rootMargin:'40px 0px'});
    Array.prototype.forEach.call(live, function(el){ io.observe(el); });
  } else Array.prototype.forEach.call(live, function(el){ el.classList.add('live'); });
  // The page search in the header: the Knowledge Base, from search.js, which
  // is fetched the first time the box is used. Results drop down under it.
  (function(){
    var inp=document.getElementById('navq'), box=document.getElementById('navResults');
    if(!inp||!box) return;
    var req=null, cb=null, t=null;
    function need(f){
      if(window.LB_SEARCH){ f(); return; }
      cb=f; if(req) return;
      req=document.createElement('script'); req.src='/search.js';
      req.onload=function(){ var g=cb; cb=null; if(g) g(); };
      // on failure too, so the box says "no page matches" rather than staying
      // blank, and a later keystroke can try the fetch again
      req.onerror=function(){ req=null; var g=cb; cb=null; if(g) g(); };
      document.head.appendChild(req);
    }
    function esc(s){ return String(s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
    function snip(x,q){ var i=x.toLowerCase().indexOf(q); if(i<0) return esc(x.slice(0,110));
      var a=Math.max(0,i-45), b=Math.min(x.length,i+q.length+75);
      return (a>0?'\u2026':'')+esc(x.slice(a,i))+'<mark>'+esc(x.slice(i,i+q.length))+'</mark>'+esc(x.slice(i+q.length,b))+(b<x.length?'\u2026':''); }
    function run(){
      var q=inp.value.trim().toLowerCase();
      if(!q){ box.style.display='none'; inp.setAttribute('aria-expanded','false'); return; }
      var terms=q.split(/\s+/).filter(Boolean), hits=[];
      (window.LB_SEARCH||[]).forEach(function(e){
        var ti=(e.t||'').toLowerCase(), bo=((e.d||'')+' '+(e.x||'')).toLowerCase(), sc=0;
        for(var i=0;i<terms.length;i++){ var a=ti.indexOf(terms[i]), b=bo.indexOf(terms[i]); if(a<0&&b<0) return; sc+=a===0?60:a>0?35:0; if(b>=0) sc+=5; }
        if(ti===q) sc+=50; hits.push({e:e, sc:sc});
      });
      hits.sort(function(a,b){ return b.sc-a.sc || a.e.t.length-b.e.t.length; }); hits=hits.slice(0,25);
      box.style.display=''; inp.setAttribute('aria-expanded','true');
      if(!hits.length){ box.innerHTML='<div class="nav-empty">No page matches <b>'+esc(inp.value)+'</b>.</div>'; return; }
      box.innerHTML='<div class="nav-res-h"><span>Pages</span><span>'+hits.length+'</span></div>'+hits.map(function(h){ var e=h.e;
        return '<a class="nav-res" href="/docs/'+(e.u?e.u+'/':'')+'"><span class="nav-res-t">'+esc(e.t)+'</span><span class="nav-res-c">'+esc(e.c||'')+'</span>'
          +'<span class="nav-res-s">'+snip((e.d||'')+' '+(e.x||''), terms[0])+'</span></a>'; }).join('');
    }
    inp.addEventListener('focus', function(){ need(function(){}); }, {once:true});
    inp.addEventListener('input', function(){ clearTimeout(t); t=setTimeout(function(){ if(!inp.value.trim()) run(); else need(run); }, 90); });
    inp.addEventListener('keydown', function(e){ if(e.key==='Escape'){ inp.value=''; run(); inp.blur(); } });
    document.addEventListener('click', function(e){ if(!inp.closest('.nav-search').contains(e.target)) box.style.display='none'; });
  })();
  // the contents drawer of the runbook on a phone
  var tb=document.getElementById('tocBtn'), nav=document.querySelector('aside.nav');
  if(tb && nav) tb.onclick=function(){ var o=nav.classList.toggle('open'); tb.setAttribute('aria-expanded', o?'true':'false'); };
})();
