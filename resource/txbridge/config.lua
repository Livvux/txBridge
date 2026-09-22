-- This file is SERVER ONLY. Use `set`, NEVER `sets` / `setr`, for secrets.
-- Generate each secret independently: openssl rand -hex 32
Config = {
    ServerId = GetConvar('txbridge_server_id', 'main'),
    Http = {
        enabled = true,
        -- Actual socket peers, not X-Forwarded-For. Add your PRIVATE proxy IP if needed.
        allowedPeers = { ['127.0.0.1'] = true, ['::1'] = true },
        maxBodyBytes = 32768,
        bodyTimeoutMs = 5000,
        maxPendingBodies = 16,
        requestsPerMinute = 120,
        burst = 30,
        maxRateBuckets = 256,
        clockSkewSeconds = 90,
        maxReplayEntries = 2048,
        idempotencySeconds = 86400,
        maxIdempotencyEntries = 512,
    },
    Clients = {
        wordpress = {
            secretConvar = 'txbridge_wordpress_secret',
            scopes = {
                ['status:read'] = true,
                ['players:read'] = true,
                ['resources:read'] = true,
                ['events:read'] = true,
                -- ['audit:read'] = true,
                -- ['webhooks:read'] = true,
                -- ['webhooks:write'] = true,
                -- ['players:identifiers'] = true,
                -- ['actions:kick'] = true,
                -- ['actions:message'] = true,
                -- ['actions:announce'] = true,
                -- ['actions:resource'] = true,
                -- ['txadmin:host'] = true,
                -- ['txadmin:player_stats'] = true,
            },
        },
    },
    Privacy = {
        includePlayerNames = false,
        includeAdminNames = false,
        includeMessageText = false,
        includeCommandText = false,
        -- Normal API raw identifiers require the separate scoped player endpoint.
        -- Experimental txAdmin responses bypass this event/native privacy filter.
        exposeIdentifiers = false,
        allowedIdentifierTypes = { license = true, license2 = true, discord = true, fivem = true },
        pseudonymSecretConvar = 'txbridge_privacy_secret',
    },
    Actions = {
        kick = false,
        message = false,
        announce = false,
        resources = false,
        allowedResources = { -- ['my_optional_resource'] = true,
        },
        protectedResources = {
            monitor = true, txbridge = true, sessionmanager = true,
            hardcap = true, baseevents = true,
        },
    },
    Events = {
        retention = 200,
        auditRetention = 200,
        maxEventBytes = 8192,
        maxEventAgeSeconds = 7 * 86400,
        trustedResources = { monitor = true },
        -- Enable only for older txAdmin versions; modern aliases produce duplicate observations.
        captureDeprecated = false,
        snapshotIntervalSeconds = 30,
        allowedPublishers = { -- ['my_resource'] = true,
        },
    },
    Webhooks = {
        wordpress = {
            urlConvar = 'txbridge_webhook_url',
            secretConvar = 'txbridge_webhook_secret',
            events = { ['*'] = true },
        },
    },
    Delivery = {
        maxQueue = 500,
        maxDeadLetters = 100,
        maxAttempts = 8,
        maxAgeSeconds = 86400,
        timeoutMs = 10000,
        maxOutstandingRequests = 4,
    },
    TxAdmin = {
        -- Only an explicitly configured base, never a request-supplied URL.
        baseUrl = GetConvar('txbridge_txadmin_url', 'http://127.0.0.1:40120'),
        hostStatusEnabled = false,
        hostTokenConvar = 'txbridge_txadmin_host_token',
        experimental = false,
        -- Manual, authorized limited-admin WEB session. Never use the internal intercom token.
        cookieConvar = 'txbridge_txadmin_cookie',
        csrfConvar = 'txbridge_txadmin_csrf',
        -- Set this to the audited source commit only after checking your installed txAdmin.
        acknowledgedRevision = GetConvar('txbridge_txadmin_revision', ''),
        maxResponseBytes = 262144,
        rules = {
            -- Each grant binds BOTH a route and exact path parameters.
            -- { route = 'player_stats', params = {} },
            -- { route = 'whitelist_list', params = { table = 'requests' } },
        },
    },
}
