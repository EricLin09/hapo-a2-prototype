/* Read-only charts drawn from the exported warehouse reporting views. */
(() => {
  const data = window.HAPO_DATA;
  if (!data || !data.uc1?.length || !data.uc2?.length || !data.uc3?.length) {
    document.querySelector('main').innerHTML = '<p>Dashboard data is missing. Run dashboard/build_dashboard.py after the prototype build.</p>';
    return;
  }

  const $ = (id) => document.getElementById(id);
  $('metric-lgas').textContent = new Set(data.uc1.map(r => r.lga_code)).size;
  $('metric-quarters').textContent = new Set(data.uc1.map(r => r.quarter_start)).size;
  $('metric-months').textContent = new Set(data.uc3.map(r => r.month_start)).size;
  const meta = data.meta || {};
  const exportedAt = meta.generated_at ? new Date(meta.generated_at) : null;
  const timeLabel = exportedAt && !Number.isNaN(exportedAt.getTime())
    ? new Intl.DateTimeFormat('en-AU', {dateStyle:'medium',timeStyle:'short',timeZone:'Australia/Sydney'}).format(exportedAt) + ' Sydney'
    : 'time unavailable';
  const verified = meta.verified === true && meta.test_run?.total > 0
    && meta.test_run.passed === meta.test_run.total;
  $('verification-detail').textContent = verified
    ? `Status: VERIFIED. Test run ${meta.test_run.id} passed ${meta.test_run.passed} of ${meta.test_run.total} tests on this data. Exported ${timeLabel}.`
    : `Status: UNVERIFIED export (not checked against a passing test run). Exported ${timeLabel}.`;
  const esc = (value) => String(value).replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const fmt = (value, decimals = 0) => value == null ? 'n/a' : Number(value).toLocaleString('en-AU', {maximumFractionDigits: decimals, minimumFractionDigits: decimals});
  const svg = (body, width, height) => `<svg viewBox="0 0 ${width} ${height}" role="img" xmlns="http://www.w3.org/2000/svg">${body}</svg>`;
  const line = (x1,y1,x2,y2,cls='grid') => `<line class="${cls}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}"/>`;
  const text = (x,y,value,cls='tick',anchor='start') => `<text class="${cls}" x="${x}" y="${y}" text-anchor="${anchor}">${esc(value)}</text>`;
  // Tooltip targets. Native SVG <title> tooltips appear only after a delay, not
  // at all in some embedded viewers, and never on touch screens, so values are
  // shown by the tooltip handler below instead. tabindex and aria-label make
  // the same value reachable by keyboard and screen reader.
  const tipAttrs = (label) => ` data-tip="${esc(label)}" tabindex="0" aria-label="${esc(label)}"`;
  const rect = (x,y,w,h,cls,title='') => `<rect class="${cls}" x="${x}" y="${y}" width="${Math.max(0,w)}" height="${h}" rx="3"${title ? tipAttrs(title) : ''}/>`;
  // Invisible, larger circle over a small data point so it is easy to hover or tap.
  const hasRatio = r => r.rent_to_income_pct != null && Number.isFinite(Number(r.rent_to_income_pct));
  const hit = (x,y,r,label) => `<circle class="hit" cx="${x}" cy="${y}" r="${r}"${tipAttrs(label)}/>`;
  const niceStep = (rough) => {
    if (!Number.isFinite(rough) || rough <= 0) return 1;
    const magnitude = 10 ** Math.floor(Math.log10(rough));
    return [1,2,2.5,5,10].find(step => step * magnitude >= rough) * magnitude;
  };
  const axis = (values, includeZero = true) => {
    const numbers = values.map(Number).filter(Number.isFinite);
    if (!numbers.length) return {lower:0,upper:1,step:1,ticks:1};
    const rawMin = Math.min(...numbers), rawMax = Math.max(...numbers);
    const spread = Math.max(rawMax-rawMin, Math.abs(rawMax)*0.05, 0.1);
    const min = includeZero ? Math.min(0,rawMin) : rawMin-spread*0.06;
    const max = includeZero ? Math.max(0,rawMax)*1.08 : rawMax+spread*0.06;
    const step = niceStep((max-min)/4);
    const lower = Math.floor(min/step)*step;
    const upper = Math.max(lower+step,Math.ceil(max/step)*step);
    return {lower,upper,step,ticks:Math.round((upper-lower)/step)};
  };
  const tickDigits = step => step >= 1 && Number.isInteger(step) ? 0 : step >= 0.1 ? 1 : 2;
  const fillLga = (element, rows) => {
    const choices = [...new Map(rows.map(r => [r.lga_code, r.lga_name])).entries()];
    for (const [code,name] of choices) {
      const opt = document.createElement('option'); opt.value = code; opt.textContent = name; element.appendChild(opt);
    }
    element.value = choices.some(([code])=>code==='16260')?'16260':choices[0]?.[0];
  };
  fillLga($('rent-lga'),data.uc1);
  fillLga($('pipeline-lga'),data.uc3);
  const comparableYears = data.uc2.filter(r => r.population_growth_pct != null && r.da_approved_per_1000_residents != null);
  const availableYears = [...new Map(comparableYears.map(r => [r.financial_year, r.financial_year_label])).entries()]
    .sort((a,b)=>a[0]-b[0]);
  for (const year of [...availableYears].reverse()) {
    const opt = document.createElement('option'); opt.value = year[0]; opt.textContent = year[1]; $('supply-year').appendChild(opt);
  }
  $('supply-year').value = String(availableYears.at(-1)?.[0] || '');

  function drawRent() {
    const latest = data.uc1.reduce((a,r) => r.quarter_start > a ? r.quarter_start : a, '');
    // A missing ratio (rent suppressed or income unavailable) is never drawn as
    // zero: it gets no bar and no trend point, only an explicit "n/a" label.
    const rows = data.uc1.filter(r => r.quarter_start === latest)
      .sort((a,b) => (hasRatio(b) - hasRatio(a)) || Number(b.rent_to_income_pct) - Number(a.rent_to_income_pct));
    const selected = $('rent-lga').value;
    $('rent-quarter').textContent = rows[0]?.quarter || '';
    const selectedRow = rows.find(r => r.lga_code === selected);
    $('rent-focus').textContent = selectedRow?.rent_to_income_pct == null ? 'n/a' : `${fmt(selectedRow.rent_to_income_pct,1)}%`;
    const w = 560, h = 330, left = 150, right = 50, top = 16, rowH = 28;
    const max = Math.max(10,Math.ceil(Math.max(0,...rows.filter(hasRatio).map(r => Number(r.rent_to_income_pct)))/10)*10);
    let chart = '';
    for (let tick = 0; tick <= max; tick += 10) {
      const x = left + (w-left-right) * tick/max;
      chart += line(x,top,x,top+rows.length*rowH) + text(x,top+rows.length*rowH+19,tick+'%', 'tick','middle');
    }
    rows.forEach((r,i) => {
      const y = top + i*rowH;
      chart += text(left-10,y+18,r.lga_name,'label','end');
      if (!hasRatio(r)) {
        chart += `<rect class="hit" x="${left}" y="${y+5}" width="${w-left-right}" height="18"${tipAttrs(`${r.lga_name}: ratio not available (rent or income missing)`)}/>`;
        chart += text(left+7,y+19,'n/a · not available','value missing');
        return;
      }
      const value = Number(r.rent_to_income_pct);
      chart += rect(left,y+5,(w-left-right)*value/max,18,r.lga_code===selected?'bar selected':'bar',`${r.lga_name}: ${fmt(value,2)}%`);
      chart += text(Math.min(w-1,left+(w-left-right)*value/max+7),y+19,fmt(value,1)+'%','value');
    });
    $('rent-bars').innerHTML = svg(chart,w,h);

    const trend = data.uc1.filter(r => r.lga_code === selected).sort((a,b) => a.quarter_start.localeCompare(b.quarter_start));
    const vals = trend.filter(hasRatio).map(r => Number(r.rent_to_income_pct));
    const yAxis = axis(vals,false);
    const x0=48,x1=535,y0=268,y1=25;
    const X=i=>x0+(x1-x0)*i/Math.max(1,trend.length-1);
    const Y=v=>y0-(Number(v)-yAxis.lower)*(y0-y1)/(yAxis.upper-yAxis.lower);
    let trendSvg='';
    for(let tick=0;tick<=yAxis.ticks;tick++){
      const val=yAxis.lower+tick*yAxis.step, y=Y(val);
      trendSvg+=line(x0,y,x1,y)+text(x0-8,y+4,fmt(val,tickDigits(yAxis.step))+'%','tick','end');
    }
    // The line breaks at a missing quarter instead of dropping to zero.
    let segment=[];
    const flush=()=>{if(segment.length>1)trendSvg+=`<polyline class="line" points="${segment.join(' ')}"/>`;segment=[];};
    trend.forEach((r,i)=>{ if(!hasRatio(r)){flush();return;} segment.push(`${X(i)},${Y(r.rent_to_income_pct)}`); });
    flush();
    const colW=(x1-x0)/Math.max(1,trend.length-1);
    trend.forEach((r,i)=>{
      const x=X(i);
      if(hasRatio(r)){
        const y=Y(r.rent_to_income_pct);
        trendSvg+=`<circle class="pt" cx="${x}" cy="${y}" r="4"/>`;
        trendSvg+=hit(x,y,11,`${r.quarter}: ${fmt(r.rent_to_income_pct,2)}%; rent $${fmt(r.median_weekly_rent)}`);
      } else {
        trendSvg+=text(x,y0-8,'n/a','tick missing','middle');
        trendSvg+=`<rect class="hit" x="${x-colW/2}" y="${y1}" width="${colW}" height="${y0-y1}"${tipAttrs(`${r.quarter}: ratio not available (rent or income missing)`)}/>`;
      }
      if(i%2===0||i===trend.length-1)trendSvg+=text(x,y0+20,r.quarter.replace('20',''),'tick','middle');
    });
    trendSvg+=text((x0+x1)/2,321,'Quarter · denominator: 2021 Census income','tick','middle');
    $('rent-trend').innerHTML=svg(trendSvg,w,h);
  }

  function drawSupply() {
    const year=Number($('supply-year').value);
    const yearRows=data.uc2.filter(r=>r.financial_year===year);
    const rows=yearRows.filter(r=>r.population_growth_pct!=null && r.da_approved_per_1000_residents!=null);
    $('supply-focus').textContent=`${rows.length}/${yearRows.length}`;
    const omitted=yearRows.filter(r=>!rows.includes(r)).map(r=>{
      const reason=r.erp_end_30_june==null?'end-year ERP unavailable':r.erp_start_30_june==null?'start-year ERP unavailable':'approval measure unavailable';
      return `${r.lga_name} (${reason})`;
    });
    const unavailableYears=[...new Map(data.uc2.map(r=>[r.financial_year,r.financial_year_label])).entries()]
      .filter(([financialYear])=>!data.uc2.some(r=>r.financial_year===financialYear && r.population_growth_pct!=null && r.da_approved_per_1000_residents!=null))
      .map(([,label])=>label);
    $('supply-coverage').textContent=[
      !yearRows.length?'No financial year has comparable values.':
        omitted.length?`Omitted from ${yearRows[0].financial_year_label}: ${omitted.join('; ')}.`:'All LGAs with reported values are shown.',
      unavailableYears.length?`${unavailableYears.join(', ')} has no comparable population and approval values.`:''
    ].filter(Boolean).join(' ');
    const w=1060,h=360,x0=82,x1=995,y0=292,y1=28;
    if (!rows.length) { $('supply-scatter').textContent='No comparable population and approval data for this financial year.'; return; }
    const xAxis=axis(rows.map(r=>Number(r.population_growth_pct)));
    const yAxis=axis(rows.map(r=>Number(r.da_approved_per_1000_residents)));
    const X=v=>x0+(Number(v)-xAxis.lower)*(x1-x0)/(xAxis.upper-xAxis.lower);
    const Y=v=>y0-(Number(v)-yAxis.lower)*(y0-y1)/(yAxis.upper-yAxis.lower);
    let chart='';
    for(let t=0;t<=xAxis.ticks;t++){
      const value=xAxis.lower+t*xAxis.step, x=X(value);
      chart+=line(x,y1,x,y0)+text(x,y0+22,fmt(value,xAxis.step<1?1:0)+'%','tick','middle');
    }
    for(let t=0;t<=yAxis.ticks;t++){
      const value=yAxis.lower+t*yAxis.step, y=Y(value);
      chart+=line(x0,y,x1,y)+text(x0-10,y+4,fmt(value,yAxis.step%1?1:0),'tick','end');
    }
    chart+=text((x0+x1)/2,h-12,'Annual population growth (%)','label','middle');
    chart+=text(x0,y1-11,'DA approvals / 1,000 residents','label');
    const placed=[];
    const labelOptions=[[11,-10,'start'],[11,17,'start'],[-11,-10,'end'],[-11,17,'end'],[18,-25,'start'],[18,31,'start'],[-18,-25,'end'],[-18,31,'end']];
    // Place longer names first; keep every visible label clear of earlier ones.
    const ordered=[...rows].sort((a,b)=>b.lga_name.length-a.lga_name.length);
    let hits='';   // drawn last, on top of labels, so every dot stays hoverable
    ordered.forEach((r)=>{
      const x=X(r.population_growth_pct),y=Y(r.da_approved_per_1000_residents);
      const cls=r.is_complete_supply_year?'dot':'dot incomplete';
      chart+=`<circle class="${cls}" cx="${x}" cy="${y}" r="6"/>`;
      hits+=hit(x,y,13,`${r.lga_name} · ${r.financial_year_label}: population growth ${fmt(r.population_growth_pct,2)}% (${fmt(r.population_change)} people); ${fmt(r.da_approved_dwellings)} DA-approved dwellings = ${fmt(r.da_approved_per_1000_residents,2)} per 1,000 residents${r.is_complete_supply_year?'':' (incomplete supply year)'}`);
      for(const [dx,dy,anchor] of labelOptions){
        const lx=x+dx, ly=y+dy, width=r.lga_name.length*6.3;
        const box={left:anchor==='start'?lx:lx-width,right:anchor==='start'?lx+width:lx,top:ly-11,bottom:ly+3};
        if(box.left<x0 || box.right>x1 || box.top<y1-5 || box.bottom>y0+5)continue;
        if(placed.some(p=>box.left<p.right+5 && box.right>p.left-5 && box.top<p.bottom+3 && box.bottom>p.top-3))continue;
        placed.push(box);
        chart+=text(lx,ly,r.lga_name,'label scatter-label',anchor);
        break;
      }
    });
    $('supply-scatter').innerHTML=svg(chart+hits,w,h);
  }

  function drawPipeline() {
    const rows=data.uc3.filter(r=>r.lga_code===$('pipeline-lga').value).sort((a,b)=>a.month_start.localeCompare(b.month_start));
    $('pipeline-period').textContent=rows.length?`${rows[0].month_label} – ${rows[rows.length-1].month_label}`:'';
    $('pipeline-focus').textContent=rows.length?fmt(rows[rows.length-1].da_approved_dwellings):'n/a';
    const w=1060,h=350,x0=62,x1=1005,y0=270,y1=20;
    const series=[['lodged_dwellings','line-lodged'],['da_approved_dwellings','line-da'],['cc_approved_dwellings','line-cc']];
    const yAxis=axis(rows.flatMap(r=>series.map(s=>Number(r[s[0]]||0))));
    const X=i=>x0+(x1-x0)*i/Math.max(1,rows.length-1);
    const Y=v=>y0-(Number(v)-yAxis.lower)*(y0-y1)/(yAxis.upper-yAxis.lower);
    let chart='';
    for(let t=0;t<=yAxis.ticks;t++){
      const value=yAxis.lower+t*yAxis.step, y=Y(value);
      chart+=line(x0,y,x1,y)+text(x0-10,y+4,fmt(value,tickDigits(yAxis.step)),'tick','end');
    }
    rows.forEach((r,i)=>{if(i%3===0)chart+=text(X(i),y0+23,r.month_label,'tick','middle')});
    for(const [key,cls] of series){
      let segment=[];
      const flush=()=>{if(segment.length>1)chart+=`<polyline class="line ${cls}" points="${segment.join(' ')}"/>`;segment=[]};
      rows.forEach((r,i)=>{
        if(r[key]==null){flush();return}
        segment.push(`${X(i)},${Y(r[key])}`);
      });
      flush();
      rows.forEach((r,i)=>{if(r[key]!=null)chart+=`<circle class="mk ${cls.replace('line-','mk-')}" cx="${X(i)}" cy="${Y(r[key])}" r="3"/>`});
    }
    // One invisible column per month shows all three stages together; the
    // stage points sit too close to each other to hover one by one.
    const colW=(x1-x0)/Math.max(1,rows.length-1);
    const stageValue=v=>v==null?'missing (not zero)':fmt(v);
    rows.forEach((r,i)=>{
      chart+=`<rect class="hit" x="${X(i)-colW/2}" y="${y1}" width="${colW}" height="${y0-y1}"${tipAttrs(
        `${r.lga_name} · ${r.month_label}: lodged ${stageValue(r.lodged_dwellings)} · DA approved ${stageValue(r.da_approved_dwellings)} · CC approved ${stageValue(r.cc_approved_dwellings)}`)}/>`;
    });
    $('pipeline-lines').innerHTML=svg(chart,w,h);
  }

  // Tooltip handler: one floating box for every [data-tip] element. Pointer
  // events cover mouse, pen and touch (a tap shows the value); focus covers
  // keyboard users tabbing through the data points.
  const tip=document.createElement('div');
  tip.className='chart-tip'; tip.setAttribute('role','tooltip'); tip.hidden=true;
  document.body.appendChild(tip);
  const placeTip=(cx,cy)=>{
    const pad=12, box=tip.getBoundingClientRect();
    const left=Math.min(window.innerWidth-box.width-pad, Math.max(pad, cx+14));
    const top=cy-box.height-14 < pad ? cy+18 : cy-box.height-14;
    tip.style.left=`${left}px`; tip.style.top=`${top}px`;
  };
  const showTip=(el,cx,cy)=>{
    tip.textContent=el.dataset.tip; tip.hidden=false; placeTip(cx,cy);
    document.querySelectorAll('.is-active').forEach(n=>n.classList.remove('is-active'));
    el.classList.add('is-active');
  };
  const hideTip=()=>{
    tip.hidden=true;
    document.querySelectorAll('.is-active').forEach(n=>n.classList.remove('is-active'));
  };
  document.addEventListener('pointerover',e=>{const el=e.target.closest?.('[data-tip]'); if(el)showTip(el,e.clientX,e.clientY);});
  document.addEventListener('pointermove',e=>{if(!tip.hidden && e.target.closest?.('[data-tip]'))placeTip(e.clientX,e.clientY);});
  document.addEventListener('pointerout',e=>{
    if(e.target.closest?.('[data-tip]') && !e.relatedTarget?.closest?.('[data-tip]'))hideTip();
  });
  document.addEventListener('pointerdown',e=>{if(!e.target.closest?.('[data-tip]'))hideTip();});
  document.addEventListener('focusin',e=>{
    const el=e.target.closest?.('[data-tip]'); if(!el)return;
    const r=el.getBoundingClientRect(); showTip(el,r.left+r.width/2,r.top);
  });
  document.addEventListener('focusout',hideTip);
  window.addEventListener('scroll',hideTip,{passive:true});

  $('rent-lga').addEventListener('change',drawRent);
  $('supply-year').addEventListener('change',drawSupply);
  $('pipeline-lga').addEventListener('change',drawPipeline);
  drawRent();drawSupply();drawPipeline();
})();
