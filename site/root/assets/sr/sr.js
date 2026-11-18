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
  // the contents drawer of the runbook on a phone
  var tb=document.getElementById('tocBtn'), nav=document.querySelector('aside.nav');
  if(tb && nav) tb.onclick=function(){ var o=nav.classList.toggle('open'); tb.setAttribute('aria-expanded', o?'true':'false'); };
})();
