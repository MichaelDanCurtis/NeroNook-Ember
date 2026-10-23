'use strict';
let currentState={}, targets=[], selectedJob=null, currentReview=null;
const localViewSignatures={};
const $ = id => document.getElementById(id);
const allowedStates = new Set(['accepted','launching','started','completed','failed','cancelled','uncertain']);
function timestampDescription(milliseconds, now=Date.now(), locale=undefined) {
  if (typeof milliseconds !== 'number' || !Number.isFinite(milliseconds) || milliseconds <= 0) return null;
  const date = new Date(milliseconds);
  if (!Number.isFinite(date.getTime())) return null;
  const age = now - milliseconds;
  let relative = 'just now';
  if (age < -5000) relative = 'time ahead of this Mac';
  else if (age >= 15000) {
    const seconds = Math.floor(age / 1000);
    const [count, unit] = seconds < 60 ? [seconds, 'second'] : seconds < 3600 ? [Math.floor(seconds / 60), 'minute'] : seconds < 86400 ? [Math.floor(seconds / 3600), 'hour'] : [Math.floor(seconds / 86400), 'day'];
    relative = `${count.toLocaleString(locale)} ${unit}${count === 1 ? '' : 's'} ago`;
  }
  return {relative, exact:new Intl.DateTimeFormat(locale,{dateStyle:'medium',timeStyle:'medium'}).format(date), datetime:date.toISOString()};
}
function showTimestamp(id, milliseconds, label, missing) {
  const node = $(id), value = timestampDescription(milliseconds);
  node.textContent = value ? `${label} ${value.relative}` : missing;
  node.title = value ? `${label} ${value.exact}` : '';
  node.setAttribute('datetime', value?.datetime || '');
  node.setAttribute('aria-label', value ? `${label} ${value.relative}. ${value.exact}` : missing);
}
nero.onState(state => {
  let providers=[];try{providers=JSON.parse(state.speechProviders||'[]');}catch{}
  const choices=JSON.stringify(providers);if($('speechProvider').dataset.choices!==choices){$('speechProvider').dataset.choices=choices;$('speechProvider').replaceChildren(new Option('Choose provider…',''));for(const p of providers)$('speechProvider').add(new Option(p.name,p.key));}
  $('speechProvider').value=state.speechProvider||'';$('speechStatus').textContent=state.speechStatus||'';$('stopSpeech').hidden=!state.speechActive;
  $('readStatus').disabled=!providers.some(p=>p.key===state.speechProvider)||state.speechActive||state.voiceActive;
  const available = state.available === true;
  $('phase').textContent = state.phase || 'Unavailable';
  $('detail').textContent = state.detail || 'Waiting for local Fuego Compute.';
  $('dot').className = 'dot ' + (state.connected && !state.paused ? 'connected' : available ? 'warning' : 'offline');
  $('active').textContent = available ? String(state.active_jobs || 0) : '—';
  $('uncertain').textContent = available ? String(state.uncertain_jobs || 0) : '—';
  $('provider').textContent = available && state.provider === 'codex' ? 'Codex' : '—';
  showTimestamp('observed', available ? state.observed_at : null, 'Observed', 'Waiting for a fresh runtime observation.');
  let jobs = [];
  try { const parsed = JSON.parse(state.jobs || '[]'); if (Array.isArray(parsed)) jobs = parsed.slice(0,20); } catch (_) {}
  $('jobs').replaceChildren();
  for (const job of jobs) {
    if (!allowedStates.has(job.state) || typeof job.runId !== 'string') continue;
    const row = document.createElement('tr');
    const run = document.createElement('td'); run.textContent = job.runId.slice(0,8).toLowerCase(); run.title = job.runId;
    const provider = document.createElement('td'); provider.textContent = 'Codex';
    const status = document.createElement('td'); const badge = document.createElement('span'); badge.className = 'state ' + job.state; badge.textContent = job.state; status.append(badge);
    row.append(run,provider,status); $('jobs').append(row);
  }
  $('job-count').textContent = jobs.length ? 'LATEST ' + jobs.length : '';
  $('empty').hidden = jobs.length > 0;
  $('empty').textContent = available ? 'No agent jobs have been admitted on this Mac yet.' : 'Jobs will appear when the local runtime responds.';
  $('request-status').textContent = ''; updateHandoff(state); updateNook(state);
});
async function send(name) {
  try { await nero.emit(name); $('request-status').textContent = name === 'refresh' ? 'Refresh requested' : 'Window requested'; }
  catch (_) { $('request-status').textContent = 'Request unavailable. Reopen this module.'; }
}

function parsed(raw,fallback){try{return JSON.parse(raw||'null')??fallback;}catch{return fallback;}}
function options(select,items,placeholder,preferred){const signature=JSON.stringify(items);if(select.dataset.choices!==signature){const previous=select.value;select.dataset.choices=signature;select.replaceChildren();if(placeholder)select.add(new Option(placeholder,''));for(const item of items)select.add(new Option(item.name,item.id));select.value=items.some(x=>x.id===previous)?previous:items[0]?.id||'';}if(preferred)select.value=preferred;}
function updateCompose(){const target=targets.find(t=>t.id===$('target').value);$('targetDetail').textContent=target?`${target.provider||'Registered provider'} · ${target.workspace} · computer ${target.device.slice(0,8).toLowerCase()}`:'';const length=new TextEncoder().encode($('task').value).length;$('taskCount').textContent=`${length.toLocaleString()} / 2,048 bytes`;$('reviewTask').disabled=!target||!$('task').value.trim()||length>2048||!currentState.canSubmit;}
function step(label,done,active){const el=document.createElement('span');el.textContent=label;el.className=done?'done':active?'now':'';return el;}
function updateHandoff(state){
 currentState=state;$('priorSaveNotice').hidden=!state.unconfirmedSave;targets=parsed(state.targets,[]);const companies=parsed(state.companies,[]);
 options($('target'),targets,targets.length?'Choose agent…':'Connect to choose an agent');options($('company'),companies,null,state.company);$('companyLabel').hidden=companies.length<2;
 $('handoffMessage').textContent=state.handoffMessage||'';$('connect').textContent=companies.length?'Account':'Connect Fuego';updateCompose();
 const nextReview=parsed(state.review,null);if(currentReview?.id!==nextReview?.id){$('instructionsBody').hidden=true;$('toggleInstructions').setAttribute('aria-expanded','false');if(nextReview)showJobs();}currentReview=nextReview;$('review').hidden=!currentReview;$('composer').hidden=!!currentReview;
 if(currentReview){$('reviewTaskText').textContent=state.reviewTask||currentReview.task||'';$('reviewTarget').replaceChildren();for(const [label,value] of [['Server',currentReview.server],['Organization',currentReview.organization],['Agent',currentReview.agent],['Computer',currentReview.device],['Workspace',currentReview.workspace],['Provider',currentReview.provider||'Registered account'],['Account',currentReview.account]]){const dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=label;dd.textContent=value;$('reviewTarget').append(dt,dd);}$('reviewInstructions').textContent=state.reviewInstructions||currentReview.instructions||'';$('sendTask').disabled=state.handoffBusy;}
 const jobs=parsed(state.handoffs,[]);options($('history'),jobs.map(j=>({id:j.id,name:j.phase+' · '+j.title})),null,state.selectedJob);$('history').hidden=!jobs.length;
 const priorJobID=selectedJob?.id;
 selectedJob=parsed(state.job,null);$('job').hidden=!selectedJob;$('noJob').hidden=!!selectedJob;
 if(selectedJob){const j=selectedJob;
 if(priorJobID!==j.id)$('jobDetails').open=false;
 $('jobPhase').textContent=j.phase;$('jobPhase').className='state '+j.state;
 const title=Array.from(displayQuestion(j.task).replace(/\s+/g,' ').trim());$('jobTitle').textContent=title.slice(0,90).join('')+(title.length>90?'…':'');$('jobTitle').title=j.task;
 $('jobTask').textContent=j.task;$('jobTarget').textContent=`${j.agent} · ${j.workspace}`;$('jobDetail').textContent=j.detail;
 showTimestamp('jobObserved', typeof j.lastRead==='number'?j.lastRead*1000:null, 'Last confirmed', 'Awaiting confirmation');
 $('steps').replaceChildren(step('Saved by Fuego',!!j.issue,j.state==='preparing'),step('Run accepted',!!j.run,j.state==='submitting'),step('Computer admission',j.admitted,j.state==='queued'||j.state==='running'),step('Result',['succeeded','failed','cancelled','skipped'].includes(j.state),j.state==='cancelling'));
 $('timeline').replaceChildren();for(const text of j.events){const line=document.createElement('p');line.textContent=text;$('timeline').append(line);}
 $('result').textContent=j.result||(['succeeded','failed','cancelled','skipped'].includes(j.state)?'Fuego returned no final answer for this run.':'The final answer will appear here when Fuego returns it.');$('cancelJob').hidden=!j.canCancel;$('cancelJob').disabled=state.handoffBusy;$('recheckJob').hidden=!j.canRecheck;$('recheckJob').disabled=state.handoffBusy;$('openJob').hidden=!j.canOpen;$('jobIDs').textContent=j.issue+(j.run?' · run '+j.run.slice(0,8).toLowerCase():'');
 }
}
async function event(name,values={}){try{await nero.emit(name,values);}catch{$('request-status').textContent='Request unavailable. Refresh the module.';}}
$('task').oninput=updateCompose;$('target').onchange=updateCompose;$('company').onchange=()=>event('company',{id:$('company').value});
$('reviewTask').onclick=()=>event('review_task',{target:$('target').value,task:$('task').value});$('sendTask').onclick=()=>{if(currentReview){$('sendTask').disabled=true;event('send_task',{id:currentReview.id});}};$('back').onclick=()=>event('dismiss_review');
$('history').onchange=()=>event('select_job',{id:$('history').value});$('cancelJob').onclick=()=>{if(selectedJob){$('cancelJob').disabled=true;event('cancel_job',{id:selectedJob.id});}};$('recheckJob').onclick=()=>selectedJob&&event('recheck_job',{id:selectedJob.id});$('openJob').onclick=()=>selectedJob&&event('open_job',{id:selectedJob.id});
$('connect').onclick=()=>event('connect_fuego');$('refresh').onclick=()=>{event('refresh');event('refresh_jobs');};$('open').onclick=()=>event('open_window');
function showJobs(){ $('nookPage').hidden=true;$('nookTab').classList.remove('selected'); $('handoffPage').hidden=false;$('computePage').hidden=true;$('jobsTab').classList.add('selected');$('computeTab').classList.remove('selected');}
$('jobsTab').onclick=showJobs;$('computeTab').onclick=()=>{ $('nookPage').hidden=true;$('nookTab').classList.remove('selected'); $('handoffPage').hidden=true;$('computePage').hidden=false;$('computeTab').classList.add('selected');$('jobsTab').classList.remove('selected');};
$('speechProvider').onchange=()=>event('speech_provider',{key:$('speechProvider').value});$('readStatus').onclick=()=>event('read_status');$('stopSpeech').onclick=()=>event('stop_speech');

$('toggleInstructions').onclick=()=>{const open=$('instructionsBody').hidden;$('instructionsBody').hidden=!open;$('toggleInstructions').setAttribute('aria-expanded',String(open));};

function updateNook(state) {
 updateEmber(state);
 $('nookStatus').textContent=state.nookStatus||'Connect Nook to choose a module.';
 $('nookModules').textContent=parsed(state.nookModules,[]).length?'Refresh modules':'Connect Nook';
 $('nookModules').disabled=!!state.nookBusy;
 $('nookWatch').hidden=!!state.nookWatching;$('nookWatch').disabled=!!state.nookBusy;
 $('nookUnwatch').hidden=!state.nookWatching;$('nookCancel').hidden=!state.nookBusy;
 $('dismissAttention').hidden=!state.ownAttention;
 renderModules();
 const rows=parsed(state.nookAttention,[]);
 const activitySignature=JSON.stringify([rows,state.nookBusy,state.nookWatching,parsed(state.nookModules,[]).map(m=>m.id)]);
 if(localViewSignatures.activity===activitySignature)return;
 localViewSignatures.activity=activitySignature;
 $('attentionChoices').replaceChildren();
 for(const row of rows.slice(0,40)) {
  const line=document.createElement('div');line.className='activity-row';
  const name=document.createElement('strong');name.textContent=row.name;
  const title=document.createElement('span');title.textContent=row.title;
  const count=document.createElement('span');count.className='count';count.textContent=row.count;
  line.append(name,title,count);
  if(parsed(state.nookModules,[]).some(m=>m.id===row.module_id)) {const open=document.createElement('button');open.textContent='Open';open.disabled=!!state.nookBusy;open.onclick=()=>event('nook',{command:'open',id:row.module_id});line.append(open);}
  $('attentionChoices').append(line);
 }
 $('activityEmpty').hidden=rows.length>0;
 $('activityEmpty').textContent=state.nookWatching?"You're all caught up.":'Choose Watch activity to see module indicators here.';
}
function renderModules() {
 const all=parsed(currentState.nookModules,[]), query=$('moduleSearch').value.trim().toLocaleLowerCase();
 const signature=JSON.stringify([all,query,currentState.nookBusy]);
 if(localViewSignatures.modules===signature)return;
 localViewSignatures.modules=signature;
 const modules=all.filter(m=>typeof m.name==='string'&&m.name.toLocaleLowerCase().includes(query));
 $('moduleChoices').replaceChildren();
 for(const item of modules.slice(0,40)) {
  const button=document.createElement('button');button.textContent=item.name;button.disabled=!!currentState.nookBusy;
  button.onclick=()=>event('nook',{command:'open',id:item.id});$('moduleChoices').append(button);
 }
 $('moduleEmpty').hidden=modules.length>0;
 $('moduleEmpty').textContent=all.length?'No matching modules.': 'Connect Nook to choose a module.';
}
$('moduleSearch').oninput=renderModules;
$('nookTab').onclick=()=>{ $('nookPage').hidden=false;$('handoffPage').hidden=true;$('computePage').hidden=true;$('nookTab').classList.add('selected');$('jobsTab').classList.remove('selected');$('computeTab').classList.remove('selected');};
$('nookModules').onclick=()=>event('nook',{command:'modules'});$('nookWatch').onclick=()=>event('nook',{command:'watch'});$('nookUnwatch').onclick=()=>event('nook',{command:'unwatch'});$('nookCancel').onclick=()=>event('nook',{command:'cancel'});$('dismissAttention').onclick=()=>event('nook',{command:'seen'});

function updateEmber(state) {
 const agents=parsed(state.targets,[]);
 const previous=$('emberTarget').value;
 options($('emberTarget'),agents,agents.length?'Choose agent…':'Connect Fuego to choose an agent');
 if($('emberTarget').dataset.ownerChosen==='true')$('emberTarget').value=agents.some(a=>a.id===previous)?previous:'';
 else $('emberTarget').value=agents.find(a=>a.name.trim().toLocaleLowerCase()==='ember')?.id||(agents.length===1?agents[0].id:'');
 const voice=!!state.voiceActive;
 const controls=parsed(state.voiceControls,null),sensitivity=$('emberSensitivity');
 $('emberMicrophoneName').textContent=voice&&controls?.microphone?controls.microphone:'Microphone';
 $('emberVoiceSettings').title=voice?'Change microphone · stops Talk':'Choose microphone and speech recognition';
 $('emberExpression').checked=!!state.voiceExpressionEnabled;$('emberExpression').disabled=!state.voiceReady;
 $('emberVoiceEngine').textContent=controls?.recognition||'Shared local speech for Nero and Ember';
 sensitivity.disabled=!state.voiceReady||!controls;if(document.activeElement!==sensitivity)sensitivity.value=String(controls?.sensitivity??50);
 $('emberSensitivityValue').textContent=controls?sensitivity.value+'%':'—';
 $('emberSensitivityHint').textContent=state.voiceReady&&controls?(state.voiceMode==='full'?'Changes apply immediately.':'Used in Full duplex. Half duplex waits until the reply ends.'):'Start Talk to adjust live, or open voice settings below.';
 document.body.classList.toggle('nc-talking',voice);
 $('emberPresenceStatus').textContent=voice?({listening:'Listening',thinking:'Thinking',speaking:'Speaking',preparing:'Preparing',permission:'Needs approval'}[state.voicePhase]||'Starting'):'';
 $('emberPresenceStatus').dataset.capturing=String(!!state.voiceReady&&(state.voiceMode==='full'||state.voicePhase==='listening'));
 $('emberWaveLabel').textContent=state.voicePhase==='speaking'?'Voice':'Live words';

 $('emberTalk').hidden=voice||!!state.voiceReview;
 $('emberTalk').disabled=!state.voiceAvailable||!!state.chatBusy||!state.canSubmit||!$('emberTarget').value;
 $('emberVoiceStop').hidden=!voice;
 $('emberVoiceReview').hidden=!state.voiceReview;
 $('emberVoiceTarget').textContent=state.voiceTarget||'Ember';
 $('emberDuplex').value=state.voiceMode||'half';
 $('emberLive').hidden=!voice;
 $('emberLive').dataset.phase=state.voicePhase||'idle';
 $('emberTalkAvatar').hidden=false;
 $('emberInputLevel').value=Math.max(0,Math.min(1,Number(state.voicePhase==='speaking'?state.voiceOutputLevel:state.voiceLevel)||0));
 $('emberInputLevel').setAttribute('aria-label',state.voicePhase==='speaking'?'Speech playback level':'Microphone level');
 window.NookAvatar?.setBusy?.(!!state.voiceActive||(!!state.speechActive&&!state.reactionSpeaking));document.querySelectorAll('.nook-presence').forEach(el=>{window.NookAvatar?.speech(el,state.voiceOutputLevel||0,state.voiceActive&&state.voicePhase==='speaking');let pose={};try{pose=JSON.parse(state.voiceExpression||'{}')}catch{}window.NookAvatar?.expression(el,pose);});
 $('emberLiveWords').textContent=state.voicePartial||(state.voicePhase==='preparing'?'Preparing local speech…':state.voicePhase==='thinking'?'Ember is thinking…':state.voicePhase==='speaking'?'Ember is speaking…':'Listening…');
 const voiceStatus=state.voiceStatus||'';
 $('emberVoiceStatus').textContent=voice ? (voiceStatus||'Starting local speech…') : (/^(Press Talk|Allow a shared|Choose an allowed)/.test(voiceStatus)?'':voiceStatus);
 $('emberVoiceStatus').hidden=!/(failed|error|unavailable|unexpected|could not|declined|permission|expired|allow)/i.test(voiceStatus);
 options($('emberVoiceProvider'),parsed(state.voiceProviders,[]),'Connect speech provider…',state.voiceProvider);
 const reviewing=!!state.chatReview;
 $('emberForm').hidden=reviewing;$('emberReview').hidden=!reviewing;
 $('emberAsk').disabled=!!state.chatBusy||!!state.voiceActive||!!state.voiceReview||!state.canSubmit||!$('emberTarget').value;
 $('emberTarget').disabled=!!state.chatBusy||!!state.voiceActive||!!state.voiceReview;
 $('emberStop').hidden=!state.chatBusy;
 $('emberStop').disabled=!!state.handoffBusy;
 $('emberStop').textContent=selectedJob?.canCancel?'Stop':'Stop waiting';
 $('emberQuestion').textContent=state.chatQuestion||'';$('emberQuestion').hidden=!state.chatQuestion;
 $('emberAnswer').textContent=state.chatAnswer||'';$('emberAnswer').hidden=!state.chatAnswer;
 $('emberRead').hidden=!state.chatAnswer||!!state.voiceActive;
 $('emberStatus').textContent=state.chatStatus||'';
 $('emberStatus').hidden=!/(failed|error|unavailable|unexpected|could not|declined|expired|finish the|connect)/i.test(state.chatStatus||'');
 const phase=state.voicePhase||'idle',titles={listening:'I’m listening.',thinking:'Let me think.',speaking:'Here’s what I found.',preparing:'Getting ready…',permission:'Connect your voice.'};
 $('emberHeading').textContent=voice?(titles[phase]||'Talk with Ember.'):(state.chatBusy?'Let me check.':state.canSubmit?($('emberTarget').value?'What can I help with?':'Choose your Ember agent.'):'Connect to your assistant.');
 $('emberSubtitle').textContent=voice?(phase==='listening'?'Take your time.':phase==='speaking'?(state.voiceMode==='full'?'You can interrupt me.':'I’ll listen when I finish.'):'One moment.'):'Ember uses your Fuego account.';
 $('emberLiveWords').textContent=voice?(state.voicePartial||(phase==='speaking'?state.chatAnswer||'':phase==='thinking'?state.chatQuestion||'':'')):'';
 $('emberLiveWords').hidden=!voice||!$('emberLiveWords').textContent;
 $('emberPresenceStage').hidden=!!state.voiceReview||reviewing||(!voice&&!!state.chatAnswer);
 $('emberExchange').hidden=voice||!state.chatAnswer;
 $('emberForm').hidden=voice||reviewing||!!state.voiceReview;
 $('emberTypeInstead').hidden=!voice;$('emberConnectMain').hidden=(!!state.canSubmit&&!!$('emberTarget').value)||!!state.chatBusy;$('emberConnectMain').textContent=state.canSubmit?'Choose Fuego agent…':'Connect Fuego…';
 for(const [id,mode] of [['emberFullDuplex','full'],['emberHalfDuplex','half']]){$(id).setAttribute('aria-pressed',String((state.voiceMode||'half')===mode));}

 $('emberOpen').hidden=!state.chatModule;$('emberOpen').textContent=state.chatModule?'Open '+state.chatModule+'…':'';
 if(reviewing){
  const context=parsed(state.chatReview,{}), target=agents.find(a=>a.id===$('emberTarget').value);
  $('emberReviewTarget').textContent=target?`${target.name} · ${target.provider} · ${target.workspace}`:'';
  const signature=state.chatReview;
  if($('emberContext').dataset.signature!==signature){
   $('emberContext').dataset.signature=signature;$('emberContext').replaceChildren();
   for(const text of ['Question: '+(context.question||''),'Modules: '+(context.modules||[]).map(m=>m.name).join(', '),'Notifications: '+((context.notifications||[]).map(n=>`${n.module}: ${n.status} (${n.count})`).join('; ')||'None')]){
    const line=document.createElement('p');line.textContent=text;$('emberContext').append(line);
   }
  }
 }
}
$('emberForm').onsubmit=e=>{e.preventDefault();event('nook',{command:'ask',id:$('emberTarget').value,text:$('emberInput').value});};
$('emberTarget').onchange=()=>{$('emberTarget').dataset.ownerChosen='true';updateEmber(currentState);};
$('emberSend').onclick=()=>{ $('emberSend').disabled=true;event('nook',{command:'send_chat'}).finally(()=>{$('emberSend').disabled=false;}); };
$('emberBack').onclick=()=>event('nook',{command:'stop_chat'});
$('emberStop').onclick=()=>event('nook',{command:'stop_chat'});
$('emberOpen').onclick=()=>event('nook',{command:'open_chat'});
$('emberRead').onclick=()=>event('nook',{command:'read_chat'});

function displayQuestion(text){if(!text.startsWith('Nook conversation v1.'))return text;const data=parsed(text.slice(text.indexOf('\n')+1),{});return typeof data.question==='string'?data.question:text;}

$('emberTalk').onclick=()=>event('nook',{command:'voice_prepare',id:$('emberTarget').value});
$('emberVoiceStart').onclick=()=>event('nook',{command:'voice_start'});
$('emberVoiceBack').onclick=()=>event('nook',{command:'voice_back'});
$('emberVoiceStop').onclick=()=>event('nook',{command:'voice_stop'});
$('emberDuplex').onchange=()=>event('nook',{command:'voice_mode',text:$('emberDuplex').value});
$('emberVoiceProvider').onchange=()=>event('nook',{command:'voice_provider',text:$('emberVoiceProvider').value});
$('emberVoiceSettings').onclick=()=>event('nook',{command:'voice_settings'});

$('emberNotifications').onclick=()=>{$('emberActivity').hidden=!$('emberActivity').hidden;};$('emberCloseActivity').onclick=()=>{$('emberActivity').hidden=true;};
$('emberTypeInstead').onclick=()=>{event('nook',{command:'voice_stop'});$('emberForm').hidden=false;$('emberInput').focus();};
$('emberConnectMain').onclick=()=>{if(currentState.canSubmit){$('emberMenu').open=true;$('emberTarget').focus();}else $('connect').onclick();};
for(const [id,mode] of [['emberFullDuplex','full'],['emberHalfDuplex','half']])$(id).onclick=()=>{$('emberDuplex').value=mode;$('emberDuplex').onchange();};
for(const id of ['nookTab','jobsTab','computeTab','connect','open','refresh','emberVoiceSettings']){const handler=$(id).onclick;$(id).onclick=()=>{$('emberMenu').open=false;handler();};}

$('emberSensitivity').oninput=()=>{$('emberSensitivityValue').textContent=$('emberSensitivity').value+'%';};
$('emberSensitivity').onchange=()=>event('nook',{command:'voice_sensitivity',text:$('emberSensitivity').value});
$('emberAllVoiceSettings').onclick=()=>{$('emberVoiceControls').open=false;event('nook',{command:'voice_settings'});};
document.addEventListener('pointerdown',e=>{if(!$('emberVoiceControls').contains(e.target))$('emberVoiceControls').open=false;});
document.addEventListener('keydown',e=>{if(e.key==='Escape')$('emberVoiceControls').open=false;});

// Explicit click handling also supports nonactivating Nook panels.
$('emberVoiceControls').querySelector('summary').onclick=e=>{e.preventDefault();$('emberVoiceControls').open=!$('emberVoiceControls').open;};

$('emberExpression').onchange=()=>event('nook',{command:'voice_expression',text:String($('emberExpression').checked)});
