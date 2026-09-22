local B = TxBridge
B.version = '0.1.0'
B.revision = '8a9a41410000fd92a527fe11bae2b8eeeb8b10e0'
B.resource = GetCurrentResourceName()
B.startedAt = os.time()
B.metrics = { delivered=0, failed=0, queueOverflow=0, httpTimeouts=0, outstanding=0 }
B.sessions = {}
B.observed = { complete=false, since=B.startedAt, admins={}, lastEvent=false, nextRestart=false }
B.fault = false
function B.array(t) return setmetatable(t or {}, {__jsontype='array'}) end
function B.copy(t) return json.decode(json.encode(t)) end
function B.object(t)
    if type(t)~='table' then return false end
    for k in pairs(t) do if type(k)~='string' then return false end end
    local mt=getmetatable(t); return not (mt and mt.__jsontype=='array')
end
function B.fail(status,code,message) error({status=status,code=code,message=message},0) end
function B.check(ok,status,code,message) if not ok then B.fail(status,code,message) end end
function B.count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
function B.read(key,default)
    local raw=GetResourceKvpString('txbridge:'..key)
    if not raw or raw=='' then return default end
    local ok,value=pcall(json.decode,raw)
    if not ok or type(value)~='table' then error('Corrupt txBridge storage: '..key..'; restore a backup before restarting.') end
    return value
end
function B.save(key,value)
    -- Native KVP storage is local durability, not a transactional database or an fsync guarantee.
    SetResourceKvp('txbridge:'..key,json.encode(value))
end
B.journal=B.read('journal',{sequence=0,events={},audit={},outbox={},deadLetters={},dropped=0})
B.boot=B.read('boot',{counter=0})
B.boot.counter=B.boot.counter+1
B.save('boot',B.boot)
B.sessionCounter=0
function B.session(id)
    id=tostring(id)
    if not GetPlayerName(id) then B.sessions[id]=nil; return nil end
    if not B.sessions[id] then
        B.sessionCounter=B.sessionCounter+1
        B.sessions[id]=Config.ServerId..'-'..B.boot.counter..'-'..B.sessionCounter
    end
    return B.sessions[id]
end
function B.secret(convar)
    local s=GetConvar(convar,'')
    if #s<32 or #s>256 or s:find('[%c]') or s:lower():find('change') or s:lower():find('replace') then return nil end
    return s
end
function B.pseudonym(value)
    local secret=B.secret(Config.Privacy.pseudonymSecretConvar)
    return secret and ('hmac:'..B.crypto.hmac(secret,tostring(value))) or '[redacted]'
end
local identifiers={license=true,identifier=true,targetIds=true,playerIds=true,identifiers=true}
local forbidden={targetHwids=true,playerHwids=true,hwids=true,tokens=true,ip=true,endpoint=true,password=true,secret=true,token=true,cookie=true}
local names={targetName=true,playerName=true,name=true}
local admins={author=true,adminName=true,actionAuthor=true,revokedBy=true,username=true}
local text={message=true,reason=true,actionReason=true,kickMessage=true,dropMessage=true,translatedMessage=true}
function B.sanitize(value,key,depth)
    depth=depth or 0
    if depth>8 then return '[depth-limit]' end
    if key and forbidden[key] then return '[redacted]' end
    if key and identifiers[key] then
        if type(value)=='table' then
            local out=B.array(); for i,v in ipairs(value) do if i>64 then break end; out[#out+1]=B.pseudonym(v) end; return out
        end
        return B.pseudonym(value)
    end
    if key and names[key] and not Config.Privacy.includePlayerNames then return '[redacted]' end
    if key and admins[key] and not Config.Privacy.includeAdminNames then return '[redacted]' end
    if key=='command' and not Config.Privacy.includeCommandText then return '[redacted]' end
    if key and text[key] and not Config.Privacy.includeMessageText then return '[redacted]' end
    if type(value)=='table' then
        local out= (#value>0) and B.array() or {}; local n=0
        for k,v in pairs(value) do
            n=n+1; if n>128 then break end
            if type(k)=='string' or type(k)=='number' then out[k]=B.sanitize(v,k,depth+1) end
        end
        return out
    elseif type(value)=='string' then return value:sub(1,2048)
    elseif type(value)=='number' then return value==value and math.abs(value)<1e16 and value or 0
    elseif type(value)=='boolean' then return value end
    return nil
end
function B.audit(client,action,status,details)
    local a=B.journal.audit
    a[#a+1]={at=os.time(),client=client or 'local',action=action,status=status,details=details}
    while #a>Config.Events.auditRetention do table.remove(a,1) end
    B.save('journal',B.journal)
end
function B.status()
    return {
        serverId=Config.ServerId, version=B.version, resource=B.resource,
        hostname=GetConvar('sv_hostname','FiveM server'),
        players=#GetPlayers(), maxPlayers=GetConvarInt('sv_maxclients',0),
        bridgeStartedAt=B.startedAt, bridgeUptimeSeconds=os.time()-B.startedAt,
        fxserverVersion=GetConvar('version','unknown'),
        monitorState=GetResourceState('monitor'),
        observedAt=os.time(), processState='running',
        eventSequence=B.journal.sequence,
        queue={pending=#B.journal.outbox, deadLetters=#B.journal.deadLetters, dropped=B.journal.dropped},
        fault=B.fault, metrics=B.copy(B.metrics),
    }
end
function B.players()
    local items=B.array()
    for _,id in ipairs(GetPlayers()) do
        local name=GetPlayerName(id)
        if name then items[#items+1]={id=tonumber(id),sessionId=B.session(id),
            name=Config.Privacy.includePlayerNames and name or '[redacted]',ping=GetPlayerPing(id)} end
    end
    table.sort(items,function(a,b) return a.id<b.id end)
    return items
end
function B.resources()
    local items=B.array()
    for i=0,GetNumResources()-1 do
        local name=GetResourceByFindIndex(i)
        if name then items[#items+1]={name=name,state=GetResourceState(name)} end
    end
    table.sort(items,function(a,b) return a.name<b.name end)
    return items
end
function B.httpsUrl(url,allowLoopback)
    if type(url)~='string' or #url>2048 or url:find('[%s%c@?#\\]') then return false end
    local scheme,authority,path=url:match('^(https?)://([^/]+)(.*)$')
    if not scheme or (path~='' and path:sub(1,1)~='/') then return false end
    if scheme=='http' then
        if not allowLoopback then return false end
        local port=authority:match('^127%.0%.0%.1:(%d+)$') or authority:match('^%[::1%]:(%d+)$')
        return port~=nil and tonumber(port)>=1 and tonumber(port)<=65535
    end
    local host,port=authority:match('^([%w%.%-]+):(%d+)$')
    if not host then host=authority; if not host:match('^[%w%.%-]+$') then return false end end
    if host:sub(1,1)=='-' or host:sub(-1)=='-' or host:find('..',1,true) then return false end
    if port and (tonumber(port)<1 or tonumber(port)>65535) then return false end
    return #host>0
end
function B.urlEncode(s)
    return (tostring(s):gsub('([^%w%-%._~])',function(c) return ('%%%02X'):format(c:byte()) end))
end
