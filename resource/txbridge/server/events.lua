local B=TxBridge
-- Exact fields documented by txAdmin at B.revision. Unknown new fields are not exported silently.
B.eventSchemas={
    announcement={'author','message'},
    serverShuttingDown={'delay','author','message'},
    scheduledRestart={'secondsRemaining','translatedMessage'},
    scheduledRestartSkipped={'secondsRemaining','temporary','author'},
    playerBanned={'author','reason','actionId','expiration','durationInput','durationTranslated','targetNetId','targetIds','targetHwids','targetName','kickMessage'},
    playerDirectMessage={'target','author','message'},
    playerHealed={'target','author'},
    playerKicked={'target','author','reason','dropMessage'},
    playerWarned={'author','reason','actionId','targetNetId','targetIds','targetName'},
    whitelistPlayer={'action','license','playerName','adminName'},
    whitelistPreApproval={'action','identifier','playerName','adminName'},
    whitelistRequest={'action','playerName','requestId','license','adminName'},
    actionRevoked={'actionId','actionType','actionReason','actionAuthor','playerName','playerIds','playerHwids','revokedBy'},
    adminAuth={'netid','isAdmin','username'},
    adminsUpdated='array',
    configChanged='empty',
    consoleCommand={'author','channel','command'},
}
B.deprecatedEvents={playerWhitelisted=true,healedPlayer=true,skippedNextScheduledRestart=true}
function B.publish(eventType,data,origin)
    B.check(type(eventType)=='string' and #eventType<=128,400,'invalid_event','Invalid event name.')
    local safe=B.sanitize(data or {})
    if #json.encode(safe)>Config.Events.maxEventBytes then
        safe={truncated=true,reason='event_size_limit'}
    end
    B.journal.sequence=B.journal.sequence+1
    local event={version=1,id=Config.ServerId..'-'..B.journal.sequence,sequence=B.journal.sequence,
        serverId=Config.ServerId,type=eventType,origin=origin or 'bridge',emittedAt=os.time(),data=safe}
    local events=B.journal.events
    events[#events+1]=event
    while #events>Config.Events.retention or (#events>0 and events[1].emittedAt<os.time()-Config.Events.maxEventAgeSeconds) do
        table.remove(events,1)
    end
    B.enqueue(event)
    B.save('journal',B.journal)
    return event.id
end
function B.capture(name,data)
    if (tonumber(source) or 0)>0 then return false end
    local invoker=GetInvokingResource()
    if invoker and not Config.Events.trustedResources[invoker] then return false end
    local schema=B.eventSchemas[name]
    local selected={}
    if schema=='array' then
        selected=B.array(); if type(data)=='table' then for i,v in ipairs(data) do if i>2048 then break end; if type(v)=='number' then selected[#selected+1]=v end end end
    elseif schema=='empty' then selected={}
    elseif type(schema)=='table' then
        if type(data)~='table' then return false end
        for _,field in ipairs(schema) do selected[field]=data[field] end
    elseif Config.Events.captureDeprecated and B.deprecatedEvents[name] then selected=data or {}
    else return false end
    B.observed.lastEvent={name=name,at=os.time()}
    if name=='scheduledRestart' and type(data.secondsRemaining)=='number' then
        B.observed.nextRestart={expectedAt=os.time()+data.secondsRemaining,observedAt=os.time()}
    elseif name=='scheduledRestartSkipped' or name=='serverShuttingDown' then B.observed.nextRestart=false
    elseif name=='adminAuth' then
        local id=tonumber(data.netid)
        if id==-1 then B.observed.admins={}
        elseif id and id>=1 then B.observed.admins[tostring(id)]=data.isAdmin==true or nil end
    elseif name=='adminsUpdated' then B.observed.admins={} end
    B.publish('txadmin.'..name,selected,'txadmin_event')
    return true
end
for name in pairs(B.eventSchemas) do
    AddEventHandler('txAdmin:events:'..name,function(data) B.capture(name,data) end)
end
if Config.Events.captureDeprecated then
    for name in pairs(B.deprecatedEvents) do
        AddEventHandler('txAdmin:events:'..name,function(data) B.capture(name,data) end)
    end
end
AddEventHandler('playerJoining',function()
    local id=tostring(source); B.sessions[id]=nil
    B.publish('fivem.playerJoined',{id=tonumber(id),sessionId=B.session(id)},'fivem_event')
end)
AddEventHandler('playerDropped',function(reason)
    local id=tostring(source)
    B.publish('fivem.playerDropped',{id=tonumber(id),sessionId=B.sessions[id],reason=reason},'fivem_event')
    B.sessions[id]=nil; B.observed.admins[id]=nil
end)
AddEventHandler('onResourceStart',function(name)
    if name~=B.resource then B.publish('fivem.resourceStarted',{resource=name},'fivem_event') end
end)
AddEventHandler('onResourceStop',function(name)
    B.publish('fivem.resourceStopped',{resource=name},'fivem_event')
end)
