// Execute the maintained fixed script with authored local fetches only.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import vm from 'node:vm';
assert.equal(Number(process.versions.node.split('.')[0]),24,'This producer qualification selects actual Node24');
const source=readFileSync(new URL('../Sources/ModuleCore/RunEventReadProducer.swift',import.meta.url),'utf8')
  .split('public static let source = #"""')[1].split('"""#')[0];
const origin='https://fuego.example.org', runID='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const auth=user=>({session:{id:'paperclip:session:'+user,userId:user},user:{id:user,email:'PRIVATE_AUTH_CANARY'},token:'SECRET_AUTH_CANARY',sentryDsn:'PRIVATE_DSN_CANARY'});
const page=[{id:1,companyId:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',agentId:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',runId:runID,
  seq:1,eventType:'future',stream:null,level:'unknown',color:null,message:'é🔥\u0000[REDACTED]',payload:{zero:0,no:false,nil:null},createdAt:'2026-10-30T12:00Z'}];
const good=()=>[{body:auth('opaque-human')},{body:page},{body:auth('opaque-human')}];
async function invoke(responses,{pageOrigin=origin,run=runID,afterSeq=0,remainingMs=12000}={}){
  let timer,cleared=0,cancelled=0,clock=100,signal;
  const calls=[],location={origin:pageOrigin};
  const fn=vm.runInNewContext('(async function(origin,run,afterSeq,remainingMs){'+source+'})',{
    location,AbortController,Uint8Array,TextDecoder,performance:{now:()=>clock},
    setTimeout(f,ms){assert.equal(ms,remainingMs);assert.equal(timer,undefined);timer=f;return 1;},clearTimeout(){cleared++;},
    async fetch(url,options){
      assert.ok(!options.signal.aborted);assert.equal(options.method,'GET');assert.equal(options.credentials,'same-origin');
      assert.equal(options.redirect,'error');assert.equal(options.cache,'no-store');assert.equal(options.body,undefined);
      assert.equal(options.referrer,origin+'/');assert.equal(options.referrerPolicy,'same-origin');
      assert.deepEqual(JSON.parse(JSON.stringify(options.headers)),{Accept:'application/json'});
      signal??=options.signal;assert.equal(signal,options.signal,'One shared abort controller');
      calls.push(url);const row=responses[calls.length-1];assert.ok(row,'Unexpected or repeated request');
      if(row.abort){timer();throw Error('Authored abort');}
      if(row.error)throw Error('Authored transport/redirect refusal');
      const chunks=row.chunks??[row.raw??new TextEncoder().encode(JSON.stringify(row.body))];let at=0;
      return {status:row.status??200,headers:{get(){return row.mime??'application/json; charset=utf-8';}},
        body:row.noBody?null:{getReader(){return {async read(){
          if(row.foreign)location.origin='https://other.example.org';
          if(row.elapsed!==undefined)clock=100+row.elapsed;
          if(at===chunks.length)return {done:true};return {done:false,value:chunks[at++]};
        },async cancel(){cancelled++;}};}}};
    }
  });
  const result=JSON.parse(JSON.stringify(await fn(origin,run,afterSeq,remainingMs)));
  assert.deepEqual(Object.keys(result).sort(),['afterUser','beforeUser','body','contentType','eventGetCount','normalProofReadCount','status']);
  assert.ok(!/PRIVATE_.*CANARY|SECRET_AUTH_CANARY|paperclip:session:/.test(JSON.stringify(result)),'Auth data cannot cross projection');
  assert.equal(result.eventGetCount,calls.filter(x=>x.includes('/events?')).length);
  assert.equal(result.normalProofReadCount,calls.filter(x=>x.endsWith('/api/auth/get-session')).length);
  assert.ok(result.eventGetCount<=1);assert.ok(result.normalProofReadCount<=2);
  assert.equal(cleared,timer?1:0);
  return {result,calls,cancelled};
}
let checks=0;
let v=await invoke(good());assert.equal(v.result.status,200);assert.equal(v.result.beforeUser,'opaque-human');assert.equal(v.result.afterUser,'opaque-human');
assert.deepEqual(JSON.parse(v.result.body),page);assert.deepEqual(v.calls,[origin+'/api/auth/get-session',origin+'/api/heartbeat-runs/'+runID+'/events?afterSeq=0&limit=50',origin+'/api/auth/get-session']);checks++;
for(const human of ['opaque:human','é','e\u0301','\u0000']){
  v=await invoke([{body:auth(human)},{body:page},{body:auth(human)}]);assert.equal(v.result.beforeUser,human);checks++;
}
for(const side of [0,2])for(const status of [401,403,500]){
  const rows=good();rows[side]={status,body:{error:'SECRET_AUTH_CANARY'}};v=await invoke(rows);
  assert.equal(v.result.status,[401,403].includes(status)?status:0);assert.equal(v.result.beforeUser,'');assert.equal(v.calls.length,side===0?1:3);checks++;
}
for(const source of ['board_key','local_implicit','cloud_tenant_auth','none']){
  const value=auth('opaque-human');value.session.id='paperclip:'+source+':opaque-human';v=await invoke([{body:value}]);assert.equal(v.result.status,0);assert.equal(v.calls.length,1);checks++;
}
for(const body of [null,{},[],auth(''),{session:{userId:'human',id:'paperclip:session:human'},user:{id:'other'}}]){
  v=await invoke([{body}]);assert.equal(v.result.status,0);assert.equal(v.result.eventGetCount,0);checks++;
}
for(const [before,after] of [['human','other'],['é','e\u0301']]){
  v=await invoke([{body:auth(before)},{body:page},{body:auth(after)}]);assert.equal(v.result.status,0);assert.equal(v.result.body,'');checks++;
}
for(const side of [0,1,2])for(const row of [{mime:'application/jsonp',body:{}},{mime:'text/html',body:{}},{noBody:true},{raw:new Uint8Array([0xff])},{foreign:true,body:{}},{error:true}]){
  const rows=good();rows[side]=row;v=await invoke(rows);assert.equal(v.result.status,0);checks++;
}
for(const side of [0,1,2]){
  const rows=good();rows[side]={abort:true};v=await invoke(rows);assert.equal(v.result.status,0);checks++;
  const expired=good();expired[side]={body:side===1?page:auth('opaque-human'),elapsed:12000};v=await invoke(expired);assert.equal(v.result.status,0);checks++;
}
const padded=(body,n)=>{const text=JSON.stringify(body);return new TextEncoder().encode(text+' '.repeat(n-Buffer.byteLength(text)));};
v=await invoke([{raw:padded(auth('opaque-human'),65536)},{raw:padded(page,524288)},{raw:padded(auth('opaque-human'),65536)}]);
assert.equal(v.result.status,200);assert.equal(Buffer.byteLength(v.result.body),524288);checks++;
for(const side of [0,1,2]){
  const rows=good();rows[side]={raw:new Uint8Array(side===1?524289:65537)};v=await invoke(rows);
  assert.equal(v.result.status,0);assert.equal(v.cancelled,1);checks++;
}
const encoded=new TextEncoder().encode(JSON.stringify(page));
v=await invoke([{body:auth('opaque-human')},{chunks:[encoded.slice(0,4),encoded.slice(4,encoded.length-1),encoded.slice(-1)]},{body:auth('opaque-human')}]);assert.deepEqual(JSON.parse(v.result.body),page);checks++;
// BOM bytes count toward the raw bound and survive event projection. Auth BOM
// is conservatively refused by JSON.parse rather than silently stripped.
const bom=new Uint8Array([0xef,0xbb,0xbf]);
const prefixed=bytes=>new Uint8Array(Buffer.concat([bom,bytes]));
let bomPage=prefixed(encoded);
v=await invoke([{body:auth('opaque-human')},{raw:bomPage},{body:auth('opaque-human')}]);
assert.equal(v.result.status,200);assert.deepEqual(Buffer.from(v.result.body,'utf8'),Buffer.from(bomPage));checks++;
v=await invoke([{body:auth('opaque-human')},{chunks:[bom.slice(0,1),bom.slice(1),encoded]},{body:auth('opaque-human')}]);
assert.equal(v.result.status,200);assert.deepEqual(Buffer.from(v.result.body,'utf8'),Buffer.from(bomPage));checks++;
bomPage=prefixed(padded(page,524285));
v=await invoke([{body:auth('opaque-human')},{raw:bomPage},{body:auth('opaque-human')}]);
assert.equal(v.result.status,200);assert.equal(Buffer.byteLength(v.result.body),524288);assert.deepEqual(Buffer.from(v.result.body),Buffer.from(bomPage));checks++;
v=await invoke([{body:auth('opaque-human')},{raw:prefixed(padded(page,524286))},{body:auth('opaque-human')}]);
assert.equal(v.result.status,0);assert.equal(v.cancelled,1);checks++;
for(const side of [0,2]){
  const rows=good();rows[side]={raw:prefixed(new TextEncoder().encode(JSON.stringify(auth('opaque-human'))))};v=await invoke(rows);
  assert.equal(v.result.status,0);assert.equal(v.result.body,'');assert.equal(v.result.eventGetCount,side===0?0:1);checks++;
}
v=await invoke(good(),{afterSeq:Number.MAX_SAFE_INTEGER,remainingMs:700});assert.equal(v.result.status,200);
assert.ok(v.calls[1].endsWith('afterSeq=9007199254740991&limit=50'));checks++;
const expired=good();expired[1]={body:page,elapsed:700};v=await invoke(expired,{remainingMs:700});assert.equal(v.result.status,0);checks++;
for(const status of [400,401,403,404,500]){
  const rows=good();rows[1]={status,body:{error:'redacted'}};v=await invoke(rows);assert.equal(v.result.status,status);assert.equal(v.calls.length,3);checks++;
}
for(const options of [{pageOrigin:'https://other.example.org'},{run:'../other'},{run:runID+'\n'},{run:runID.toUpperCase()},
  {afterSeq:-1},{afterSeq:0.5},{afterSeq:Number.MAX_SAFE_INTEGER+1},{afterSeq:true},{remainingMs:0},{remainingMs:-1},{remainingMs:Infinity},{remainingMs:NaN},{remainingMs:12001}]){
  v=await invoke([],options);assert.equal(v.result.status,0);assert.equal(v.calls.length,0);checks++;
}
console.log(JSON.stringify({result:'pass',checks,node:process.versions.node,scriptSHA256:createHash('sha256').update(source).digest('hex'),
  scope:'Actual maintained script with authored local responses; zero live requests/account/app',eventRequestsPerSuccessfulRead:1,authProofReads:2,
  maximumAcceptanceMs:12000,transportQuiescenceProven:false}));
