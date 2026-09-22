local B=TxBridge
B.security=B.read('security',{nonces={},idempotency={}})
local buckets={}
function B.peer(address)
    if type(address)~='string' then return '' end
    local ip=address:match('^%[([^%]]+)%]:%d+$') or address:match('^(%d+%.%d+%.%d+%.%d+):%d+$') or address
    return (ip:gsub('^::ffff:',''))
end
function B.rate(key)
    local now=os.time()
    local bucket=buckets[key]
    if not bucket then
        if B.count(buckets)>=Config.Http.maxRateBuckets then
            for k,v in pairs(buckets) do if now-v.at>120 then buckets[k]=nil end end
            if B.count(buckets)>=Config.Http.maxRateBuckets then return false end
        end
        bucket={at=now,tokens=Config.Http.burst}; buckets[key]=bucket
    end
    bucket.tokens=math.min(Config.Http.burst,bucket.tokens+math.max(0,now-bucket.at)*Config.Http.requestsPerMinute/60)
    bucket.at=now
    if bucket.tokens<1 then return false end
    bucket.tokens=bucket.tokens-1; return true
end
function B.headers(input)
    local out={}
    for k,v in pairs(input or {}) do
        B.check(type(k)=='string' and type(v)=='string',400,'invalid_headers','Invalid headers.')
        local name=k:lower()
        B.check(out[name]==nil,400,'duplicate_header','Duplicate header.')
        out[name]=v
    end
    return out
end
function B.canonical(key,method,path,timestamp,nonce,idem,body)
    return table.concat({'TXBRIDGE1',Config.ServerId,key,method,path,timestamp,nonce,idem or '',B.crypto.sha256(body or '')},'\n')
end
function B.pruneSecurity()
    local now=os.time()
    for k,v in pairs(B.security.nonces) do if v<now then B.security.nonces[k]=nil end end
    for k,v in pairs(B.security.idempotency) do if v.expires<now then B.security.idempotency[k]=nil end end
end
function B.authenticate(method,path,headers,body)
    local key=headers['x-txbridge-key']
    local stamp=headers['x-txbridge-timestamp'] or ''
    local nonce=headers['x-txbridge-nonce'] or ''
    local sig=headers['x-txbridge-signature'] or ''
    local idem=headers['idempotency-key'] or ''
    B.check(type(key)=='string' and #key<=64 and key:match('^[%w_-]+$'),401,'unauthorized','Authentication failed.')
    local client=Config.Clients[key]
    local secret=client and B.secret(client.secretConvar)
    B.check(secret~=nil,401,'unauthorized','Authentication failed.')
    B.check(stamp:match('^%d+$') and #stamp==10 and math.abs(os.time()-tonumber(stamp))<=Config.Http.clockSkewSeconds,
        401,'expired_signature','Request timestamp outside the permitted window.')
    B.check(#nonce>=24 and #nonce<=128 and nonce:match('^[%w_-]+$'),401,'unauthorized','Invalid nonce.')
    B.check(#sig==64 and sig:match('^[0-9a-f]+$'),401,'unauthorized','Authentication failed.')
    B.check(#idem<=128 and (idem=='' or (#idem>=16 and idem:match('^[%w_-]+$'))),400,'invalid_idempotency_key','Use a 16–128 character idempotency key.')
    local expected=B.crypto.hmac(secret,B.canonical(key,method,path,stamp,nonce,idem,body))
    B.check(B.crypto.equal(expected,sig),401,'unauthorized','Authentication failed.')
    B.pruneSecurity()
    local nonceKey=key..':'..nonce
    B.check(not B.security.nonces[nonceKey],409,'replayed_request','Nonce already used. Re-sign retries with a fresh nonce.')
    B.check(B.count(B.security.nonces)<Config.Http.maxReplayEntries,503,'replay_capacity','Replay store full; try later.')
    -- A future-dated signature must remain blocked until timestamp + skew, not arrival + skew.
    B.security.nonces[nonceKey]=tonumber(stamp)+Config.Http.clockSkewSeconds
    B.save('security',B.security)
    B.check(B.rate('key:'..key),429,'rate_limited','Too many requests.')
    return {id=key,scopes=client.scopes or {},idem=idem}
end
function B.scope(client,scope)
    B.check(client.scopes[scope]==true,403,'forbidden','Required scope: '..scope)
end
function B.beginIdempotency(client,method,path,body)
    B.check(client.idem~='',400,'idempotency_required','POST requires Idempotency-Key.')
    local key=client.id..':'..client.idem
    local fingerprint=B.crypto.sha256(method..'\n'..path..'\n'..body)
    local old=B.security.idempotency[key]
    if old then
        B.check(old.fingerprint==fingerprint,409,'idempotency_conflict','This key was used for a different request.')
        B.check(old.state=='complete',409,'outcome_unknown','Request pending or outcome unknown; reconcile before retrying.')
        B.check(old.response~=nil,409,'response_not_retained','Already executed; response exceeded retention limit.')
        return nil,old
    end
    B.check(B.count(B.security.idempotency)<Config.Http.maxIdempotencyEntries,503,'idempotency_capacity','Idempotency store full.')
    B.security.idempotency[key]={fingerprint=fingerprint,state='pending',expires=os.time()+Config.Http.idempotencySeconds}
    B.save('security',B.security)
    return key
end
function B.finishIdempotency(key,status,response)
    if not key then return end
    local item=B.security.idempotency[key]
    if not item then return end
    item.state='complete'; item.status=status
    if #json.encode(response)<=16384 then item.response=response end
    B.save('security',B.security)
end
