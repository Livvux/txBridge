fx_version 'cerulean'
game 'gta5'
server_only 'yes'

author 'txBridge contributors'
description 'Authenticated FiveM / txAdmin event and application bridge'
version '0.1.0'

server_scripts {
    'config.lua',
    'server/crypto.lua',
    'server/core.lua',
    'server/security.lua',
    'server/catalog.lua',
    'server/transport.lua',
    'server/events.lua',
    'server/txadmin.lua',
    'server/api.lua',
    'server/main.lua'
}
