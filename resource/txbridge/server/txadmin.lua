local B=TxBridge
local function sameParams(a,b)
    if not B.object(a) or not B.object(b) or B.count(a)~=B.count(b) then return false end
    for k,v in pairs(a) do if v~=b[k] then return false end end
    return true
end
local function txBase()
    local url=Config.TxAdmin.baseUrl:gsub('/+$','')
    B.check(B.httpsUrl(url,true),503,'txadmin_configuration','txAdmin URL must be HTTPS or explicit loopback HTTP.')
    return url
end
function B.txCatalog()
    local items=B.array()
    for id,route in pairs(B.txRoutes) do
        local enabled=false
        for _,rule in ipairs(Config.TxAdmin.rules) do if rule.route==id then enabled=true end end
        items[#items+1]={id=id,method=route.method,path=route.path,authentication=route.auth,
            exposure=route.exposure,configured=enabled,experimental=true}
    end
    table.sort(items,function(a,b) return a.id<b.id end)
    return {auditedRevision=B.revision,routes=items,internalContractStable=false}
end
local function upstreamResult(status,raw,err,done)
    if err then done(status,{code=err,message='Upstream request failed. Do not blindly repeat writes.',outcomeUnknown=true}); return end
    if status<200 or status>=300 then done(502,{code='upstream_http_error',upstreamStatus=status,message='txAdmin rejected the request.'}); return end
    local ok,data=pcall(json.decode,raw or '')
    if ok and type(data)=='table' then
        if data.logout or data.error or data.type=='error' or data.success==false then
            -- An HTTP 200 from txAdmin may still be an authentication / application failure.
            done(502,{code=data.logout and 'txadmin_session_expired' or 'txadmin_application_error',
                upstreamStatus=status,upstream=data,message='txAdmin reported an error; a write may have partially completed.'})
        else done(200,{upstreamStatus=status,upstream=data,contract='txadmin-internal-unstable'}) end
    else
        -- Rendered pages and logs are returned as inert text inside JSON, never as executable HTML.
        done(200,{upstreamStatus=status,text=raw or '',contract='txadmin-internal-unstable',interpretation='unverified_text'})
    end
end
function B.txHost(client,done)
    B.scope(client,'txadmin:host')
    B.check(Config.TxAdmin.hostStatusEnabled,403,'disabled','Host status integration is disabled.')
    local token=B.secret(Config.TxAdmin.hostTokenConvar)
    B.check(token~=nil,503,'txadmin_configuration','Configure a private TXHOST_API_TOKEN and matching bridge token.')
    B.httpRequest(txBase()..'/host/status','GET','',{['x-txadmin-envtoken']=token},10000,
        Config.TxAdmin.maxResponseBytes,function(status,raw,err) upstreamResult(status,raw,err,done) end)
end
function B.txRequest(client,input,done)
    B.check(Config.TxAdmin.experimental,403,'disabled','Internal txAdmin adapter is disabled.')
    B.check(Config.TxAdmin.acknowledgedRevision==B.revision,503,'revision_not_acknowledged','Review your txAdmin version and acknowledge the audited revision.')
    local routeId=input.route
    B.check(type(routeId)=='string',400,'invalid_route','Specify a catalog route ID.')
    local route=B.txRoutes[routeId]
    B.check(route~=nil,404,'unknown_route','Unknown txAdmin route ID.')
    B.check(route.exposure=='experimental',403,'blocked_route','Authentication, intercom, host and development routes cannot use this adapter.')
    B.scope(client,'txadmin:'..routeId)
    local params=input.params or {}
    B.check(B.object(params),400,'invalid_params','params must be an object.')
    local permitted=false
    for _,rule in ipairs(Config.TxAdmin.rules) do
        if rule.route==routeId and sameParams(rule.params or {},params) then permitted=true; break end
    end
    B.check(permitted,403,'route_not_allowlisted','Route and exact path parameters must match a configured rule.')
    local expected={}
    local path=route.path:gsub(':([%w_]+)',function(name)
        expected[name]=true
        local value=params[name]
        B.check(type(value)=='string' and #value>=1 and #value<=64 and value:match('^[%w_-]+$'),400,'invalid_params','Invalid path parameter.')
        return value
    end)
    for key in pairs(params) do B.check(expected[key],400,'invalid_params','Unexpected path parameter.') end
    local query=input.query or {}
    B.check(B.object(query) and B.count(query)<=20,400,'invalid_query','query must be a small object of scalar values.')
    local keys={}; for k in pairs(query) do keys[#keys+1]=k end; table.sort(keys)
    local encoded={}
    for _,k in ipairs(keys) do
        local v=query[k]
        B.check(k:match('^[%w_%-%[%]]+$') and #k<=64,400,'invalid_query','Invalid query key.')
        B.check(type(v)=='string' or type(v)=='number' or type(v)=='boolean',400,'invalid_query','Query values must be scalar.')
        B.check(#tostring(v)<=2048,400,'invalid_query','Query value too long.')
        encoded[#encoded+1]=B.urlEncode(k)..'='..B.urlEncode(v)
    end
    if #encoded>0 then path=path..'?'..table.concat(encoded,'&') end
    B.check(#path<=4096,400,'invalid_query','Upstream request target too long.')
    local cookie=GetConvar(Config.TxAdmin.cookieConvar,'')
    local csrf=GetConvar(Config.TxAdmin.csrfConvar,'')
    B.check(#cookie>0 and #cookie<=8192 and not cookie:find('[%c]') and #csrf>0 and #csrf<=256 and not csrf:find('[%c]'),
        503,'txadmin_configuration','Configure an authorized limited-admin web session and CSRF token.')
    B.check(route.method~='GET' or input.body==nil,400,'get_body_not_allowed','GET upstream routes do not accept a body.')
    local body=route.method=='GET' and '' or json.encode(input.body or {})
    B.httpRequest(txBase()..path,route.method,body,{
        ['Cookie']=cookie,['x-txadmin-csrftoken']=csrf,['Content-Type']='application/json',
    },10000,Config.TxAdmin.maxResponseBytes,function(status,raw,err) upstreamResult(status,raw,err,done) end)
end
