local passed,failed=0,0
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1; print('PASS '..name) else failed=failed+1; print('FAIL '..name..': '..tostring(err)) end
end
local function eq(a,b) assert(a==b,('expected %s, got %s'):format(tostring(b),tostring(a))) end
local convars={
    txbridge_wordpress_secret=string.rep('a',64),
    txbridge_privacy_secret=string.rep('b',64),
    txbridge_webhook_secret=string.rep('c',64),
    txbridge_webhook_url='https://wordpress.example.test/wp-json/txbridge/v1/webhook',
    txbridge_txadmin_host_token=string.rep('d',64),
    sv_hostname='Test FiveM',sv_maxclients='48',version='mock-fxserver',
}
local kvp,handlers,timers,threads,exported={},{},{},{},{}
local players={['1']='Alice',['2']='Bob'}
local resources={monitor='started',chat='started',txbridge='started',optional='started'}
local invoker='monitor'
local kicks,messages,nativeRequests=0,0,{}
local responseBehavior=function(_,callback) callback(200,'{}') end
GetConvar=function(k,d) return convars[k] or d end
GetConvarInt=function(k,d) return tonumber(convars[k]) or d end
GetCurrentResourceName=function() return 'txbridge' end
GetResourceKvpString=function(k) return kvp[k] end
SetResourceKvp=function(k,v) kvp[k]=v end
GetResourceState=function(k) return resources[k] or 'missing' end
GetPlayers=function() local t={}; for id in pairs(players) do t[#t+1]=id end; table.sort(t); return t end
GetPlayerName=function(id) return players[tostring(id)] end
GetPlayerPing=function() return 42 end
GetPlayerIdentifiers=function() return {'license:private-license','ip:192.0.2.1','discord:123456789'} end
GetNumResources=function() return 4 end
GetResourceByFindIndex=function(i) return ({'monitor','chat','txbridge','optional'})[i+1] end
GetInvokingResource=function() return invoker end
DropPlayer=function(id,reason) kicks=kicks+1; players[tostring(id)]=nil end
TriggerClientEvent=function() messages=messages+1 end
StartResource=function(name) resources[name]='started'; return true end
StopResource=function(name) resources[name]='stopped'; return true end
AddEventHandler=function(name,fn) handlers[name]=handlers[name] or {}; table.insert(handlers[name],fn) end
SetTimeout=function(ms,fn) timers[#timers+1]={ms=ms,fn=fn} end
CreateThread=function(fn) threads[#threads+1]=fn end
Wait=function() error('Tests must not run infinite resource threads') end
SetHttpHandler=function(fn) _G.handler=fn end
PerformHttpRequest=function(url,callback,method,body,headers,options)
    local req={url=url,method=method,body=body,headers=headers,options=options,callback=callback}
    nativeRequests[#nativeRequests+1]=req; responseBehavior(req,callback)
end
RegisterCommand=function() end
exports=function(name,fn) exported[name]=fn end
source=0
local base='resource/txbridge/'
dofile(base..'config.lua')
local realBurst=Config.Http.burst
Config.Http.burst=10000; Config.Http.requestsPerMinute=10000
for _,file in ipairs({'crypto','core','security','catalog','transport','events','txadmin','api','main'}) do dofile(base..'server/'..file..'.lua') end
local B=TxBridge
local serial=0
local function request(method,path,body,options)
    options=options or {}; serial=serial+1
    local raw=type(body)=='string' and body or (body~=nil and json.encode(body) or '')
    local stamp=options.stamp or tostring(os.time())
    local nonce=options.nonce or ('nonce_with_at_least_24_characters_'..serial)
    local idem=options.idem or (method=='POST' and ('idempotency_key_'..string.format('%08d',serial)) or '')
    local key=options.key or 'wordpress'; local secret=options.secret or convars.txbridge_wordpress_secret
    local headers={['x-txbridge-key']=key,['x-txbridge-timestamp']=stamp,['x-txbridge-nonce']=nonce,
        ['idempotency-key']=idem,['content-type']='application/json'}
    headers['x-txbridge-signature']=B.crypto.hmac(secret,B.canonical(key,method,path,stamp,nonce,idem,options.signBody or raw))
    for k,v in pairs(options.headers or {}) do headers[k]=v end
    local output={}
    local req={method=method,path=path,address=options.peer or '127.0.0.1:54321',headers=headers,
        setCancelHandler=function(fn) output.cancel=fn end,
        setDataHandler=function(fn) if options.holdBody then output.sendBody=fn else fn(raw) end end}
    local res={writeHead=function(status,h) output.status=status; output.headers=h end,
        send=function(s) output.raw=s; output.body=json.decode(s) end}
    handler(req,res)
    return output
end
local function scope(s) Config.Clients.wordpress.scopes[s]=true end

test('default request burst is bounded',function() eq(realBurst,30) end)
test('SHA-256 empty',function() eq(B.crypto.sha256(''),'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') end)
test('SHA-256 abc',function() eq(B.crypto.sha256('abc'),'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') end)
test('SHA-256 multi-block',function() eq(B.crypto.sha256('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),'248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1') end)
test('HMAC RFC 4231 vector 1',function() eq(B.crypto.hmac(string.rep('\11',20),'Hi There'),'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7') end)
test('HMAC RFC 4231 long key',function() eq(B.crypto.hmac(string.rep('\170',131),'Test Using Larger Than Block-Size Key - Hash Key First'),'60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54') end)
test('constant-length comparison',function() assert(B.crypto.equal('abc','abc')); assert(not B.crypto.equal('abc','abd')); assert(not B.crypto.equal('ab','abc')) end)
test('cross-language request protocol vector',function()
    local f=assert(io.open('tests/protocol-vectors.json','r')); local v=json.decode(f:read('*a')); f:close()
    eq(B.crypto.hmac(v.secret,B.canonical(v.key,v.method,v.path,v.timestamp,v.nonce,v.idempotency,v.body)),v.requestSignature)
    eq(B.crypto.hmac(v.webhookSecret,B.webhookCanonical(v.server,v.eventId,v.timestamp,v.eventBody)),v.webhookSignature)
end)
test('signed health read',function() local r=request('GET','/v1/health'); eq(r.status,200); eq(r.body.data.healthy,true) end)
test('status JSON has no secrets',function() local r=request('GET','/v1/status'); eq(r.status,200); eq(r.body.data.players,2); assert(not r.raw:find(convars.txbridge_wordpress_secret,1,true)) end)
test('unknown client rejected',function() eq(request('GET','/v1/status',nil,{key='unknown'}).status,401) end)
test('weak configured secret rejected',function() convars.bad_secret='short'; Config.Clients.bad={secretConvar='bad_secret',scopes={}}; eq(request('GET','/v1/status',nil,{key='bad',secret='short'}).status,401) end)
test('incorrect signature rejected',function() eq(request('GET','/v1/status',nil,{secret=string.rep('f',64)}).status,401) end)
test('expired timestamp rejected',function() eq(request('GET','/v1/status',nil,{stamp=tostring(os.time()-91)}).status,401) end)
test('future timestamp outside window rejected',function() eq(request('GET','/v1/status',nil,{stamp=tostring(os.time()+91)}).status,401) end)
test('replayed nonce rejected',function() local o={nonce=string.rep('z',32)}; eq(request('GET','/v1/status',nil,o).status,200); eq(request('GET','/v1/status',nil,o).status,409) end)
test('future nonce retained through full acceptance window',function()
    local o={nonce=string.rep('y',32),stamp=tostring(os.time()+80)}; eq(request('GET','/v1/status',nil,o).status,200)
    eq(B.security.nonces['wordpress:'..o.nonce],tonumber(o.stamp)+90)
end)
test('unauthorized peer rejected',function() eq(request('GET','/v1/status',nil,{peer='203.0.113.1:2000'}).status,403) end)
test('forwarded-for cannot bypass peer restriction',function() eq(request('GET','/v1/status',nil,{peer='203.0.113.1',headers={['X-Forwarded-For']='127.0.0.1'}}).status,403) end)
test('IPv6 loopback recognized',function() eq(request('GET','/v1/status',nil,{peer='[::1]:1234'}).status,200) end)
test('IPv4-mapped loopback recognized',function() eq(B.peer('[::ffff:127.0.0.1]:1234'),'127.0.0.1') end)
test('duplicate security header rejected',function() eq(request('GET','/v1/status',nil,{headers={['X-TxBridge-Key']='wordpress'}}).status,400) end)
test('GET body rejected',function() eq(request('GET','/v1/status','abc',{headers={['content-length']='3'}}).status,400) end)
test('malformed query escape rejected',function() eq(request('GET','/v1/events?after=%ZZ').status,400) end)
test('duplicate query key rejected',function() eq(request('GET','/v1/events?limit=1&limit=2').status,400) end)
test('traversal path rejected',function() eq(request('GET','/v1/../status').status,400) end)
test('encoded path rejected',function() eq(request('GET','/v1/%73tatus').status,400) end)
test('unknown endpoint is 404',function() eq(request('GET','/v1/missing').status,404) end)
test('missing read scope is 403',function() eq(request('GET','/v1/audit').status,403) end)
test('player names redacted by default',function() local r=request('GET','/v1/players'); eq(r.body.data.items[1].name,'[redacted]'); assert(r.body.data.items[1].sessionId) end)
test('raw identifier endpoint disabled without scope',function() eq(request('GET','/v1/players/1/identifiers').status,403) end)
test('raw identifier endpoint needs privacy opt-in',function() scope('players:identifiers'); eq(request('GET','/v1/players/1/identifiers').status,403) end)
test('raw identifiers never return IP',function() Config.Privacy.exposeIdentifiers=true; local r=request('GET','/v1/players/1/identifiers'); eq(r.status,200); assert(not r.raw:find('192.0.2.1',1,true)); Config.Privacy.exposeIdentifiers=false end)
test('POST requires an idempotency key',function() eq(request('POST','/v1/actions/announce',{}, {idem=''}).status,400) end)
test('POST must be JSON object',function() eq(request('POST','/v1/actions/announce','[]').status,400); eq(request('POST','/v1/actions/announce','null').status,400) end)
test('invalid JSON rejected',function() eq(request('POST','/v1/actions/announce','{no}').status,400) end)
test('JSON content type is strict',function() eq(request('POST','/v1/actions/announce','{}',{headers={['content-type']='application/json-malicious'}}).status,415) end)
test('oversized body rejected',function() eq(request('POST','/v1/actions/announce',string.rep('x',32769)).status,413) end)
test('body tampering rejected',function() eq(request('POST','/v1/actions/announce','{"message":"changed"}',{signBody='{"message":"original"}'}).status,401) end)
test('declared body length mismatch rejected',function() eq(request('POST','/v1/actions/announce','{}',{headers={['content-length']='3'}}).status,400) end)
test('slow request body times out',function() local r=request('POST','/v1/actions/announce','{}',{holdBody=true}); eq(r.status,nil); timers[#timers].fn(); eq(r.status,408); r.sendBody('{}'); eq(r.status,408) end)
test('write action remains disabled after granting scope',function() scope('actions:announce'); eq(request('POST','/v1/actions/announce',{message='Hi'}).status,403) end)
test('announcement via native chat only',function() Config.Actions.announce=true; local n=messages; local r=request('POST','/v1/actions/announce',{message='Hello'}); eq(r.status,200); eq(messages,n+1); eq(r.body.data.txAdminAction,false) end)
test('unknown native action fields rejected',function() eq(request('POST','/v1/actions/announce',{message='Hi',command='quit'}).status,400) end)
test('control characters rejected',function() eq(request('POST','/v1/actions/announce',{message='hello\nquit'}).status,400) end)
test('same idempotency key cannot change body',function()
    local o={idem='same_idempotency_key_0001'}; eq(request('POST','/v1/actions/announce','{"message":"one"}',o).status,200)
    eq(request('POST','/v1/actions/announce','{"message":"two"}',o).status,409)
end)
test('duplicate action returns saved result without executing',function()
    local o={idem='same_idempotency_key_0002'}; local n=messages
    eq(request('POST','/v1/actions/announce','{"message":"once"}',o).status,200)
    local r=request('POST','/v1/actions/announce','{"message":"once"}',o); eq(r.status,200); eq(messages,n+1); eq(r.headers['X-TxBridge-Idempotent-Replay'],'true')
end)
test('pending action is never automatically re-executed',function()
    local idem='pending_idempotency_00001'; local raw='{"message":"once"}'
    B.beginIdempotency({id='wordpress',idem=idem},'POST','/v1/actions/announce',raw)
    local r=request('POST','/v1/actions/announce',raw,{idem=idem}); eq(r.status,409); eq(r.body.error.code,'outcome_unknown')
end)
test('idempotency survives a security-module restart',function()
    local o={idem='persisted_idempotency_0001'}; local raw='{"message":"persist"}'; local n=messages
    eq(request('POST','/v1/actions/announce',raw,o).status,200); dofile(base..'server/security.lua')
    eq(request('POST','/v1/actions/announce',raw,o).status,200); eq(messages,n+1)
end)
test('kick requires current player session',function() scope('actions:kick'); Config.Actions.kick=true; eq(request('POST','/v1/players/1/actions/kick',{reason='test',sessionId='old'}).status,409) end)
test('kick executes without arbitrary console command',function() local n=kicks; local r=request('POST','/v1/players/1/actions/kick',{reason='Test moderation',sessionId=B.session(1)}); eq(r.status,200); eq(kicks,n+1); players['1']='Alice'; B.sessions['1']=nil end)
test('recycled player ID gets a different session',function() local old=B.session(1); B.sessions['1']=nil; local now=B.session(1); assert(old~=now); eq(request('POST','/v1/players/1/actions/kick',{reason='test',sessionId=old}).status,409) end)
test('resource actions disabled by default',function() scope('actions:resource'); eq(request('POST','/v1/resources/optional/actions/restart',{}).status,403) end)
test('resource must be allowlisted',function() Config.Actions.resources=true; eq(request('POST','/v1/resources/optional/actions/restart',{}).status,403) end)
test('monitor remains protected even if allowlisted',function() Config.Actions.allowedResources.monitor=true; eq(request('POST','/v1/resources/monitor/actions/stop',{}).status,403) end)
test('bridge cannot stop itself',function() Config.Actions.allowedResources.txbridge=true; eq(request('POST','/v1/resources/txbridge/actions/stop',{}).status,403) end)
test('allowlisted resource restart succeeds',function() Config.Actions.allowedResources.optional=true; local r=request('POST','/v1/resources/optional/actions/restart',{}); eq(r.status,200); eq(resources.optional,'started') end)
test('all 17 current txAdmin events registered',function() eq(B.count(B.eventSchemas),17); for name in pairs(B.eventSchemas) do assert(handlers['txAdmin:events:'..name]) end end)
test('deprecated events off by default',function() assert(not handlers['txAdmin:events:healedPlayer']) end)
test('client-originated txAdmin event rejected',function() local n=B.journal.sequence; source=12; assert(not B.capture('announcement',{message='fake'})); source=0; eq(B.journal.sequence,n) end)
test('untrusted resource event rejected',function() invoker='untrusted'; assert(not B.capture('announcement',{message='fake'})); invoker='monitor' end)
test('official ban fields captured and HWIDs redacted',function()
    assert(B.capture('playerBanned',{author='Admin',expiration=false,targetIds={'license:abc'},targetHwids={'secret-hardware'},targetName='Alice',reason='private',unknownSecret='no'}))
    local e=B.journal.events[#B.journal.events]; eq(e.data.expiration,false); eq(e.data.targetHwids,'[redacted]'); eq(e.data.targetName,'[redacted]'); assert(e.data.targetIds[1]:match('^hmac:')); eq(e.data.unknownSecret,nil)
end)
test('console command payload is redacted',function() B.capture('consoleCommand',{author='admin',command='set secret password'}); eq(B.journal.events[#B.journal.events].data.command,'[redacted]') end)
test('no-payload configChanged event accepted',function() assert(B.capture('configChanged',nil)) end)
test('adminAuth revoke all clears observed admins',function() B.capture('adminAuth',{netid=1,isAdmin=true}); assert(B.observed.admins['1']); B.capture('adminAuth',{netid=-1,isAdmin=false}); eq(B.count(B.observed.admins),0) end)
test('event feed reports retention gaps',function() local old=Config.Events.retention; Config.Events.retention=2; for i=1,3 do B.publish('custom.test',{value=i}) end; local r=request('GET','/v1/events?after=0&limit=1'); eq(r.status,200); eq(r.body.data.gap,true); eq(#r.body.data.items,1); Config.Events.retention=old end)
test('invalid cursor rejected',function() eq(request('GET','/v1/events?after=-1').status,400) end)
test('full router inventory has 58 entries',function() eq(B.count(B.txRoutes),58) end)
test('txAdmin host integration disabled by default',function() scope('txadmin:host'); eq(request('GET','/v1/txadmin/host/status').status,403) end)
test('host status uses env token header, never query string',function() Config.TxAdmin.hostStatusEnabled=true; local r=request('GET','/v1/txadmin/host/status'); eq(r.status,200); local n=nativeRequests[#nativeRequests]; assert(n.headers['x-txadmin-envtoken']); eq(n.url,'http://127.0.0.1:40120/host/status'); eq(n.options.followLocation,false) end)
test('upstream HTTP 200 application error becomes error',function() responseBehavior=function(_,cb) cb(200,'{"error":"token missing"}') end; eq(request('GET','/v1/txadmin/host/status').status,502); responseBehavior=function(_,cb) cb(200,'{}') end end)
test('experimental adapter disabled by default',function() eq(request('POST','/v1/txadmin/request',{route='player_stats'}).status,403) end)
test('internal adapter requires revision acknowledgement',function() Config.TxAdmin.experimental=true; eq(request('POST','/v1/txadmin/request',{route='player_stats'}).status,503); Config.TxAdmin.acknowledgedRevision=B.revision end)
test('authentication lifecycle routes blocked',function() eq(request('POST','/v1/txadmin/request',{route='auth_self'}).status,403) end)
test('private intercom never exposed',function() eq(request('POST','/v1/txadmin/request',{route='intercom'}).status,403) end)
test('development routes never exposed',function() eq(request('POST','/v1/txadmin/request',{route='dev_get'}).status,403) end)
test('internal adapter needs per-route scope',function() eq(request('POST','/v1/txadmin/request',{route='player_stats'}).status,403); scope('txadmin:player_stats') end)
test('internal route must be explicitly allowlisted',function() eq(request('POST','/v1/txadmin/request',{route='player_stats'}).status,403); Config.TxAdmin.rules={{route='player_stats',params={}}} end)
test('internal adapter needs authorized session',function() eq(request('POST','/v1/txadmin/request',{route='player_stats'}).status,503); convars.txbridge_txadmin_cookie='txAdmin=session; txAdmin.sig=signature'; convars.txbridge_txadmin_csrf='csrf-token-for-test' end)
test('internal adapter forwards fixed route, session and CSRF',function() local r=request('POST','/v1/txadmin/request',{route='player_stats'}); eq(r.status,200); local n=nativeRequests[#nativeRequests]; eq(n.method,'GET'); eq(n.url,'http://127.0.0.1:40120/player/stats'); assert(n.headers.Cookie); assert(n.headers['x-txadmin-csrftoken']); eq(n.headers['x-txadmin-token'],nil) end)
test('expired txAdmin session cannot look successful',function() responseBehavior=function(_,cb) cb(200,'{"logout":true}') end; local r=request('POST','/v1/txadmin/request',{route='player_stats'}); eq(r.status,502); eq(r.body.error.code,'txadmin_session_expired'); responseBehavior=function(_,cb) cb(200,'{}') end end)
test('internal GET body is rejected',function() eq(request('POST','/v1/txadmin/request',{route='player_stats',body={x=1}}).status,400) end)
test('path parameters bind to exact rule',function()
    scope('txadmin:player_actions'); Config.TxAdmin.rules[#Config.TxAdmin.rules+1]={route='player_actions',params={action='warn'}}
    eq(request('POST','/v1/txadmin/request',{route='player_actions',params={action='ban'},body={}}).status,403)
end)
test('unsafe URLs are rejected',function()
    assert(not B.httpsUrl('http://example.com',true)); assert(not B.httpsUrl('http://127.0.0.1:40120.evil',true)); assert(not B.httpsUrl('https://good.example@evil.example',false)); assert(not B.httpsUrl('https://example.com#secret',false)); assert(B.httpsUrl('http://127.0.0.1:40120',true))
end)
test('webhook delivery is signed and uses no redirects',function()
    B.journal.outbox={}; B.publish('custom.delivery',{value=1}); responseBehavior=function(_,cb) cb(202,'{}') end; B.pump(); eq(#B.journal.outbox,0)
    local n=nativeRequests[#nativeRequests]; eq(n.options.followLocation,false); assert(n.headers['X-TxBridge-Signature']); local h=n.headers
    eq(h['X-TxBridge-Signature'],B.crypto.hmac(convars.txbridge_webhook_secret,B.webhookCanonical(h['X-TxBridge-Server'],h['X-TxBridge-Event'],h['X-TxBridge-Timestamp'],n.body)))
end)
test('webhook transient failure queues retry',function() B.journal.outbox={}; B.publish('custom.retry',{}); responseBehavior=function(_,cb) cb(500,'{}') end; B.pump(); eq(#B.journal.outbox,1); eq(B.journal.outbox[1].attempts,1); assert(B.journal.outbox[1].nextAt>os.time()) end)
test('webhook permanent failure enters dead-letter queue',function() B.journal.outbox[1].nextAt=0; responseBehavior=function(_,cb) cb(401,'{}') end; local n=#B.journal.deadLetters; B.pump(); eq(#B.journal.outbox,0); eq(#B.journal.deadLetters,n+1) end)
test('dead-letter retry retains immutable event ID',function() local item=B.journal.deadLetters[#B.journal.deadLetters]; local id=item.eventId; B.retryDelivery(item.id); eq(B.journal.outbox[#B.journal.outbox].eventId,id); B.journal.outbox={} end)
test('outbox capacity is bounded with explicit loss counter',function() local old=Config.Delivery.maxQueue; Config.Delivery.maxQueue=1; local dropped=B.journal.dropped; B.publish('custom.one',{}); B.publish('custom.two',{}); eq(#B.journal.outbox,1); eq(B.journal.dropped,dropped+1); Config.Delivery.maxQueue=old; B.journal.outbox={} end)
test('timed-out native request remains in concurrency accounting',function()
    responseBehavior=function() end; local called=0
    B.httpRequest('https://example.test','POST','{}',{},1,1024,function(status) eq(status,504); called=called+1 end)
    local t=timers[#timers]; t.fn(); eq(called,1); eq(B.metrics.outstanding,1)
    nativeRequests[#nativeRequests].callback(200,'{}'); eq(called,1); eq(B.metrics.outstanding,0)
    responseBehavior=function(_,cb) cb(200,'{}') end
end)
test('native request concurrency is bounded',function() local old=B.metrics.outstanding; B.metrics.outstanding=Config.Delivery.maxOutstandingRequests; local result; B.httpRequest('https://example.test','GET','',{},10,1024,function(status) result=status end); eq(result,503); B.metrics.outstanding=old end)
test('custom publishers denied by default',function() invoker='my_resource'; local id,err=exported.PublishEvent('order.created',{}); eq(id,nil); eq(err,'publisher_not_allowed'); invoker='monitor' end)
test('authorized custom publisher uses custom namespace',function() Config.Events.allowedPublishers.my_resource=true; invoker='my_resource'; assert(exported.PublishEvent('order.created',{orderId=10})); eq(B.journal.events[#B.journal.events].type,'custom.order.created'); invoker='monitor' end)
test('read-only exports do not return references to mutable state',function() local s=exported.GetStatus(); s.serverId='evil'; eq(B.status().serverId,'main') end)
test('rate limiter denies excess requests',function() local a,b=Config.Http.burst,Config.Http.requestsPerMinute; Config.Http.burst=2; Config.Http.requestsPerMinute=60; assert(B.rate('test-new-key')); assert(B.rate('test-new-key')); assert(not B.rate('test-new-key')); Config.Http.burst=a; Config.Http.requestsPerMinute=b end)
test('corrupt KVP is not silently erased',function() kvp['txbridge:bad']='not json'; local ok=pcall(B.read,'bad',{}); assert(not ok) end)
print(('Lua tests: %d passed, %d failed'):format(passed,failed))
assert(failed==0,'Lua test failures')
