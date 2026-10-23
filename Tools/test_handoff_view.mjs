import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const html=fs.readFileSync(new URL('../Resources/Views/monitor/index.html',import.meta.url),'utf8');
assert.ok(html.includes('Fuego may include your existing conversation context.'));
class Node {
  constructor(){this.dataset={};this.value='';this.hidden=false;this.children=[];this.textContent='';this.classList={add(){},remove(){},toggle(){}};}
  querySelector(){return this.summary ??= new Node();}
  contains(){return false;}
  setAttribute(key,value){this[key]=value;}
  add(n){this.children.push(n);}
  append(...n){this.children.push(...n);}
  replaceChildren(...n){this.children=n;}
  addEventListener(name,fn){this['on'+name]=fn;}
}
const nodes=Object.fromEntries([...html.matchAll(/id="([^"]+)"/g)].map(m=>[m[1],new Node()]));
const calls=[];let update;
const sandbox={window:{},document:{body:new Node(),querySelectorAll:()=>[],addEventListener(){},getElementById:id=>{assert.ok(nodes[id],id);return nodes[id];},createElement:()=>new Node()},
  Option:class extends Node{constructor(name,id){super();this.textContent=name;this.value=id;}},
  TextEncoder,Date,JSON,Set,console,nero:{onState:fn=>{update=fn;fn({});},emit:async(name,args)=>calls.push({name,args})}};
vm.runInNewContext(fs.readFileSync(new URL('../Resources/Views/monitor/monitor.js',import.meta.url),'utf8'),sandbox);
assert.equal(nodes.companyLabel.hidden,true);assert.equal(nodes.history.hidden,true);
assert.equal(typeof nodes.connect.onclick,'function');nodes.connect.onclick();assert.equal(calls.at(-1).name,'connect_fuego');
const state={canSubmit:true,targets:JSON.stringify([{id:'a',name:'Agent',provider:'Codex',workspace:'Owned work',device:'device-id'}]),companies:JSON.stringify([{id:'c',name:'Company'}]),company:'c',handoffs:'[]',handoffMessage:'Ready'};
update(state);nodes.target.value='a';nodes.task.value='Keep this exact task';nodes.task.oninput();assert.equal(nodes.reviewTask.disabled,false);
nodes.reviewTask.onclick();assert.equal(calls.at(-1).name,'review_task');assert.equal(calls.at(-1).args.task,'Keep this exact task');
update({...state,phase:'Ready'});assert.equal(nodes.task.value,'Keep this exact task');
nodes.task.value='🐈'.repeat(513);nodes.task.oninput();assert.equal(nodes.reviewTask.disabled,true);
update({...state,review:JSON.stringify({id:'r',task:'Original task',server:'https://fuego.example.org',agent:'Agent',organization:'Company',device:'Device',workspace:'Owned work',provider:'Codex',account:'Account',instructions:'Standing instructions'})});
assert.equal(nodes.composer.hidden,true);assert.equal(nodes.review.hidden,false);assert.equal(nodes.reviewTaskText.textContent,'Original task');
nodes.toggleInstructions.onclick();assert.equal(nodes.instructionsBody.hidden,false);assert.equal(nodes.toggleInstructions['aria-expanded'],'true');
nodes.sendTask.onclick();assert.equal(calls.at(-1).name,'send_task');assert.equal(calls.at(-1).args.id,'r');
const job={id:'j',task:'Original task',phase:'Cancellation requested',state:'cancelling',agent:'Agent',workspace:'Owned work',detail:'Waiting for actual stop',result:'',events:['Accepted'],issue:'FUE-1',run:'run-id',canCancel:false,canOpen:true,admitted:true,lastRead:Date.now()/1000};
update({...state,job:JSON.stringify(job),handoffs:JSON.stringify([{id:'j',title:'Original task',phase:'Cancellation requested'}]),selectedJob:'j'});
assert.equal(nodes.jobPhase.textContent,'Cancellation requested');assert.equal(nodes.cancelJob.hidden,true);assert.equal(nodes.jobDetail.textContent,'Waiting for actual stop');
update({...state,job:JSON.stringify({...job,phase:'Completed',state:'succeeded',result:'<script>never execute</script>\nActual result'})});
assert.equal(nodes.result.textContent,'<script>never execute</script>\nActual result');
assert.equal(nodes.jobDetails.open,false);
nodes.jobDetails.open=true;
update({...state,job:JSON.stringify({...job,phase:'Completed',state:'succeeded',result:'A refreshed result'})});
assert.equal(nodes.jobDetails.open,true,'Status updates preserve an open task/activity disclosure');
update({...state,job:JSON.stringify({...job,id:'different-job',task:'🐈'.repeat(100),lastRead:0})});
assert.equal(nodes.jobDetails.open,false,'Selecting another job resets its disclosure');
assert.equal(nodes.jobTitle.textContent,'🐈'.repeat(90)+'…');
assert.equal(nodes.jobTask.textContent,'🐈'.repeat(100),'The full task remains available');
assert.equal(nodes.jobObserved.textContent,'Awaiting confirmation');
assert.equal(nodes.jobObserved.datetime,'','A missing observation cannot retain the previous date');
assert.equal(nodes.jobObserved.title,'');
const now=Date.UTC(2026,9,18,12,0,0);
for(const [age,expected] of [[0,'just now'],[14999,'just now'],[15000,'15 seconds ago'],[59000,'59 seconds ago'],[60000,'1 minute ago'],[3599000,'59 minutes ago'],[3600000,'1 hour ago'],[86399000,'23 hours ago'],[86400000,'1 day ago'],[3*86400000,'3 days ago']]){
 const value=sandbox.timestampDescription(now-age,now,'en-US');
 assert.equal(value.relative,expected);assert.equal(value.datetime,new Date(now-age).toISOString());assert.ok(value.exact.includes('2026'));
}
for(const invalid of [0,-1,NaN,Infinity,'123',null,undefined,1e20])assert.equal(sandbox.timestampDescription(invalid,now),null);
assert.equal(sandbox.timestampDescription(now+6000,now).relative,'time ahead of this Mac');
assert.equal(sandbox.timestampDescription(now+1000,now).relative,'just now');
update({...state,job:JSON.stringify({...job,lastRead:(now-3*86400000)/1000})});
assert.ok(nodes.jobObserved.title.includes('2026'));assert.ok(nodes.jobObserved['aria-label'].includes('2026'));
nodes.computeTab.onclick();assert.equal(nodes.handoffPage.hidden,true);assert.equal(nodes.computePage.hidden,false);
nodes.jobsTab.onclick();assert.equal(nodes.handoffPage.hidden,false);assert.equal(nodes.computePage.hidden,true);
console.log('PASS: immediate SDK bootstrap, events, preserved task, Unicode limit, exact review, cancellation, text-only results, timestamp boundaries/unknowns/clock skew, disclosure continuity and content tabs.');
update({...state,nookModules:JSON.stringify([{id:'test.weather',name:'Weather',enabled:'true'}]),nookAttention:JSON.stringify([{module_id:'test.weather',name:'Weather',title:'New activity',count:'1'}]),nookWatching:true,nookStatus:'Current Nook activity.'});
assert.equal(nodes.moduleChoices.children.length,1);nodes.moduleChoices.children[0].onclick();assert.equal(calls.at(-1).name,'nook');assert.equal(calls.at(-1).args.command,'open');assert.equal(calls.at(-1).args.id,'test.weather');
nodes.moduleSearch.value='missing';nodes.moduleSearch.oninput();assert.equal(nodes.moduleEmpty.hidden,false);assert.equal(nodes.moduleEmpty.textContent,'No matching modules.');
assert.equal(nodes.attentionChoices.children.length,1);assert.equal(nodes.nookWatch.hidden,true);nodes.nookUnwatch.onclick();assert.equal(calls.at(-1).name,'nook');assert.equal(calls.at(-1).args.command,'unwatch');
nodes.nookTab.onclick();assert.equal(nodes.nookPage.hidden,false);assert.equal(nodes.handoffPage.hidden,true);assert.equal(nodes.computePage.hidden,true);
console.log('PASS: local Nook launch targets, activity controls, empty search and tab continuity.');
nodes.moduleSearch.value='';nodes.moduleSearch.oninput();const stableModuleButton=nodes.moduleChoices.children[0];
update({...state,nookModules:JSON.stringify([{id:'test.weather',name:'Weather',enabled:'true'}]),nookAttention:JSON.stringify([{module_id:'test.weather',name:'Weather',title:'New activity',count:'1'}]),nookWatching:true,nookStatus:'Current Nook activity.'});
assert.equal(nodes.moduleChoices.children[0],stableModuleButton,'Polling must preserve navigation nodes and keyboard focus');
console.log('PASS: unchanged module polling preserves the live navigation node.');
update({...state,chatQuestion:'Open Weather',chatAnswer:'<script>text only</script>',chatModule:'Weather',chatStatus:'Ready',chatBusy:false});
assert.equal(nodes.emberAnswer.textContent,'<script>text only</script>');
assert.equal(nodes.emberOpen.hidden,false);nodes.emberOpen.onclick();assert.equal(calls.at(-1).args.command,'open_chat');
nodes.emberInput.value='What needs my attention?';nodes.emberTarget.value='a';nodes.emberForm.onsubmit({preventDefault(){}});
assert.equal(calls.at(-1).args.command,'ask');assert.equal(calls.at(-1).args.text,'What needs my attention?');
const context=JSON.stringify({question:'Open Weather',modules:[{name:'Weather'}],notifications:[{module:'Mail',status:'Unread items',count:'10'}]});
update({...state,chatBusy:true,chatReview:context});assert.equal(nodes.emberForm.hidden,true);assert.equal(nodes.emberReview.hidden,false);
assert.ok(nodes.emberContext.children[2].textContent.includes('Mail: Unread items (10)'));
const stableContext=nodes.emberContext.children[0];update({...state,chatBusy:true,chatReview:context});assert.equal(nodes.emberContext.children[0],stableContext);
nodes.emberBack.onclick();assert.equal(calls.at(-1).args.command,'stop_chat');
console.log('PASS: conversational question, exact context review, text-only answer, explicit opening proposal and draft continuity.');

const twoAgents={...state,targets:JSON.stringify([{id:'qualification',name:'Fuego Mac Qualification',device:'device',workspace:'owned'},{id:'ember',name:'Ember',device:'device',workspace:'owned'}])};
update(twoAgents);assert.equal(nodes.emberTarget.value,'ember','The personal assistant must not default to a qualification agent');
nodes.emberTarget.value='qualification';nodes.emberTarget.onchange();update(twoAgents);assert.equal(nodes.emberTarget.value,'qualification','Explicit owner selection wins');
update({...state,targets:JSON.stringify([{id:'other',name:'Other',device:'device',workspace:'owned'}])});assert.equal(nodes.emberTarget.value,'','A removed selection cannot silently switch agents');
console.log('PASS: Ember default, explicit runtime selection and removed-selection fencing.');

update({...state,voiceAvailable:true,voiceMode:'half',voiceActive:false});
assert.equal(nodes.emberTalk.hidden,false);nodes.emberTalk.onclick();assert.equal(calls.at(-1).args.command,'voice_prepare');
update({...state,voiceAvailable:true,voiceReview:true,voiceTarget:'Ember'});
assert.equal(nodes.emberVoiceReview.hidden,false);assert.equal(nodes.emberAsk.disabled,true);assert.equal(nodes.emberTarget.disabled,true);
nodes.emberVoiceStart.onclick();assert.equal(calls.at(-1).args.command,'voice_start');
const preserved=nodes.emberInput.value;
update({...state,voiceAvailable:true,voiceActive:true,voicePhase:'listening',voicePartial:'Open Weather',voiceStatus:'Listening',voiceMode:'full'});
assert.equal(nodes.emberLiveWords.textContent,'Open Weather');assert.equal(nodes.emberVoiceStop.hidden,false);assert.equal(nodes.emberTalk.hidden,true);assert.equal(nodes.emberDuplex.value,'full');
assert.equal(nodes.emberInput.value,preserved,'Partial speech must not overwrite a typed draft');
nodes.emberVoiceStop.onclick();assert.equal(calls.at(-1).args.command,'voice_stop');
nodes.emberDuplex.value='half';nodes.emberDuplex.onchange();assert.equal(calls.at(-1).args.text,'half');
nodes.emberVoiceSettings.onclick();assert.equal(calls.at(-1).args.command,'voice_settings');
assert.ok(!calls.some(c=>c.args?.command==='voice_start' && !c.name),'Polling cannot start speech');
console.log('PASS: explicit Talk consent, live words, duplex, provider settings, stop and preserved typed draft.');

update({...state,voiceActive:false,voiceStatus:'The microphone stopped responding. Press Talk to reconnect.'});
assert.ok(nodes.emberVoiceStatus.textContent.includes('microphone stopped responding'),'A failed speech provider must stay visible after the session retires');

update({...state,voiceActive:true,voicePhase:'preparing',voiceLevel:0});
assert.equal(nodes.emberPresenceStatus.textContent,'Preparing','Never claim Listening before the shared provider is ready');
assert.equal(nodes.emberHeading.textContent,'Getting ready…');
assert.equal(nodes.emberLiveWords.hidden,true,'No fabricated transcript before recognition is ready');
update({...state,voiceActive:true,voicePhase:'listening',voiceLevel:.75});assert.equal(nodes.emberInputLevel.value,.75);
