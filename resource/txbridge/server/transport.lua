local B=TxBridge
local active={}
function B.httpRequest(url,method,body,headers,timeout,maxResponse,done)
    if B.metrics.outstanding>=Config.Delivery.maxOutstandingRequests then
        done(503,nil,'http_capacity'); return
    end
    B.metrics.outstanding=B.metrics.outstanding+1
    local completed=false; local nativeFinished=false
    local function finish(code,data,err)
        if completed then return end
        completed=true; done(code,data,err)
    end
    SetTimeout(timeout,function()
        if completed then return end
        B.metrics.httpTimeouts=B.metrics.httpTimeouts+1
        -- Native request cannot be canceled here. Keep it counted until its callback fires.
        finish(504,nil,'timeout_outcome_unknown')
    end)
    local ok=pcall(PerformHttpRequest,url,function(status,data)
        if nativeFinished then return end
        nativeFinished=true
        B.metrics.outstanding=math.max(0,B.metrics.outstanding-1)
        if type(data)=='string' and #data>maxResponse then finish(502,nil,'upstream_too_large'); return end
        finish(tonumber(status) or 0,data,nil)
    end,method,body or '',headers or {},{followLocation=false})
    if not ok then
        if not nativeFinished then B.metrics.outstanding=math.max(0,B.metrics.outstanding-1); nativeFinished=true end
        finish(502,nil,'http_error')
    end
end
function B.webhookCanonical(serverId,eventId,timestamp,body)
    return table.concat({'TXBRIDGE-WEBHOOK1',serverId,eventId,timestamp,B.crypto.sha256(body)},'\n')
end
local function removeDelivery(id)
    for i,item in ipairs(B.journal.outbox) do if item.id==id then table.remove(B.journal.outbox,i); return item end end
end
function B.deadLetter(item,reason)
    removeDelivery(item.id)
    item.lastError=reason; item.failedAt=os.time()
    B.journal.deadLetters[#B.journal.deadLetters+1]=item
    while #B.journal.deadLetters>Config.Delivery.maxDeadLetters do
        table.remove(B.journal.deadLetters,1); B.journal.dropped=B.journal.dropped+1
    end
    B.metrics.failed=B.metrics.failed+1
    B.save('journal',B.journal)
end
function B.enqueue(event)
    local body=json.encode(event)
    for endpoint,cfg in pairs(Config.Webhooks) do
        local url=GetConvar(cfg.urlConvar,'')
        if url~='' and (cfg.events['*'] or cfg.events[event.type]) then
            if #B.journal.outbox>=Config.Delivery.maxQueue then
                B.journal.dropped=B.journal.dropped+1; B.metrics.queueOverflow=B.metrics.queueOverflow+1
            else
                B.journal.outbox[#B.journal.outbox+1]={
                    id=event.id..'--'..endpoint,eventId=event.id,endpoint=endpoint,
                    type=event.type,body=body,createdAt=os.time(),nextAt=os.time(),attempts=0,
                }
            end
        end
    end
end
function B.pump()
    local now=os.time()
    -- One in-flight delivery per destination; delivery order is best-effort, not guaranteed.
    local candidates={}
    for _,item in ipairs(B.journal.outbox) do candidates[#candidates+1]=item end
    for _,item in ipairs(candidates) do
        if not active[item.endpoint] and item.nextAt<=now then
            if now-item.createdAt>Config.Delivery.maxAgeSeconds then B.deadLetter(item,'expired')
            else
                local cfg=Config.Webhooks[item.endpoint]
                local url=cfg and GetConvar(cfg.urlConvar,'') or ''
                local secret=cfg and B.secret(cfg.secretConvar)
                if not cfg or not B.httpsUrl(url,false) or not secret then
                    B.deadLetter(item,'invalid_endpoint_configuration')
                elseif B.metrics.outstanding<Config.Delivery.maxOutstandingRequests then
                    active[item.endpoint]=item.id
                    item.attempts=item.attempts+1
                    -- Checkpoint before sending. A crash may cause a duplicate, never an exactly-once claim.
                    item.nextAt=now+math.min(300,2^item.attempts)
                    B.save('journal',B.journal)
                    local stamp=tostring(now)
                    local headers={
                        ['Content-Type']='application/json',
                        ['X-TxBridge-Server']=Config.ServerId,
                        ['X-TxBridge-Event']=item.eventId,
                        ['X-TxBridge-Timestamp']=stamp,
                        ['X-TxBridge-Signature']=B.crypto.hmac(secret,B.webhookCanonical(Config.ServerId,item.eventId,stamp,item.body)),
                    }
                    B.httpRequest(url,'POST',item.body,headers,Config.Delivery.timeoutMs,16384,function(status,_,err)
                        active[item.endpoint]=nil
                        if not err and status>=200 and status<300 then
                            removeDelivery(item.id); B.metrics.delivered=B.metrics.delivered+1
                            B.save('journal',B.journal)
                        else
                            local permanent=status>=400 and status<500 and status~=408 and status~=429
                            if permanent or item.attempts>=Config.Delivery.maxAttempts then
                                B.deadLetter(item,err or ('http_'..status))
                            else
                                item.lastError=err or ('http_'..status)
                                item.nextAt=os.time()+math.min(300,2^item.attempts)+math.random(0,3)
                                B.save('journal',B.journal)
                            end
                        end
                    end)
                end
            end
        end
    end
end
function B.deliveryStatus()
    local endpoints=B.array()
    for id,cfg in pairs(Config.Webhooks) do
        endpoints[#endpoints+1]={id=id,configured=GetConvar(cfg.urlConvar,'')~='',active=active[id]~=nil}
    end
    return {endpoints=endpoints,pending=#B.journal.outbox,deadLetters=#B.journal.deadLetters,dropped=B.journal.dropped}
end
function B.retryDelivery(id)
    B.check(#B.journal.outbox<Config.Delivery.maxQueue,503,'queue_full','Delivery queue full.')
    for i,item in ipairs(B.journal.deadLetters) do
        if item.id==id then
            table.remove(B.journal.deadLetters,i)
            item.attempts=0; item.nextAt=os.time(); item.createdAt=os.time(); item.lastError=nil; item.failedAt=nil
            B.journal.outbox[#B.journal.outbox+1]=item; B.save('journal',B.journal)
            return {deliveryId=id,queued=true}
        end
    end
    B.fail(404,'not_found','Dead letter not found.')
end
