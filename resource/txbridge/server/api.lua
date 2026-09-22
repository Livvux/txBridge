local B=TxBridge
local pendingBodies=0
local function decodeQuery(raw)
    local out={}
    if not raw or raw=='' then return out end
    local function decode(s)
        B.check(not s:gsub('%%[%x][%x]',''):find('%%'),400,'invalid_query','Malformed percent escape.')
        return (s:gsub('+',' '):gsub('%%(%x%x)',function(h) return string.char(tonumber(h,16)) end))
    end
    for pair in raw:gmatch('[^&]+') do
        local k,v=pair:match('^([^=]+)=(.*)$')
        B.check(k~=nil,400,'invalid_query','Use key=value query parameters.')
        k,v=decode(k),decode(v)
        B.check(not out[k] and #k<=64 and #v<=2048 and not (k..v):find('[%c]'),400,'invalid_query','Duplicate or invalid query parameter.')
        out[k]=v
    end
    B.check(B.count(out)<=20,400,'invalid_query','Too many query parameters.')
    return out
end
local function fields(body,allowed)
    B.check(B.object(body),400,'invalid_body','A JSON object is required.')
    for key in pairs(body) do B.check(allowed[key],400,'invalid_body','Unknown field: '..tostring(key)) end
end
local function text(value,max)
    B.check(type(value)=='string' and #value>=1 and #value<=max and value:find('%S') and not value:find('[%c]'),400,'invalid_text','Text must be nonempty, bounded, and contain no control characters.')
    return value
end
local function player(id,body)
    B.check(id and id>=1 and id%1==0 and GetPlayerName(tostring(id)),404,'player_not_found','Player not connected.')
    B.check(type(body.sessionId)=='string' and body.sessionId==B.session(id),409,'player_session_changed','Fetch the current player session before acting.')
    return tostring(id)
end
function B.capabilities()
    local events=B.array(); for name in pairs(B.eventSchemas) do events[#events+1]='txAdmin:events:'..name end; table.sort(events)
    return {version=B.version,serverId=Config.ServerId,events=events,deprecatedCapture=Config.Events.captureDeprecated,
        actions=B.copy(Config.Actions),rawIdentifiers=Config.Privacy.exposeIdentifiers,
        txAdmin={hostStatus=Config.TxAdmin.hostStatusEnabled,experimental=Config.TxAdmin.experimental,auditedRevision=B.revision},
        guarantees={fullDatabaseSync=false,worksWhenFxserverStopped=false,exactlyOnce=false},
        signing='TXBRIDGE1',webhookSigning='TXBRIDGE-WEBHOOK1'}
end
function B.dispatch(method,path,query,body,client,done)
    if method=='GET' then
        if path=='/v1/health' then B.scope(client,'status:read'); done(200,{healthy=not B.fault,serverId=Config.ServerId}); return
        elseif path=='/v1/status' then B.scope(client,'status:read'); done(200,B.status()); return
        elseif path=='/v1/capabilities' then B.scope(client,'status:read'); done(200,B.capabilities()); return
        elseif path=='/v1/players' then B.scope(client,'players:read'); done(200,{items=B.players()}); return
        elseif path=='/v1/resources' then B.scope(client,'resources:read'); done(200,{items=B.resources()}); return
        elseif path=='/v1/txadmin/state' then B.scope(client,'events:read'); done(200,{observed=B.copy(B.observed),authoritative=false}); return
        elseif path=='/v1/txadmin/routes' then B.scope(client,'status:read'); done(200,B.txCatalog()); return
        elseif path=='/v1/txadmin/host/status' then B.txHost(client,done); return
        elseif path=='/v1/events' then
            B.scope(client,'events:read')
            local after=tonumber(query.after or '0'); local limit=tonumber(query.limit or '50')
            B.check(after and after>=0 and after%1==0 and after<=B.journal.sequence,400,'invalid_cursor','after must be a known nonnegative sequence.')
            B.check(limit and limit%1==0 and limit>=1 and limit<=100,400,'invalid_limit','limit must be 1–100.')
            local items=B.array(); local oldest=B.journal.sequence+1
            for _,e in ipairs(B.journal.events) do
                if e.emittedAt>=os.time()-Config.Events.maxEventAgeSeconds then
                    oldest=math.min(oldest,e.sequence)
                    if e.sequence>after and #items<limit then items[#items+1]=e end
                end
            end
            done(200,{items=items,cursor=#items>0 and items[#items].sequence or after,
                latest=B.journal.sequence,oldestAvailable=oldest,gap=after<oldest-1,authoritative=false}); return
        elseif path=='/v1/audit' then B.scope(client,'audit:read'); done(200,{items=B.array(B.copy(B.journal.audit)),tamperProof=false}); return
        elseif path=='/v1/webhooks' then B.scope(client,'webhooks:read'); done(200,B.deliveryStatus()); return
        elseif path=='/v1/webhooks/dead-letters' then
            B.scope(client,'webhooks:read'); local items=B.array()
            for _,d in ipairs(B.journal.deadLetters) do items[#items+1]={id=d.id,eventId=d.eventId,endpoint=d.endpoint,type=d.type,attempts=d.attempts,lastError=d.lastError,failedAt=d.failedAt} end
            done(200,{items=items}); return
        end
        local id=path:match('^/v1/players/(%d+)/identifiers$')
        if id then
            B.scope(client,'players:identifiers')
            B.check(Config.Privacy.exposeIdentifiers,403,'disabled','Raw player identifiers are disabled.')
            B.check(GetPlayerName(id)~=nil,404,'player_not_found','Player not connected.')
            local ids=B.array()
            for _,identifier in ipairs(GetPlayerIdentifiers(id)) do
                local kind=identifier:match('^([^:]+):')
                if Config.Privacy.allowedIdentifierTypes[kind] and kind~='ip' then ids[#ids+1]=identifier end
            end
            done(200,{id=tonumber(id),sessionId=B.session(id),identifiers=ids}); return
        end
    elseif method=='POST' then
        if path=='/v1/txadmin/request' then fields(body,{route=true,params=true,query=true,body=true}); B.txRequest(client,body,done); return
        elseif path=='/v1/webhooks/retry' then
            B.scope(client,'webhooks:write'); fields(body,{deliveryId=true})
            done(202,B.retryDelivery(text(body.deliveryId,192))); return
        elseif path=='/v1/actions/announce' then
            B.scope(client,'actions:announce'); B.check(Config.Actions.announce,403,'disabled','Announcements disabled.')
            fields(body,{message=true}); local message=text(body.message,512)
            B.check(GetResourceState('chat')=='started',409,'chat_not_running','Default chat resource must be started.')
            TriggerClientEvent('chat:addMessage',-1,{args={'Server',message}})
            B.publish('bridge.announcement',{message=message,author=client.id})
            done(200,{sent=true,via='fivem_chat',txAdminAction=false}); return
        end
        local id,action=path:match('^/v1/players/(%d+)/actions/([%w_-]+)$')
        if id and (action=='kick' or action=='message') then
            B.scope(client,'actions:'..action); B.check(Config.Actions[action],403,'disabled','Action disabled.')
            fields(body,action=='kick' and {sessionId=true,reason=true} or {sessionId=true,message=true})
            local target=player(tonumber(id),body)
            if action=='kick' then
                local reason=text(body.reason,256); DropPlayer(target,reason)
                B.publish('bridge.playerKicked',{target=tonumber(id),author=client.id,reason=reason})
                done(200,{requested=true,via='DropPlayer',txAdminAction=false})
            else
                local message=text(body.message,512)
                B.check(GetResourceState('chat')=='started',409,'chat_not_running','Default chat resource must be started.')
                TriggerClientEvent('chat:addMessage',tonumber(id),{args={'Server',message}})
                B.publish('bridge.playerMessaged',{target=tonumber(id),author=client.id,message=message})
                done(200,{sent=true,via='fivem_chat',txAdminAction=false})
            end
            return
        end
        local resource,operation=path:match('^/v1/resources/([%w_-]+)/actions/([%w_-]+)$')
        if resource and (operation=='start' or operation=='stop' or operation=='restart') then
            B.scope(client,'actions:resource'); B.check(Config.Actions.resources,403,'disabled','Resource actions disabled.')
            fields(body,{})
            B.check(resource~=B.resource and resource~='monitor' and not Config.Actions.protectedResources[resource],403,'protected_resource','Protected resource.')
            B.check(Config.Actions.allowedResources[resource],403,'resource_not_allowlisted','Resource is not allowlisted.')
            local before=GetResourceState(resource)
            B.check(before~='missing' and before~='unknown',404,'resource_not_found','Resource not found.')
            local ok=true
            if operation=='stop' or operation=='restart' then ok=StopResource(resource) end
            if ok and (operation=='start' or operation=='restart') then ok=StartResource(resource) end
            local result={resource=resource,operation=operation,before=before,after=GetResourceState(resource),success=ok==true}
            B.publish('bridge.resourceAction',result)
            if not ok then done(409,{code='resource_action_failed',message='Resource transition failed or partially completed.',result=result}) else done(200,result) end
            return
        end
    end
    B.fail(404,'not_found','Endpoint not found.')
end
local function safeError(err)
    if type(err)=='table' and err.status and err.code then return err.status,{code=err.code,message=err.message} end
    -- Do not leak Lua traces, request bodies, secrets or upstream cookie values.
    return 500,{code='internal_error',message='Internal bridge error. Check local deployment and storage.'}
end
function B.httpHandler(req,res)
    local completed=false; local canceled=false; local client=nil; local idemKey=nil; local receiving=false
    local function finish(status,data)
        if completed then return end
        completed=true
        if receiving then pendingBodies=math.max(0,pendingBodies-1); receiving=false end
        local payload=status<400 and {ok=true,data=data} or {ok=false,error=data}
        if idemKey then B.finishIdempotency(idemKey,status,payload) end
        if client and req.method=='POST' then B.audit(client.id,req.path,status) end
        if not canceled then
            res.writeHead(status,{['Content-Type']='application/json; charset=utf-8',['Cache-Control']='no-store',
                ['X-Content-Type-Options']='nosniff',['Retry-After']=status==429 and '60' or nil})
            res.send(json.encode(payload))
        end
    end
    local function catch(fn)
        local ok,err=pcall(fn)
        if not ok then local status,data=safeError(err); finish(status,data) end
    end
    catch(function()
        B.check(Config.Http.enabled,503,'disabled','Bridge HTTP is disabled.')
        B.check(not B.fault,503,'bridge_fault','Bridge configuration or storage fault.')
        local peer=B.peer(req.address)
        B.check(Config.Http.allowedPeers[peer]==true,403,'peer_forbidden','Socket peer is not allowed.')
        B.check(B.rate('peer:'..peer),429,'rate_limited','Too many requests.')
        local headers=B.headers(req.headers)
        B.check(req.method=='GET' or req.method=='POST',405,'method_not_allowed','Only GET and POST are supported.')
        B.check(type(req.path)=='string' and #req.path<=4096 and not req.path:find('[%c%s]'),400,'invalid_path','Invalid request target.')
        local path,rawQuery=req.path:match('^([^?]+)%??(.*)$')
        B.check(path and path:sub(1,4)=='/v1/' and not path:find('%%') and not path:find('..',1,true) and not path:find('//',1,true) and not path:find('\\',1,true),400,'invalid_path','Use an unencoded /v1/ path.')
        local query=decodeQuery(rawQuery)
        local length=headers['content-length']
        if length then
            B.check(length:match('^%d+$') and #length<=8 and tonumber(length)<=Config.Http.maxBodyBytes,413,'body_too_large','Request body too large or invalid Content-Length.')
        end
        local function process(raw)
            if completed then return end
            catch(function()
                B.check(type(raw)=='string' and #raw<=Config.Http.maxBodyBytes,413,'body_too_large','Request body too large.')
                if length then B.check(#raw==tonumber(length),400,'length_mismatch','Content-Length mismatch.') end
                client=B.authenticate(req.method,req.path,headers,raw)
                local body={}
                if req.method=='POST' then
                    local contentType=(headers['content-type'] or ''):lower()
                    B.check(contentType:match('^application/json%s*$') or contentType:match('^application/json%s*;'),415,'json_required','Use application/json.')
                    local ok,value=pcall(json.decode,raw)
                    B.check(ok and B.object(value),400,'invalid_json','Body must be a JSON object.')
                    body=value
                    local cached
                    idemKey,cached=B.beginIdempotency(client,req.method,req.path,raw)
                    if cached then
                        completed=true
                        if receiving then pendingBodies=math.max(0,pendingBodies-1); receiving=false end
                        if not canceled then res.writeHead(cached.status,{['Content-Type']='application/json',['Cache-Control']='no-store',['X-TxBridge-Idempotent-Replay']='true'}); res.send(json.encode(cached.response)) end
                        return
                    end
                end
                B.dispatch(req.method,path,query,body,client,finish)
            end)
        end
        if req.setCancelHandler then req.setCancelHandler(function() canceled=true end) end
        if req.method=='GET' then
            B.check(not headers['transfer-encoding'] and (not length or tonumber(length)==0),400,'get_body_not_allowed','GET body not allowed.')
            process('')
        else
            B.check(pendingBodies<Config.Http.maxPendingBodies,503,'body_capacity','Too many pending request bodies.')
            pendingBodies=pendingBodies+1; receiving=true
            SetTimeout(Config.Http.bodyTimeoutMs,function()
                if receiving and not completed then finish(408,{code='body_timeout',message='Request body timeout.'}) end
            end)
            req.setDataHandler(function(raw)
                if receiving then pendingBodies=math.max(0,pendingBodies-1); receiving=false end
                process(raw)
            end)
        end
    end)
end
