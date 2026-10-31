// Execute the maintained fixed script against authored local responses only.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source=readFileSync(new URL('../Sources/ModuleCore/EmberConversationReadScript.swift',import.meta.url),'utf8')
  .split('public static let source = #"""')[1].split('"""#')[0];
const origin='https://fuego-bridge.curtishome.org', company='a1111111-1111-4111-8111-111111111111', agent='a2222222-2222-4222-8222-222222222222';
const auth=user=>({session:{id:'paperclip:session:'+user,userId:user},user:{id:user,email:'AUTHORED_PRIVATE_EMAIL'},token:'AUTHORED_SECRET_CANARY',sentryDsn:'AUTHORED_PRIVATE_DSN'});
const snapshot={conversation:null,messages:[],turns:[],hasEarlierMessages:false,limits:{maxTextBytes:4096,maxEnvelopeBytes:8192,maxContextBytes:8192}};
const good=()=>[{body:auth('owner')},{body:snapshot},{body:auth('owner')}];
async function run(responses,{pageOrigin=origin,selectedCompany=company,selectedAgent=agent}={}) {
  let timer,cleared=0,cancelled=0,clock=100,signal;
  const calls=[],location={origin:pageOrigin};
  const fn=vm.runInNewContext('(async function(origin,company,agent){'+source+'})',{
    location,AbortController,Uint8Array,TextDecoder,performance:{now:()=>clock},
    setTimeout(f,ms){assert.equal(ms,12000);assert.equal(timer,undefined);timer=f;return 1;},clearTimeout(){cleared++;},
    async fetch(url,options){
      assert.ok(!options.signal.aborted);assert.equal(options.method,'GET');assert.equal(options.credentials,'same-origin');
      assert.equal(options.redirect,'error');assert.equal(options.cache,'no-store');assert.equal(options.body,undefined);
      assert.equal(options.referrer,origin+'/');assert.equal(options.referrerPolicy,'same-origin');
      assert.deepEqual(JSON.parse(JSON.stringify(options.headers)),{Accept:'application/json'});
      signal??=options.signal;assert.equal(signal,options.signal,'One shared abort controller');
      calls.push(url);const row=responses[calls.length-1];assert.ok(row,'Unexpected request');
      if(row.abort){timer();assert.ok(signal.aborted);throw Error('authored abort');}
      if(row.error)throw Error('authored transport/redirect refusal');
      const bytes=row.raw??new TextEncoder().encode(JSON.stringify(row.body));let sent=false;
      return {status:row.status??200,headers:{get(){return row.mime??'application/json; charset=utf-8';}},
        body:row.noBody?null:{getReader(){return {async read(){
          if(row.foreign)location.origin='https://foreign.example.org';
          if(row.elapsed!==undefined)clock=100+row.elapsed;
          if(sent)return {done:true};sent=true;return {done:false,value:bytes};
        },async cancel(){cancelled++;}};}}};
    }
  });
  const result=JSON.parse(JSON.stringify(await fn(origin,selectedCompany,selectedAgent)));
  assert.deepEqual(Object.keys(result).sort(),['afterUser','beforeUser','body','contentType','status']);
  assert.ok(!/AUTHORED_PRIVATE|AUTHORED_SECRET|paperclip:session:/.test(JSON.stringify(result)),'Auth payload must not cross the isolated-world projection');
  assert.equal(cleared,timer?1:0);
  return {result,calls,cancelled};
}
let checks=0;
let v=await run(good());assert.equal(v.result.status,200);assert.equal(v.result.beforeUser,'owner');assert.equal(v.result.afterUser,'owner');
assert.deepEqual(v.calls,[origin+'/api/auth/get-session',origin+'/api/companies/'+company+'/ember/'+agent,origin+'/api/auth/get-session']);checks++;
for(const user of ['opaque:owner','\u00e9','e\u0301']){
  v=await run([{body:auth(user)},{body:snapshot},{body:auth(user)}]);assert.equal(v.result.beforeUser,user);checks++;
}
for(const position of [0,2])for(const status of [401,403,500]){
  const rows=good();rows[position]={status,body:{error:'AUTHORED_SECRET_CANARY'}};v=await run(rows);
  assert.equal(v.result.status,[401,403].includes(status)?status:0);assert.equal(v.result.beforeUser,'');
  assert.equal(v.calls.length,position===0?1:3);checks++;
}
for(const source of ['board_key','local_implicit','cloud_tenant_auth','none']){
  const value=auth('owner');value.session.id='paperclip:'+source+':owner';v=await run([{body:value}]);
  assert.equal(v.calls.length,1);assert.equal(v.result.status,0);checks++;
}
for(const body of [null,{},[],{session:{userId:'owner',id:'paperclip:session:owner'},user:{id:'other'}},auth('')]){
  v=await run([{body}]);assert.equal(v.calls.length,1);assert.equal(v.result.status,0);checks++;
}
for(const user of ['another-owner','e\u0301']){
  const before=user==='e\u0301'?'\u00e9':'owner';v=await run([{body:auth(before)},{body:snapshot},{body:auth(user)}]);
  assert.equal(v.result.status,0);assert.equal(v.result.body,'');checks++;
}
for(const position of [0,1,2])for(const row of [{mime:'application/jsonp',body:{}},{mime:'text/html',body:{}},{noBody:true},{raw:new Uint8Array([0xff])},{foreign:true,body:{}},{error:true}]){
  const rows=good();rows[position]=row;v=await run(rows);assert.equal(v.result.status,0);checks++;
}
v=await run([{raw:new Uint8Array(65537)}]);assert.equal(v.result.status,0);assert.equal(v.cancelled,1);checks++;
v=await run([{body:auth('owner')},{raw:new Uint8Array(524289)},{body:auth('owner')}]);assert.equal(v.result.status,0);assert.equal(v.calls.length,3);assert.equal(v.cancelled,1);checks++;
// Inclusive maximum snapshot size; bytes are real padded UTF8, not a reported count.
const padded=JSON.stringify(snapshot).padEnd(524288,' ');
v=await run([{body:auth('owner')},{raw:new TextEncoder().encode(padded)},{body:auth('owner')}]);assert.equal(v.result.status,200);assert.equal(v.result.body.length,524288);checks++;
for(const position of [0,1,2]){
  const rows=good();rows[position]={abort:true};v=await run(rows);assert.equal(v.result.status,0);checks++;
  const slow=good();slow[position]={body:position===1?snapshot:auth('owner'),elapsed:12000};v=await run(slow);assert.equal(v.result.status,0);checks++;
}
const denied=good();denied[1]={status:403,body:{error:'denied'}};v=await run(denied);assert.equal(v.result.status,403);assert.equal(v.calls.length,3);checks++;
for(const options of [{pageOrigin:'https://foreign.example.org'},{selectedCompany:'../other'},{selectedAgent:'not-an-agent'}]){
  v=await run([] ,options);assert.equal(v.calls.length,0);assert.equal(v.result.status,0);checks++;
}
console.log(JSON.stringify({result:'pass',checks,scope:'actual fixed script with authored local responses; no live network/account/app',snapshotRequestsPerSuccessfulRead:1,authProofReads:2,totalBudgetMs:12000}));
