local B=TxBridge
assert(type(Config.ServerId)=='string' and #Config.ServerId>=1 and #Config.ServerId<=64 and Config.ServerId:match('^[%w_-]+$'),'Invalid txBridge ServerId')
assert(Config.Events.retention>=1 and Config.Events.retention<=1000,'Invalid event retention')
assert(Config.Events.snapshotIntervalSeconds>=10,'Snapshot interval must be at least 10 seconds')
assert(Config.Delivery.maxAttempts>=1 and Config.Delivery.maxAttempts<=20,'Invalid delivery retry limit')
for id,client in pairs(Config.Clients) do
    assert(id:match('^[%w_-]+$') and #id<=64 and type(client.secretConvar)=='string','Invalid client configuration')
end
for id,cfg in pairs(Config.Webhooks) do
    assert(id:match('^[%w_-]+$') and #id<=64,'Invalid webhook ID')
    local url=GetConvar(cfg.urlConvar,'')
    if url~='' then assert(B.httpsUrl(url,false) and B.secret(cfg.secretConvar),'Webhook requires HTTPS and a strong secret') end
end
SetHttpHandler(B.httpHandler)
exports('GetStatus',function() return B.copy(B.status()) end)
exports('GetCapabilities',function() return B.copy(B.capabilities()) end)
exports('GetPlayers',function() return B.copy(B.players()) end)
exports('PublishEvent',function(name,data)
    local caller=GetInvokingResource()
    if not caller or not Config.Events.allowedPublishers[caller] then return nil,'publisher_not_allowed' end
    if type(name)~='string' or #name>100 or not name:match('^[%a][%w_.-]*$') then return nil,'invalid_event_name' end
    if type(data)~='table' then return nil,'object_required' end
    return B.publish('custom.'..name,data,'resource:'..caller)
end)
RegisterCommand('txbridge_status',function(source)
    if source~=0 then return end
    print(('[txBridge] server=%s version=%s events=%d queued=%d deadLetters=%d dropped=%d'):format(
        Config.ServerId,B.version,B.journal.sequence,#B.journal.outbox,#B.journal.deadLetters,B.journal.dropped))
end,true)
CreateThread(function()
    while true do
        Wait(500)
        local ok=pcall(B.pump)
        if not ok then B.fault='delivery_or_storage_error' end
    end
end)
CreateThread(function()
    while true do
        Wait(Config.Events.snapshotIntervalSeconds*1000)
        local ok=pcall(function() B.publish('bridge.status',B.status()) end)
        if not ok then B.fault='snapshot_or_storage_error' end
    end
end)
B.publish('bridge.started',{version=B.version,boot=B.boot.counter})
B.publish('bridge.status',B.status())
print(('[txBridge] %s initialized for %s; API peers are allowlisted; write actions are opt-in.'):format(B.version,Config.ServerId))
