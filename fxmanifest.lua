fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'Pickle Wheel Enhanced'
description 'Enhanced Pickle Wheel with advanced manual transmission system'
version '2.0.0'

ui_page 'nui/index.html'

files {
    'nui/index.html',
    'nui/assets/**/*.*'
}

client_scripts {
    'client.lua'
}

server_scripts {
    'server.lua'
}

shared_scripts {
    '@ox_lib/init.lua'
}

dependencies {
    'ox_lib'
}
