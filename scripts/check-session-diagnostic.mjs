// Execute the actual fixed client script with authored, network-free responses.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const text=readFileSync(new URL('../Sources/ModuleCore/FuegoConnectionDiagnostic.swift',import.meta.url),'utf8');
const source=text.split('public static let source = #"""')[1].split('"""#')[0];
const origin='https://fuego.example.org',company='11111111-1111-4111-8111-111111111111';
const body={session:{id:'paperclip:session:subject-canary',userId:'subject-canary'},user:{id:'subject-canary',email:'AUTHORED_PRIVATE_EMAIL'},token:'AUTHORED_DO_NOT_EXPORT'};
const catalog={items:[],nextAfterId:null};
async function run(responses,{selected=company,pageOrigin=origin}={}) {
  const calls=[];let timer,cleared=0,cancelled=0;
  const location={origin:pageOrigin};
  const fn=vm.runInNewContext('(async function(origin,company){'+source+'})',{
    location,AbortController,Uint8Array,TextDecoder,
    setTimeout(f,ms){assert.equal(ms,12000);timer=f;return 1;},clearTimeout(){cleared++;},
    async fetch(url,options){
      calls.push(url);assert.equal(options.method,'GET');assert.equal(options.credentials,'same-origin');
      assert.equal(options.redirect,'error');assert.equal(options.cache,'no-store');assert.equal(options.body,undefined);
      const response=responses[calls.length-1];assert.ok(response,'Unexpected request');
      if(response.abort){timer();assert.ok(options.signal.aborted);throw Error('authored aborted fetch');}
      if(response.error)throw Error('authored transport/redirect refusal');
      const bytes=response.raw??new TextEncoder().encode(JSON.stringify(response.body));let sent=false;
      return {status:response.status??200,headers:{get(){return response.mime??'application/json';}},
        body:{getReader(){return {async read(){if(response.changeOrigin)location.origin='https://foreign.example.org';if(sent)return {done:true};sent=true;return {done:false,value:bytes};},async cancel(){cancelled++;}};}}};
    }
  });
  const result=JSON.parse(JSON.stringify(await fn(origin,selected)));
  assert.deepEqual(Object.keys(result).sort(),['catalogHTTPStatus','catalogRead','sessionHTTPStatus','sessionKind']);
  assert.ok(!/subject-canary|AUTHORED_PRIVATE|AUTHORED_DO_NOT_EXPORT/.test(JSON.stringify(result)));
  return {result,calls,cleared,cancelled};
}
let checks=0;
const row={entryId:company,headRevisionId:company,publicationId:null,version:1,availability:'active'};
let v=await run([{body},{body:catalog}]);assert.equal(v.result.sessionKind,'humanWebSession');assert.equal(v.result.catalogRead,'eligible');
assert.deepEqual(v.calls,[origin+'/api/auth/get-session',origin+'/api/companies/'+company+'/flows']);assert.equal(v.cleared,1);checks++;
v=await run([{body},{body:{items:[row,row],nextAfterId:null}}]);assert.equal(v.result.catalogRead,'eligible');checks++;
v=await run([{body},{body:{items:Array(101).fill(row),nextAfterId:null}}]);assert.equal(v.result.catalogRead,'unknown');checks++;
// JSON arrays/scalars cannot stand in for UUID strings through RegExp coercion.
for(const field of ['entryId','headRevisionId','publicationId']) {
  for(const malformed of [[],[company],{value:company},true,1,null]) {
    if(field==='publicationId'&&malformed===null)continue;
    const invalid={...row,[field]:malformed};
    v=await run([{body},{body:{items:[invalid],nextAfterId:null}}]);
    assert.equal(v.result.catalogRead,'unknown',field+' requires a UUID string');checks++;
  }
}
v=await run([{body},{body:{items:[{...row,publicationId:company}],nextAfterId:company}}]);assert.equal(v.result.catalogRead,'eligible');checks++;
v=await run([{body}],{selected:''});assert.equal(v.calls.length,1);assert.equal(v.result.catalogRead,'unknown');checks++;
for(const [kind,label] of [['board_key','boardKey'],['local_implicit','localImplicit'],['cloud_tenant_auth','unknown']]){
  const data=structuredClone(body);data.session.id='paperclip:'+kind+':subject-canary';
  v=await run([{body:data}]);assert.equal(v.result.sessionKind,label);assert.equal(v.calls.length,1);assert.equal(v.result.catalogRead,'unknown');checks++;
}
v=await run([{status:401,body:{}}]);assert.equal(v.result.sessionKind,'signedOut');assert.equal(v.calls.length,1);checks++;
for(const status of [401,403,404,405,503]){
  v=await run([{body},{status,body:{}}]);assert.equal(v.result.catalogRead,[401,403].includes(status)?'denied':'unavailable');
  if(status===401)assert.equal(v.result.sessionKind,'signedOut');checks++;
}
for(const data of [{items:[],nextAfterId:null,owner:true},{items:[{},{}],nextAfterId:null},{items:[],nextAfterId:'bad'}]){
  v=await run([{body},{body:data}]);assert.equal(v.result.catalogRead,'unknown');checks++;
}
for(const data of [null,{session:body.session,user:{id:'different'}},{...body,session:{...body.session,id:'unknown-session-format'}}]){
  v=await run([{body:data}]);assert.equal(v.result.sessionKind,'unknown');assert.equal(v.calls.length,1);checks++;
}
v=await run([{body,mime:'text/html'}]);assert.equal(v.result.sessionKind,'unknown');checks++;
v=await run([{raw:new Uint8Array(65537)}]);assert.equal(v.result.sessionKind,'unknown');assert.equal(v.cancelled,1);checks++;
v=await run([{body},{body:catalog,changeOrigin:true}]);assert.equal(v.result.sessionKind,'unknown');assert.equal(v.result.catalogRead,'unknown');checks++;
v=await run([],{pageOrigin:'https://foreign.example.org'});assert.equal(v.calls.length,0);checks++;
v=await run([],{selected:'../other-company'});assert.equal(v.calls.length,0);checks++;
for(const response of [{error:true},{abort:true}]){v=await run([response]);assert.equal(v.result.sessionKind,'unknown');assert.equal(v.cleared,1);checks++;}
console.log('PASS: '+checks+' fixed-script metadata cases; no live network, UI or credentials');
