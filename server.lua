-- Server-side script for Pickle Wheel gear synchronization
-- Handles multiplayer gear state synchronization

RegisterNetEvent('pickle-gearbox:server:setGear', function(vehicleNetworkId, gear)
    local networkEntity = NetworkGetEntityFromNetworkId(vehicleNetworkId)
    Entity(networkEntity).state.gearchange = gear
end)
