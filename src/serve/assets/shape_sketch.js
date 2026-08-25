// Parametric closed-shape sketch kernel. Board outlines and custom copper pours
// use this same dependency-free engine; geometry stays in world millimetres.
(function (root, factory) {
  "use strict";
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  if (root) {
    root.PCBShapeSketch = api;
    // Compatibility for the DXF importer and older cached board scripts.
    root.PCBOutlineSketch = api;
  }
})(typeof window !== "undefined" ? window : this, function () {
  "use strict";

  var VERSION = 1, SAG = 0.01, TAU = Math.PI * 2;
  var DIM_KINDS = {distance_x:1,distance_y:1,distance:1,length:1,angle:1,radius:1,diameter:1};

  function cp(v) { return JSON.parse(JSON.stringify(v)); }
  function finite(v) { return typeof v === "number" && isFinite(v); }
  function point(s, id) { for (var i=0;i<s.points.length;i++) if (s.points[i].id===id) return s.points[i]; return null; }
  function curve(s, id) { for (var i=0;i<s.curves.length;i++) if (s.curves[i].id===id) return s.curves[i]; return null; }
  function nextId(s) { var n=0; s.points.concat(s.curves,s.constraints||[]).forEach(function(e){n=Math.max(n,+e.id||0);}); return n+1; }
  function physicalCurves(s) { return (s.curves||[]).filter(function(c){return !c.construction;}); }
  // Every point referenced by physical geometry, in stable curve order. Closed
  // profiles naturally contribute each point once; open/disconnected sketches
  // also expose their loose endpoints for selection and endpoint snapping.
  function physicalPoints(s) { var out=[],seen={};physicalCurves(s).forEach(function(c){[c.a,c.b].forEach(function(id){if(seen[id])return;var p=point(s,id);if(p){seen[id]=1;out.push(p);}});});return out; }
  function dist(a,b) { return Math.hypot(b.x-a.x,b.y-a.y); }
  function lineDir(s,c) { var a=point(s,c.a),b=point(s,c.b),d=a&&b?dist(a,b):0; return d>1e-12?{x:(b.x-a.x)/d,y:(b.y-a.y)/d}:null; }
  function wrapAngle(a) { while(a>Math.PI)a-=TAU; while(a<-Math.PI)a+=TAU; return a; }

  function arcCircle(s,c) {
    if (!c || c.kind!=="arc" || !c.mid) return null;
    var a=point(s,c.a),b={x:+c.mid[0],y:+c.mid[1]},z=point(s,c.b);
    if(!a||!z)return null;
    var d=2*(a.x*(b.y-z.y)+b.x*(z.y-a.y)+z.x*(a.y-b.y));
    if(Math.abs(d)<1e-12)return null;
    var aa=a.x*a.x+a.y*a.y,bb=b.x*b.x+b.y*b.y,zz=z.x*z.x+z.y*z.y;
    var cx=(aa*(b.y-z.y)+bb*(z.y-a.y)+zz*(a.y-b.y))/d;
    var cy=(aa*(z.x-b.x)+bb*(a.x-z.x)+zz*(b.x-a.x))/d;
    var start=Math.atan2(a.y-cy,a.x-cx),mid=Math.atan2(b.y-cy,b.x-cx),end=Math.atan2(z.y-cy,z.x-cx);
    var me=(mid-start+TAU)%TAU,ee=(end-start+TAU)%TAU;
    return {cx:cx,cy:cy,r:Math.hypot(a.x-cx,a.y-cy),start:start,sweep:me<=ee?ee:ee-TAU};
  }
  function tangentAt(s,c,pid) {
    if(c.kind==="line")return lineDir(s,c);
    var g=arcCircle(s,c),p=point(s,pid);if(!g||!p)return null;
    var sign=g.sweep>=0?1:-1,rx=(p.x-g.cx)/g.r,ry=(p.y-g.cy)/g.r;
    return {x:-ry*sign,y:rx*sign};
  }
  function sharedPoint(a,b) { if(a.a===b.a||a.a===b.b)return a.a;if(a.b===b.a||a.b===b.b)return a.b;return null; }

  function validSketch(s) {
    if(!s||s.version!==VERSION||!Array.isArray(s.points)||!Array.isArray(s.curves))return false;
    var seen={},pcs=physicalCurves(s);
    for(var i=0;i<s.points.length;i++){var p=s.points[i];if(!p||!p.id||seen[p.id]||!finite(+p.x)||!finite(+p.y))return false;seen[p.id]=1;}
    for(i=0;i<s.curves.length;i++){var c=s.curves[i];if(!c||!c.id||seen[c.id]||!point(s,c.a)||!point(s,c.b)||(c.kind!=="line"&&c.kind!=="arc"))return false;seen[c.id]=1;if(c.kind==="arc"&&(!c.mid||!finite(+c.mid[0])||!finite(+c.mid[1])))return false;}
    return true;
  }
  // Return a traversal of one closed, non-branching physical loop regardless
  // of curve array order/direction. Open sketch geometry remains structurally
  // valid, but has no fabrication traversal until its loose endpoints join.
  function closedOrder(s) { var pcs=physicalCurves(s);if(pcs.length<3)return null;var incident={};
    pcs.forEach(function(c){(incident[c.a]||(incident[c.a]=[])).push(c);(incident[c.b]||(incident[c.b]=[])).push(c);});
    var ids=Object.keys(incident);for(var i=0;i<ids.length;i++)if(incident[ids[i]].length!==2)return null;
    var used={},out=[],first=pcs[0].a,at=first,c=pcs[0];
    for(i=0;i<pcs.length;i++){if(!c||used[c.id])return null;var reverse=c.b===at;if(c.a!==at&&!reverse)return null;used[c.id]=1;out.push({curve:c,reverse:reverse});at=reverse?c.a:c.b;
      if(i+1<pcs.length){var pair=incident[at]||[];c=used[pair[0]&&pair[0].id]?pair[1]:pair[0];}}
    return at===first&&out.length===pcs.length?out:null;
  }
  function isClosed(s){return !!closedOrder(s);}
  function normalize(s){var order=closedOrder(s);if(!order)return false;var construction=(s.curves||[]).filter(function(c){return c.construction;});
    s.curves=order.map(function(e){var c=e.curve;if(e.reverse){var a=c.a;c.a=c.b;c.b=a;}return c;}).concat(construction);return true;}
  function cornerFillet(a,b,c,want) {
    want=+want||0;if(!(want>0))return null;var x1=b[0]-a[0],y1=b[1]-a[1],x2=c[0]-b[0],y2=c[1]-b[1];
    var l1=Math.hypot(x1,y1),l2=Math.hypot(x2,y2);if(l1<1e-6||l2<1e-6)return null;
    var ux=x1/l1,uy=y1/l1,vx=x2/l2,vy=y2/l2,dot=Math.max(-1,Math.min(1,ux*vx+uy*vy)),cross=ux*vy-uy*vx;
    if(Math.abs(cross)<1e-6||dot<-.995)return null;var tangent=Math.tan(Math.acos(dot)/2);if(!(tangent>1e-6))return null;
    var trim=Math.min(want*tangent,l1*.45,l2*.45);if(trim<.01)return null;var radius=trim/tangent,sign=cross<0?-1:1;
    var p1=[b[0]-ux*trim,b[1]-uy*trim],p2=[b[0]+vx*trim,b[1]+vy*trim],cx=p1[0]-uy*sign*radius,cy=p1[1]+ux*sign*radius;
    var start=Math.atan2(p1[1]-cy,p1[0]-cx),finish=Math.atan2(p2[1]-cy,p2[0]-cx),sweep=finish-start;
    if(sign>0){while(sweep<0)sweep+=TAU;while(sweep>TAU)sweep-=TAU;}else{while(sweep>0)sweep-=TAU;while(sweep<-TAU)sweep+=TAU;}
    if(Math.abs(sweep)>Math.PI+1e-6)return null;var ma=start+sweep/2;
    return {p1:p1,p2:p2,mid:[cx+radius*Math.cos(ma),cy+radius*Math.sin(ma)]};
  }
  function fromSegments(segments) {
    var s={version:VERSION,points:[],curves:[],constraints:[]};if(!segments||!segments.length)return s;
    s.points.push({id:1,x:+segments[0].a[0],y:+segments[0].a[1]});var last=1;
    segments.forEach(function(seg,si){var bid=si===segments.length-1?1:s.points.length+1;if(si<segments.length-1)s.points.push({id:bid,x:+seg.b[0],y:+seg.b[1]});
      var c={id:1001+si,kind:seg.kind,a:last,b:bid};if(seg.mid)c.mid=[+seg.mid[0],+seg.mid[1]];s.curves.push(c);last=bid;});
    return s;
  }
  function fromOutline(o) {
    var raw=o&&o.pts&&o.pts.length>=3?o.pts:[[o.x,o.y],[o.x+o.w,o.y],[o.x+o.w,o.y+o.h],[o.x,o.y+o.h]];
    var radii=o&&o.radii&&o.radii.length===raw.length?o.radii:null,segments=[],fillets=[],i,n=raw.length;
    if(radii){for(i=0;i<n;i++)fillets.push(cornerFillet(raw[(i+n-1)%n],raw[i],raw[(i+1)%n],radii[i]));
      for(i=0;i<n;i++){var prev=fillets[(i+n-1)%n],cur=fillets[i],start=prev?prev.p2:raw[(i+n-1)%n],end=cur?cur.p1:raw[i];
        if(Math.hypot(end[0]-start[0],end[1]-start[1])>1e-9)segments.push({kind:"line",a:start,b:end});
        if(cur)segments.push({kind:"arc",a:cur.p1,b:cur.p2,mid:cur.mid});}}
    else for(i=0;i<n;i++)segments.push({kind:"line",a:raw[i],b:raw[(i+1)%n]});
    var s=fromSegments(segments);if(!segments.length)return s;
    // Exact axes are safe legacy intent: they describe the geometry already on
    // disk and make rectangles retain their shape on the first precise edit.
    s.curves.forEach(function(c){if(c.kind!=="line")return;var a=point(s,c.a),b=point(s,c.b);
      if(Math.abs(a.y-b.y)<1e-9)s.constraints.push({id:2001+s.constraints.length,kind:"horizontal",a:c.id,driving:true,enabled:true});
      else if(Math.abs(a.x-b.x)<1e-9)s.constraints.push({id:2001+s.constraints.length,kind:"vertical",a:c.id,driving:true,enabled:true});});
    return s;
  }
  function ensure(o) { if(!o)return null;if(!validSketch(o.sketch))o.sketch=fromOutline(o);o.radii=null;syncOutline(o);return o.sketch; }

  // Copper pours persist their fabrication fallback as `poly` rather than the
  // outline model's `pts` + bbox. These adapters keep the authoring sketch
  // generic while every fill/DRC/export consumer continues reading `poly`.
  function fromPolygon(poly) { return fromOutline({pts:poly||[]}); }
  function syncPolygon(o) { var g=o&&compile(o.sketch);if(!g)return null;o.poly=g.points;return g; }
  function ensurePolygon(o) { if(!o)return null;if(!validSketch(o.sketch))o.sketch=fromPolygon(o.poly);syncPolygon(o);return o.sketch; }

  function compile(s,sag) {
    if(!validSketch(s))return null;sag=Math.max(0.0001,+sag||SAG);
    var pcs=physicalCurves(s),closed=closedOrder(s),walk=closed?closed.map(function(e){return {curve:e.curve,reverse:e.reverse};}):pcs.map(function(c){return {curve:c,reverse:false};}),poly=[],arcs=[],ordered=[];
    function push(x,y){var q=poly[poly.length-1];if(!q||Math.hypot(q[0]-x,q[1]-y)>1e-9)poly.push([x,y]);}
    for(var i=0;i<walk.length;i++){var c=walk[i].curve,a=point(s,walk[i].reverse?c.b:c.a),b=point(s,walk[i].reverse?c.a:c.b);ordered.push([a.x,a.y]);
      if(c.kind==="line"){push(a.x,a.y);if(!closed)push(b.x,b.y);continue;}
      var g=arcCircle(s,c);if(!g||!finite(g.r)||g.r<1e-9)return null;
      if(walk[i].reverse){g={cx:g.cx,cy:g.cy,r:g.r,start:g.start+g.sweep,sweep:-g.sweep};}
      var step=g.r<=sag?Math.abs(g.sweep):2*Math.acos(Math.max(-1,Math.min(1,1-sag/g.r)));
      var count=Math.max(1,Math.min(256,Math.ceil(Math.abs(g.sweep)/Math.max(step,0.001))));
      for(var k=0;k<count;k++){var ang=g.start+g.sweep*k/count;push(g.cx+g.r*Math.cos(ang),g.cy+g.r*Math.sin(ang));}
      if(!closed)push(b.x,b.y);
      arcs.push({curve:c.id,p1:[a.x,a.y],pm:[+c.mid[0],+c.mid[1]],p2:[b.x,b.y],cx:g.cx,cy:g.cy,radius:g.r,start_angle:g.start,sweep:g.sweep});}
    if(!closed)ordered=physicalPoints(s).map(function(p){return [p.x,p.y];});
    var minx=Infinity,miny=Infinity,maxx=-Infinity,maxy=-Infinity;
    poly.forEach(function(p){minx=Math.min(minx,p[0]);miny=Math.min(miny,p[1]);maxx=Math.max(maxx,p[0]);maxy=Math.max(maxy,p[1]);});
    return {points:poly,nominal:ordered,arcs:arcs,curves:pcs,closed:!!closed,rect:poly.length?{x:minx,y:miny,w:maxx-minx,h:maxy-miny}:null};
  }
  function syncOutline(o) { var g=compile(o.sketch);if(!g)return null;o.pts=g.nominal;if(g.rect){o.x=g.rect.x;o.y=g.rect.y;o.w=g.rect.w;o.h=g.rect.h;}return g; }

  function variables(s) {
    var out=[];s.points.forEach(function(p){out.push({kind:"px",e:p},{kind:"py",e:p});});
    s.curves.forEach(function(c){if(c.kind==="arc"){out.push({kind:"mx",e:c},{kind:"my",e:c});}});return out;
  }
  function readVars(vars){return vars.map(function(v){return v.kind==="px"?v.e.x:v.kind==="py"?v.e.y:v.kind==="mx"?v.e.mid[0]:v.e.mid[1];});}
  function writeVars(vars,x){vars.forEach(function(v,i){if(v.kind==="px")v.e.x=x[i];else if(v.kind==="py")v.e.y=x[i];else if(v.kind==="mx")v.e.mid[0]=x[i];else v.e.mid[1]=x[i];});}
  function entityLength(s,id){var c=curve(s,id);if(!c)return NaN;if(c.kind==="line")return dist(point(s,c.a),point(s,c.b));var g=arcCircle(s,c);return g?g.r:NaN;}
  function pointLineResidual(p,a,b){var dx=b.x-a.x,dy=b.y-a.y,l=Math.hypot(dx,dy)||1;return ((p.x-a.x)*dy-(p.y-a.y)*dx)/l;}

  function residuals(s,fixed,targets) {
    var out=[];
    function add(v,w){if(finite(v))out.push(v*(w==null?1:w));}
    (s.constraints||[]).forEach(function(q){if(q.enabled===false||q.driving===false)return;
      var a=point(s,q.a),b=q.b!=null?point(s,q.b):null,ca=curve(s,q.a),cb=q.b!=null?curve(s,q.b):null,v=+q.value;
      if(q.kind==="horizontal"&&ca){a=point(s,ca.a);b=point(s,ca.b);add(b.y-a.y);}
      else if(q.kind==="vertical"&&ca){a=point(s,ca.a);b=point(s,ca.b);add(b.x-a.x);}
      else if(q.kind==="coincident"&&a&&b){add(b.x-a.x);add(b.y-a.y);}
      else if(q.kind==="distance_x"&&a&&b&&finite(v))add((b.x-a.x)-v);
      else if(q.kind==="distance_y"&&a&&b&&finite(v))add((b.y-a.y)-v);
      else if(q.kind==="distance"&&a&&b&&finite(v))add(dist(a,b)-v);
      else if(q.kind==="length"&&ca&&finite(v))add(entityLength(s,ca.id)-v);
      else if((q.kind==="radius"||q.kind==="diameter")&&ca&&finite(v)){var ag=arcCircle(s,ca);if(ag)add(ag.r-(q.kind==="diameter"?v/2:v));}
      else if(q.kind==="angle"&&ca&&finite(v)){var d=lineDir(s,ca);if(d)add(wrapAngle(Math.atan2(d.y,d.x)-v*Math.PI/180));}
      else if((q.kind==="parallel"||q.kind==="perpendicular")&&ca&&cb){var da=lineDir(s,ca),db=lineDir(s,cb);if(da&&db)add(q.kind==="parallel"?da.x*db.y-da.y*db.x:da.x*db.x+da.y*db.y);}
      else if(q.kind==="equal"&&ca&&cb)add(entityLength(s,ca.id)-entityLength(s,cb.id));
      else if(q.kind==="midpoint"&&a&&cb){var ma=point(s,cb.a),mb=point(s,cb.b);add(a.x-(ma.x+mb.x)/2);add(a.y-(ma.y+mb.y)/2);}
      else if(q.kind==="tangent"&&ca&&cb){var pid=sharedPoint(ca,cb),ta=pid&&tangentAt(s,ca,pid),tb=pid&&tangentAt(s,cb,pid);if(ta&&tb)add(ta.x*tb.y-ta.y*tb.x);}
      else if(q.kind==="symmetric"&&a&&b&&q.c!=null){var axis=curve(s,q.c);if(axis){var la=point(s,axis.a),lb=point(s,axis.b),mid={x:(a.x+b.x)/2,y:(a.y+b.y)/2},ad=lineDir(s,axis);add(pointLineResidual(mid,la,lb));if(ad)add((b.x-a.x)*ad.x+(b.y-a.y)*ad.y);}}
      else if(q.kind==="fixed"&&a&&fixed[q.a]){add(a.x-fixed[q.a].x,10);add(a.y-fixed[q.a].y,10);}
    });
    (targets||[]).forEach(function(t){if(t.arc!=null){var ac=curve(s,t.arc);if(ac&&ac.kind==="arc"&&ac.mid){add(ac.mid[0]-t.x,t.weight||25);add(ac.mid[1]-t.y,t.weight||25);}return;}var p=point(s,t.id);if(p){add(p.x-t.x,t.weight||25);add(p.y-t.y,t.weight||25);}});
    return out;
  }
  function gaussian(a,b) {
    var n=b.length,i,j,k,p,tmp;
    for(i=0;i<n;i++){p=i;for(j=i+1;j<n;j++)if(Math.abs(a[j][i])>Math.abs(a[p][i]))p=j;
      if(Math.abs(a[p][i])<1e-12)return null;tmp=a[i];a[i]=a[p];a[p]=tmp;tmp=b[i];b[i]=b[p];b[p]=tmp;
      for(j=i+1;j<n;j++){var f=a[j][i]/a[i][i];if(!finite(f))return null;for(k=i;k<n;k++)a[j][k]-=f*a[i][k];b[j]-=f*b[i];}}
    var x=new Array(n);for(i=n-1;i>=0;i--){var s=b[i];for(j=i+1;j<n;j++)s-=a[i][j]*x[j];x[i]=s/a[i][i];}return x;
  }
  function jacobian(s,vars,x,fixed,targets,base) {
    var eps=1e-5,j=new Array(base.length);for(var r=0;r<base.length;r++)j[r]=new Array(vars.length);
    for(var c=0;c<vars.length;c++){var old=x[c],h=eps*Math.max(1,Math.abs(old));x[c]=old+h;writeVars(vars,x);var rr=residuals(s,fixed,targets);x[c]=old;
      for(r=0;r<base.length;r++)j[r][c]=((rr[r]==null?base[r]:rr[r])-base[r])/h;}
    writeVars(vars,x);return j;
  }
  function matrixRank(m,tol) {
    if(!m.length)return 0;var a=m.map(function(r){return r.slice();}),rows=a.length,cols=a[0].length,rank=0,c=0;
    while(rank<rows&&c<cols){var p=rank;for(var r=rank+1;r<rows;r++)if(Math.abs(a[r][c])>Math.abs(a[p][c]))p=r;
      if(Math.abs(a[p][c])<tol){c++;continue;}var t=a[rank];a[rank]=a[p];a[p]=t;
      for(r=rank+1;r<rows;r++){var f=a[r][c]/a[rank][c];for(var k=c;k<cols;k++)a[r][k]-=f*a[rank][k];}rank++;c++;}return rank;
  }
  function solve(s,opts) {
    opts=opts||{};var vars=variables(s),x=readVars(vars),home=x.slice(),fixed={};
    (s.constraints||[]).forEach(function(q){if(q.kind==="fixed"){var p=point(s,q.a);if(p)fixed[q.a]={x:p.x,y:p.y};}});
    var max=Infinity,it=0,j=[],base=[];
    for(;it<(opts.iterations||14);it++){writeVars(vars,x);base=residuals(s,fixed,opts.targets);max=base.reduce(function(m,v){return Math.max(m,Math.abs(v));},0);if(max<1e-7)break;
      j=jacobian(s,vars,x,fixed,opts.targets,base);var n=vars.length,a=new Array(n),b=new Array(n),lambda=1e-5,stay=opts.stay==null?1e-5:+opts.stay;
      for(var c=0;c<n;c++){a[c]=new Array(n);b[c]=stay*(home[c]-x[c]);for(var d=0;d<n;d++){var sum=0;for(var r=0;r<base.length;r++)sum+=j[r][c]*j[r][d];a[c][d]=sum+(c===d?lambda+stay:0);}for(r=0;r<base.length;r++)b[c]-=j[r][c]*base[r];}
      var dx=gaussian(a,b);if(!dx)break;var step=0;for(c=0;c<n;c++){x[c]+=dx[c];step=Math.max(step,Math.abs(dx[c]));}if(step<1e-8)break;}
    writeVars(vars,x);base=residuals(s,fixed,[]);j=jacobian(s,vars,x,fixed,[],base);
    var rank=matrixRank(j,1e-7),dof=Math.max(0,vars.length-rank),residual=base.reduce(function(m,v){return Math.max(m,Math.abs(v));},0),conflict=residual>1e-4;
    // A failed solve is transactional: direct drags and addConstraint both
    // call this kernel, and neither may leave an unsavable half-solved shape.
    if(conflict)writeVars(vars,home);
    return {ok:!conflict,conflict:conflict,dof:dof,residual:residual,iterations:it};
  }

  function addConstraint(s,kind,a,b,value,c) {
    var q={id:nextId(s),kind:kind,a:a,driving:true,enabled:true};if(b!=null)q.b=b;if(value!=null)q.value=+value;if(c!=null)q.c=c;
    s.constraints=s.constraints||[];s.constraints.push(q);var result=solve(s);if(result.conflict){s.constraints.pop();return null;}return q;
  }
  function removeConstraint(s,id){s.constraints=(s.constraints||[]).filter(function(q){return q.id!==id;});return solve(s);}
  // An endpoint drag edits the length of an axis-constrained line instead of
  // translating the line sideways.  The constraint solver treats drag targets
  // as soft but high-weight residuals, so feeding it the raw cursor coordinate
  // would otherwise make both endpoints follow that coordinate while still
  // remaining horizontal/vertical.  At a rectangular corner both constraints
  // are incident; use the cursor's dominant direction to choose the segment
  // whose length the user is changing rather than locking the corner entirely.
  function pointDragAxis(s,id,x,y,origin){var p=point(s,id),horizontal=false,vertical=false;if(!p)return null;
    (s.constraints||[]).forEach(function(q){if(q.enabled===false||q.driving===false||(q.kind!=="horizontal"&&q.kind!=="vertical"))return;var c=curve(s,q.a);if(!c||(c.a!==id&&c.b!==id))return;if(q.kind==="horizontal")horizontal=true;else vertical=true;});
    if(horizontal&&vertical){origin=origin||p;return Math.abs(x-origin.x)>=Math.abs(y-origin.y)?"horizontal":"vertical";}
    return horizontal?"horizontal":vertical?"vertical":null;}
  function pointDragTarget(s,id,x,y,axis){var p=point(s,id);if(!p)return {x:x,y:y};axis=axis===undefined?pointDragAxis(s,id,x,y,p):axis;
    if(axis==="horizontal")y=p.y;else if(axis==="vertical")x=p.x;
    return {x:x,y:y};}
  function movePoint(s,id,x,y,axis){var target=pointDragTarget(s,id,x,y,axis);return solve(s,{targets:[{id:id,x:target.x,y:target.y,weight:50}],iterations:10,stay:1e-4});}
  // A tangent arc between the dragged line and its next straight neighbour is
  // a fillet, not an independently deformable curve. Record its three-point
  // geometry so a line slide can carry the whole arc rigidly and move only the
  // joined endpoint of the outer line (which then merely changes length).
  function rigidFilletAt(s,host,pid){if(!host||host.kind!=="line")return null;var pcs=physicalCurves(s),hit=pcs.filter(function(c){return c!==host&&(c.a===pid||c.b===pid);});
    if(hit.length!==1||hit[0].kind!=="arc")return null;var arc=hit[0],farId=arc.a===pid?arc.b:arc.a,outer=pcs.filter(function(c){return c!==arc&&(c.a===farId||c.b===farId);});
    if(outer.length!==1||outer[0].kind!=="line")return null;var ht=tangentAt(s,host,pid),an=tangentAt(s,arc,pid),af=tangentAt(s,arc,farId),ot=tangentAt(s,outer[0],farId);
    if(!ht||!an||!af||!ot||Math.abs(ht.x*an.y-ht.y*an.x)>1e-5||Math.abs(af.x*ot.y-af.y*ot.x)>1e-5)return null;
    var near=point(s,pid),far=point(s,farId);return {arc:arc,near:near,far:far,nx:near.x,ny:near.y,fx:far.x,fy:far.y,mx:+arc.mid[0],my:+arc.mid[1]};}
  function moveCurve(s,id,dx,dy){var c=curve(s,id);if(!c)return null;var a=point(s,c.a),b=point(s,c.b),fillets=[],fa=rigidFilletAt(s,c,c.a),fb=rigidFilletAt(s,c,c.b),targets=[{id:a.id,x:a.x+dx,y:a.y+dy,weight:50},{id:b.id,x:b.x+dx,y:b.y+dy,weight:50}];
    if(fa)fillets.push(fa);if(fb&&(!fa||fb.arc!==fa.arc))fillets.push(fb);fillets.forEach(function(f){targets.push({id:f.far.id,x:f.fx+dx,y:f.fy+dy,weight:50},{arc:f.arc.id,x:f.mx+dx,y:f.my+dy,weight:50});});
    var result=solve(s,{targets:targets,iterations:10,stay:1e-4});if(result.conflict)return result;
    // The solver honours surrounding dimensions/axes, then the actual motion
    // of the shared tangent point supplies one exact translation for all three
    // arc points. This last assignment keeps radius, sweep and shape invariant
    // instead of leaving them merely close under a weighted numeric solve.
    fillets.forEach(function(f){var tx=f.near.x-f.nx,ty=f.near.y-f.ny;f.far.x=f.fx+tx;f.far.y=f.fy+ty;f.arc.mid[0]=f.mx+tx;f.arc.mid[1]=f.my+ty;});return result;}
  function insertPoint(s,curveId,x,y){var idx=s.curves.findIndex(function(c){return c.id===curveId;}),c=idx>=0?s.curves[idx]:null;if(!c||c.construction)return null;
    var pid=nextId(s),cid=pid+1,oldb=c.b;c.b=pid;c.kind="line";delete c.mid;s.points.push({id:pid,x:x,y:y});s.curves.splice(idx+1,0,{id:cid,kind:"line",a:pid,b:oldb});return pid;}
  function dropEntities(s,pointIds,curveIds){var ps={},cs={};(pointIds||[]).forEach(function(id){ps[id]=1;});(curveIds||[]).forEach(function(id){cs[id]=1;});
    s.curves=s.curves.filter(function(c){return !cs[c.id];});s.points=s.points.filter(function(p){return !ps[p.id];});s.constraints=(s.constraints||[]).filter(function(q){return !ps[q.a]&&!ps[q.b]&&!ps[q.c]&&!cs[q.a]&&!cs[q.b]&&!cs[q.c];});}
  // Fusion-style erase: deleting a vertex removes the geometry incident to
  // that point and leaves loose endpoints. It never invents a healing segment.
  function deletePoint(s,pid){if(!point(s,pid))return false;var hit=physicalCurves(s).filter(function(c){return c.a===pid||c.b===pid;});if(!hit.length)return false;
    dropEntities(s,[pid],hit.map(function(c){return c.id;}));return true;}
  function toArc(s,cid,mid){var c=curve(s,cid);if(!c||c.construction)return false;c.kind="arc";c.mid=[+mid[0],+mid[1]];return !!arcCircle(s,c);}
  function toLine(s,cid){var c=curve(s,cid);if(!c)return false;c.kind="line";delete c.mid;s.constraints=(s.constraints||[]).filter(function(q){return !((q.kind==="radius"||q.kind==="diameter")&&q.a===cid);});return true;}
  function cornerCurves(s,pid){var pcs=physicalCurves(s),prev=null,next=null;pcs.forEach(function(c){if(c.b===pid)prev=c;if(c.a===pid)next=c;});return prev&&next?{prev:prev,next:next}:null;}
  function splitCorner(s,pid,radius,chamfer){var pair=cornerCurves(s,pid);if(!pair||pair.prev.kind!=="line"||pair.next.kind!=="line")return false;
    var a=point(s,pair.prev.a),b=point(s,pid),c=point(s,pair.next.b),f;
    if(chamfer){var l1=dist(a,b),l2=dist(b,c),d=Math.min(Math.max(.001,+radius||0),l1*.45,l2*.45);if(!(d>0))return false;
      f={p1:[b.x+(a.x-b.x)*d/l1,b.y+(a.y-b.y)*d/l1],p2:[b.x+(c.x-b.x)*d/l2,b.y+(c.y-b.y)*d/l2]};}
    else f=cornerFillet([a.x,a.y],[b.x,b.y],[c.x,c.y],radius);
    if(!f)return false;var npid=nextId(s),ncid=npid+1;b.x=f.p1[0];b.y=f.p1[1];s.points.push({id:npid,x:f.p2[0],y:f.p2[1]});pair.next.a=npid;
    var insert=s.curves.indexOf(pair.next),bridge={id:ncid,kind:chamfer?"line":"arc",a:pid,b:npid};if(f.mid)bridge.mid=f.mid.slice();s.curves.splice(insert,0,bridge);
    s.constraints=(s.constraints||[]).filter(function(q){return !(q.a===pid&&(q.kind==="fixed"||DIM_KINDS[q.kind]));});return bridge.id;}
  function filletPoint(s,pid,radius){return splitCorner(s,pid,radius,false);}
  function chamferPoint(s,pid,distance){return splitCorner(s,pid,distance,true);}
  function lineIntersection(a,b,c,d){var rx=b.x-a.x,ry=b.y-a.y,sx=d.x-c.x,sy=d.y-c.y,den=rx*sy-ry*sx;if(Math.abs(den)<1e-10)return null;var t=((c.x-a.x)*sy-(c.y-a.y)*sx)/den;return {x:a.x+t*rx,y:a.y+t*ry};}
  function removeFillet(s,cid){var pcs=physicalCurves(s),i=pcs.findIndex(function(c){return c.id===cid;}),arc=i>=0?pcs[i]:null;if(!arc||arc.kind!=="arc"||pcs.length<=3)return false;
    var prev=pcs[(i+pcs.length-1)%pcs.length],next=pcs[(i+1)%pcs.length];if(prev.kind!=="line"||next.kind!=="line"||prev.b!==arc.a||next.a!==arc.b)return false;
    var hit=lineIntersection(point(s,prev.a),point(s,prev.b),point(s,next.a),point(s,next.b));if(!hit)return false;var keep=point(s,arc.a),drop=arc.b;keep.x=hit.x;keep.y=hit.y;next.a=keep.id;
    s.curves=s.curves.filter(function(c){return c.id!==arc.id;});if(!s.curves.some(function(c){return c.a===drop||c.b===drop;}))s.points=s.points.filter(function(p){return p.id!==drop;});
    s.constraints=(s.constraints||[]).filter(function(q){return q.a!==arc.id&&q.b!==arc.id&&q.c!==arc.id&&q.a!==drop&&q.b!==drop&&q.c!==drop;});return true;}
  // Erasing a curve leaves its endpoints in place when neighbouring geometry
  // still uses them. This is intentionally allowed to open the profile.
  function deleteSegment(s,cid){var c=curve(s,cid);if(!c||c.construction)return false;dropEntities(s,[],[cid]);return true;}
  function addLinePath(s,coords,tol){coords=coords||[];tol=Math.max(1e-9,+tol||1e-7);if(coords.length<2)return false;var added=false;
    function existing(q){var best=null,bd=tol;physicalPoints(s).forEach(function(p){var d=Math.hypot(p.x-q[0],p.y-q[1]);if(d<=bd){bd=d;best=p;}});return best;}
    function endpoint(q){var p=existing(q);if(p)return p;var id=nextId(s);p={id:id,x:+q[0],y:+q[1]};s.points.push(p);return p;}
    var a=endpoint(coords[0]);for(var i=1;i<coords.length;i++){var b=endpoint(coords[i]);if(a.id!==b.id&&dist(a,b)>1e-9){s.curves.push({id:nextId(s),kind:"line",a:a.id,b:b.id});added=true;}a=b;}return added;}
  // Repair the common one-edge gap explicitly. Only a single connected chain
  // with exactly two loose endpoints qualifies: adding the candidate edge to a
  // clone must produce the one closed contour accepted by closedOrder. This
  // refuses branches and disconnected islands instead of guessing at copper.
  function closeProfile(s){if(!validSketch(s))return false;if(isClosed(s))return normalize(s);var pcs=physicalCurves(s),degree={},ends=[];
    if(pcs.length<2)return false;pcs.forEach(function(c){degree[c.a]=(degree[c.a]||0)+1;degree[c.b]=(degree[c.b]||0)+1;});
    Object.keys(degree).forEach(function(id){if(degree[id]===1)ends.push(+id);else if(degree[id]!==2)ends.push(NaN);});
    if(ends.length!==2||!isFinite(ends[0])||!isFinite(ends[1]))return false;
    var edge={id:nextId(s),kind:"line",a:ends[0],b:ends[1]};s.curves.push(edge);
    if(!isClosed(s)){s.curves.pop();return false;}normalize(s);return true;}
  function canCloseProfile(s){return !!(s&&closeProfile(cp(s)));}
  // Fusion-style line endpoint inference. Existing/profile vertices win over
  // the drawing grid, followed by horizontal/vertical alignment to the last
  // line endpoint. Returning the exact target coordinates makes the resulting
  // curves share one corner instead of merely looking coincident on screen.
  function snapLinePoint(chain,existing,x,y,grid,tol,axisTol){chain=chain||[];existing=existing||[];grid=+grid||0;tol=Math.max(0,+tol||0);axisTol=Math.max(0,+axisTol||tol);
    var q={x:grid>0?Math.round(x/grid)*grid:+x,y:grid>0?Math.round(y/grid)*grid:+y,kind:grid>0?"grid":"free",mag:false,close:false,axis:null,target:-1},best=tol+1e-12;
    function vertex(p,kind,index){var px=Array.isArray(p)?+p[0]:+p.x,py=Array.isArray(p)?+p[1]:+p.y,d=Math.hypot(x-px,y-py);if(d<best){best=d;q.x=px;q.y=py;q.kind=kind;q.mag=true;q.close=kind==="close";q.axis=null;q.target=index;}}
    if(chain.length>=3)vertex(chain[0],"close",0);existing.forEach(function(p,i){vertex(p,"vertex",i);});if(q.mag)return q;
    if(chain.length){var last=chain[chain.length-1],dx=Math.abs(x-last[0]),dy=Math.abs(y-last[1]);if(dx<=axisTol&&dx<=dy){q.x=last[0];q.kind="inference";q.axis="vertical";}else if(dy<=axisTol){q.y=last[1];q.kind="inference";q.axis="horizontal";}}
    return q;}
  function offset(s,distance){var pcs=physicalCurves(s);if(pcs.some(function(c){return c.kind!=="line";}))return false;var ps=physicalPoints(s),area=0,i,n=ps.length;
    for(i=0;i<n;i++){var a=ps[i],b=ps[(i+1)%n];area+=a.x*b.y-b.x*a.y;}var side=area>=0?1:-1,shift=[];
    for(i=0;i<n;i++){a=ps[i];b=ps[(i+1)%n];var dx=b.x-a.x,dy=b.y-a.y,l=Math.hypot(dx,dy);if(l<1e-9)return false;var nx=side*dy/l,ny=-side*dx/l;
      shift.push({a:{x:a.x+nx*distance,y:a.y+ny*distance},b:{x:b.x+nx*distance,y:b.y+ny*distance}});}
    var out=[];for(i=0;i<n;i++){var p=lineIntersection(shift[(i+n-1)%n].a,shift[(i+n-1)%n].b,shift[i].a,shift[i].b);if(!p)return false;out.push(p);}
    for(i=0;i<n;i++){ps[i].x=out[i].x;ps[i].y=out[i].y;}(s.constraints||[]).forEach(function(q){if(q.value!=null&&DIM_KINDS[q.kind])q.value=dimensionValue(s,q);});return true;}
  function mirror(s,axis,coordinate){if(axis!=="x"&&axis!=="y")return false;s.points.forEach(function(p){if(axis==="x")p.x=2*coordinate-p.x;else p.y=2*coordinate-p.y;});
    s.curves.forEach(function(c){if(c.mid){if(axis==="x")c.mid[0]=2*coordinate-c.mid[0];else c.mid[1]=2*coordinate-c.mid[1];}});return true;}
  function dimensionValue(s,q){var a=point(s,q.a),b=q.b!=null?point(s,q.b):null,c=curve(s,q.a);
    if(q.kind==="distance_x"&&a&&b)return b.x-a.x;if(q.kind==="distance_y"&&a&&b)return b.y-a.y;if(q.kind==="distance"&&a&&b)return dist(a,b);
    if(q.kind==="length"&&c)return c.kind==="line"?dist(point(s,c.a),point(s,c.b)):NaN;if((q.kind==="radius"||q.kind==="diameter")&&c){var g=arcCircle(s,c);return g?g.r*(q.kind==="diameter"?2:1):NaN;}
    if(q.kind==="angle"&&c){var d=lineDir(s,c);return d?Math.atan2(d.y,d.x)*180/Math.PI:NaN;}return +q.value;}
  function annotations(s){var out=[];(s.constraints||[]).forEach(function(q){if(!DIM_KINDS[q.kind])return;var c=curve(s,q.a),a=point(s,q.a),b=q.b!=null?point(s,q.b):null,x=0,y=0;
      if(c){var p=point(s,c.a),z=point(s,c.b);x=(p.x+z.x)/2;y=(p.y+z.y)/2;}else if(a&&b){x=(a.x+b.x)/2;y=(a.y+b.y)/2;}else return;
      out.push({id:q.id,x:x,y:y,kind:q.kind,value:dimensionValue(s,q),driving:q.driving!==false});});return out;}
  function state(s){var copy=cp(s),result=solve(copy,{iterations:1});return result;}

  return {VERSION:VERSION,clone:cp,valid:validSketch,closed:isClosed,normalize:normalize,fromSegments:fromSegments,fromOutline:fromOutline,fromPolygon:fromPolygon,ensure:ensure,ensurePolygon:ensurePolygon,compile:compile,syncOutline:syncOutline,syncPolygon:syncPolygon,
    point:point,curve:curve,physicalCurves:physicalCurves,physicalPoints:physicalPoints,nextId:nextId,arcCircle:arcCircle,
    solve:solve,state:state,addConstraint:addConstraint,removeConstraint:removeConstraint,pointDragAxis:pointDragAxis,pointDragTarget:pointDragTarget,movePoint:movePoint,moveCurve:moveCurve,
    insertPoint:insertPoint,deletePoint:deletePoint,deleteSegment:deleteSegment,addLinePath:addLinePath,closeProfile:closeProfile,canCloseProfile:canCloseProfile,toArc:toArc,toLine:toLine,filletPoint:filletPoint,chamferPoint:chamferPoint,removeFillet:removeFillet,snapLinePoint:snapLinePoint,
    offset:offset,mirror:mirror,annotations:annotations,dimensionValue:dimensionValue};
});
