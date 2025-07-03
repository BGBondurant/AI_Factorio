local PathfindingModule = {}

-- Define Pathfinding Vehicle States
local PF_VEHICLE_STATES = {
    IDLE = "IDLE",
    REQUESTING_PATH = "REQUESTING_PATH",
    PATH_RECEIVED = "PATH_RECEIVED", -- Path is available, ready for movement logic
    PATH_FAILED = "PATH_FAILED",     -- Path request was unsuccessful
    FOLLOWING_PATH = "FOLLOWING_PATH"
}

-- Forward declarations for functions that might call each other or be called by handlers
local set_vehicle_pf_state
local get_vehicle_entity -- Might be better in control.lua or passed as param
local request_vehicle_path_internal -- Renamed to avoid conflict if we expose a simpler one
local execute_next_movement_command
local get_vehicle_key_from_entity


-- Function to set and log vehicle pathfinding state
set_vehicle_pf_state = function(vehicle_key, new_state)
    if not global.pf_vehicles[vehicle_key] then
        game.print("PathfindingModule Error: Trying to set state for unknown vehicle_key: " .. vehicle_key)
        return
    end
    local old_state = global.pf_vehicles[vehicle_key].pf_state
    global.pf_vehicles[vehicle_key].pf_state = new_state
    if old_state ~= new_state then
        game.print("PathfindingModule: Vehicle " .. vehicle_key .. " (Name: " .. (global.pf_vehicles[vehicle_key].entity_name or "N/A") .. ") state changed from " .. (old_state or "nil") .. " to: " .. new_state)
    end
end

-- Utility to get a vehicle entity (can be player character or actual vehicle)
-- This will be called by the main request function in the module.
get_vehicle_entity = function(unit_number, player_index)
    if unit_number then
        for _, surface in pairs(game.surfaces) do
            local entity = surface.find_entity_by_unit_number(unit_number)
            if entity and entity.valid and (entity.type == "player" or entity.commandable) then
                return entity
            end
        end
        return nil, "PathfindingModule: Vehicle with unit number " .. unit_number .. " not found or not commandable."
    end
    local player = game.players[player_index or 1]
    if player and player.character and player.character.valid then
        return player.character, nil
    end
    return nil, "PathfindingModule: Player " .. (player_index or 1) .. " character not found."
end

-- Core path request function (internal)
request_vehicle_path_internal = function(vehicle_entity, target_pos)
    if not (vehicle_entity and vehicle_entity.valid) then
        game.print("PathfindingModule: Path request failed: Invalid vehicle entity.")
        return nil, "Invalid vehicle entity"
    end
    if not (target_pos and target_pos.x and target_pos.y) then
        game.print("PathfindingModule: Path request failed: Invalid target position.")
        return nil, "Invalid target position"
    end

    local surface = vehicle_entity.surface
    local request_params = {
        bounding_box = vehicle_entity.prototype.selection_box,
        collision_mask = vehicle_entity.prototype.collision_mask,
        start = vehicle_entity.position,
        goal = target_pos,
        force = vehicle_entity.force,
        radius = 1,
        pathfind_flags = { cache = true },
        can_open_gates = true,
        path_resolution_modifier = 0,
        entity_to_ignore = vehicle_entity
    }

    local request_id = surface.request_path(request_params)
    local vehicle_key

    if vehicle_entity.unit_number then
        vehicle_key = vehicle_entity.unit_number
    else
        vehicle_key = "player_" .. vehicle_entity.player.index
    end

    if request_id then
        global.pf_vehicles[vehicle_key] = global.pf_vehicles[vehicle_key] or {} -- Ensure it exists
        global.pf_vehicles[vehicle_key].active_request_id = request_id
        global.pf_vehicles[vehicle_key].entity_name = vehicle_entity.name
        global.pf_vehicles[vehicle_key].target_pos = target_pos

        global.pf_request_to_vehicle_map[request_id] = vehicle_key

        game.print("PathfindingModule: Path request initiated for " .. vehicle_entity.name .. " (Key: " .. vehicle_key .. ") to {" .. target_pos.x .. "," .. target_pos.y .. "}. Request ID: " .. request_id)
        return request_id, vehicle_key -- Return vehicle_key for state setting
    else
        game.print("PathfindingModule: Path request failed for " .. vehicle_entity.name .. " (Key: " .. vehicle_key .. ") to {" .. target_pos.x .. "," .. target_pos.y .. "}. surface.request_path returned nil.")
        if vehicle_key then -- vehicle_key might be nil if entity was invalid very early
             global.pf_vehicles[vehicle_key] = global.pf_vehicles[vehicle_key] or {}
             global.pf_vehicles[vehicle_key].entity_name = vehicle_entity.name -- ensure name is there for state setting
        end
        return nil, vehicle_key, "surface.request_path returned nil"
    end
end

get_vehicle_key_from_entity = function(entity)
    if not (entity and entity.valid) then return nil end
    if entity.unit_number then return entity.unit_number end
    if entity.type == "player" and entity.player and entity.player.valid then
        return "player_" .. entity.player.index
    end
    return nil
end

execute_next_movement_command = function(vehicle_key)
    local vehicle_data = global.pf_vehicles[vehicle_key]
    if not vehicle_data then
        game.print("PathfindingModule: Execute movement: No data for vehicle_key: " .. vehicle_key)
        return
    end

    local entity_unit_number
    local entity_player_index
    if type(vehicle_key) == "string" and string.sub(vehicle_key, 1, 7) == "player_" then
        entity_player_index = tonumber(string.sub(vehicle_key, 8))
    else
        entity_unit_number = vehicle_key
    end
    local vehicle_entity, err_msg_get_entity = get_vehicle_entity(entity_unit_number, entity_player_index)

    if not (vehicle_entity and vehicle_entity.valid and vehicle_entity.commandable) then
        game.print("PathfindingModule: Vehicle " .. vehicle_key .. " (Name: " .. (vehicle_data.entity_name or "N/A") .. "): Entity not found, invalid, or not commandable for movement. Error: " .. (err_msg_get_entity or "N/A"))
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.PATH_FAILED)
        vehicle_data.current_path = nil
        vehicle_data.current_waypoint_index = nil
        return
    end

    if not (vehicle_data.current_path and vehicle_data.current_waypoint_index) then
        game.print("PathfindingModule: Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. "): Cannot execute movement. Missing path or waypoint index.")
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE)
        return
    end

    if vehicle_data.current_waypoint_index > #vehicle_data.current_path then
        game.print("PathfindingModule: Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") has completed all waypoints.")
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE)
        vehicle_data.current_path = nil
        vehicle_data.current_waypoint_index = nil
        return
    end

    local destination = vehicle_data.current_path[vehicle_data.current_waypoint_index]
    if not destination then
        game.print("PathfindingModule: Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. "): Invalid destination at waypoint index " .. vehicle_data.current_waypoint_index)
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.PATH_FAILED)
        vehicle_data.current_path = nil
        vehicle_data.current_waypoint_index = nil
        return
    end

    local command = {type = defines.command.go_to_location, destination = destination, follow_path = true}
    vehicle_entity.commandable.set_command(command)
    set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.FOLLOWING_PATH)
    game.print("PathfindingModule: Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") moving to waypoint " .. vehicle_data.current_waypoint_index .. "/" .. #vehicle_data.current_path .. " at {" .. string.format("%.2f", destination.x) .. ", " .. string.format("%.2f", destination.y) .. "}")
end

-------------------------------------------------------------------------------------
-- Event Handlers to be exposed by the module
-------------------------------------------------------------------------------------

PathfindingModule.on_script_path_request_finished = function(event)
    local request_id = event.id
    local vehicle_key = global.pf_request_to_vehicle_map[request_id]

    if not vehicle_key then return end

    local vehicle_data = global.pf_vehicles[vehicle_key]
    if not vehicle_data or vehicle_data.active_request_id ~= request_id then
        game.print("PathfindingModule: Path request finished for vehicle key " .. vehicle_key .. ", but ID mismatch or no active request. Event ID: " .. request_id .. ", Stored ID: " .. (vehicle_data and vehicle_data.active_request_id or "nil"))
        return
    end

    game.print("PathfindingModule: Path request finished for vehicle key: " .. vehicle_key .. " (Name: " .. (vehicle_data.entity_name or "N/A") .. ")")
    if event.success then
        game.print("PathfindingModule: Path found successfully! Number of waypoints: " .. #event.path)
        -- Using game.print with to_json_string (if available in control.lua and passed) or simple print
        if #event.path < 10 and #event.path > 0 then
             game.print("PathfindingModule: Path waypoints (first few): " .. table_to_json_string_for_logging(event.path))
        elseif #event.path == 0 then
            game.print("PathfindingModule: Path found, but it has zero waypoints.")
        else
            game.print("PathfindingModule: Path is too long to print all waypoints here (" .. #event.path .. " waypoints).")
        end
        vehicle_data.current_path = event.path
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.PATH_RECEIVED)
    else
        game.print("PathfindingModule: Pathfinding failed for vehicle key: " .. vehicle_key)
        vehicle_data.current_path = nil
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.PATH_FAILED)
    end

    vehicle_data.active_request_id = nil
    global.pf_request_to_vehicle_map[request_id] = nil

    if vehicle_data.pf_state == PF_VEHICLE_STATES.PATH_RECEIVED and vehicle_data.current_path and #vehicle_data.current_path > 0 then
        vehicle_data.current_waypoint_index = 1
        execute_next_movement_command(vehicle_key)
    elseif vehicle_data.pf_state == PF_VEHICLE_STATES.PATH_RECEIVED and vehicle_data.current_path and #vehicle_data.current_path == 0 then
        game.print("PathfindingModule: Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") received an empty path. Nav complete.")
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE)
    end
end

PathfindingModule.on_ai_command_completed = function(event)
    if not (event and event.entity and event.entity.valid) then return end

    local vehicle_entity = event.entity
    local vehicle_key = get_vehicle_key_from_entity(vehicle_entity)

    if not vehicle_key then return end

    local vehicle_data = global.pf_vehicles[vehicle_key]
    if not (vehicle_data and vehicle_data.pf_state == PF_VEHICLE_STATES.FOLLOWING_PATH) then
        return
    end

    game.print("PathfindingModule: Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") AI command completed to waypoint " .. (vehicle_data.current_waypoint_index or "?") .. ". Result: " .. event.result)

    if vehicle_data.current_waypoint_index then
        vehicle_data.current_waypoint_index = vehicle_data.current_waypoint_index + 1
        execute_next_movement_command(vehicle_key)
    else
        game.print("PathfindingModule: Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") completed a command but current_waypoint_index was nil. Setting to IDLE.")
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE)
    end
end


-------------------------------------------------------------------------------------
-- Public API for the Pathfinding Module
-------------------------------------------------------------------------------------

-- Initializes global storage needed by the pathfinding module
PathfindingModule.initialize_globals = function()
    global.pf_vehicles = global.pf_vehicles or {}
    global.pf_request_to_vehicle_map = global.pf_request_to_vehicle_map or {}
    game.print("PathfindingModule: Globals initialized.")
end

-- Main function to be called from control.lua to request a path
-- vehicle_entity is the actual LuaEntity
PathfindingModule.request_path_for_entity = function(vehicle_entity, target_pos)
    if not (vehicle_entity and vehicle_entity.valid) then
        return {status = "error", message = "PathfindingModule: Invalid vehicle entity provided."}
    end

    local vehicle_key
    if vehicle_entity.unit_number then
        vehicle_key = vehicle_entity.unit_number
    else
        vehicle_key = "player_" .. vehicle_entity.player.index
    end

    if not global.pf_vehicles[vehicle_key] then
        global.pf_vehicles[vehicle_key] = {}
        global.pf_vehicles[vehicle_key].entity_name = vehicle_entity.name
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE)
    else
        global.pf_vehicles[vehicle_key].entity_name = vehicle_entity.name
    end

    -- If already busy, what to do? For now, new request overrides.
    if global.pf_vehicles[vehicle_key].active_request_id or global.pf_vehicles[vehicle_key].pf_state == PF_VEHICLE_STATES.FOLLOWING_PATH then
        game.print("PathfindingModule: Vehicle " .. vehicle_key .. " is already processing a path or moving. New request will override. (Future: queue or reject)")
        -- Simplistic: just stop current movement if any, clear old path.
        if vehicle_entity.commandable and vehicle_entity.commandable.valid then
            vehicle_entity.commandable.set_command({type=defines.command.stop, ticks_to_wait=0})
        end
        global.pf_vehicles[vehicle_key].current_path = nil
        global.pf_vehicles[vehicle_key].current_waypoint_index = nil
        -- active_request_id will be overwritten by new request_vehicle_path_internal call
    end

    local request_id, returned_vk, err_msg = request_vehicle_path_internal(vehicle_entity, target_pos)

    if request_id then
        set_vehicle_pf_state(returned_vk or vehicle_key, PF_VEHICLE_STATES.REQUESTING_PATH)
        return {status = "path_requested", vehicle_key = returned_vk or vehicle_key, request_id = request_id, entity_name = vehicle_entity.name, state = global.pf_vehicles[returned_vk or vehicle_key].pf_state}
    else
        set_vehicle_pf_state(returned_vk or vehicle_key, PF_VEHICLE_STATES.PATH_FAILED)
        return {status = "error", message = "PathfindingModule: Failed to initiate path request: " .. (err_msg or "Unknown error"), state = global.pf_vehicles[returned_vk or vehicle_key].pf_state}
    end
end

-- Placeholder for a to_json_string if control.lua doesn't provide one to the module.
-- Factorio's game.table_to_json is a good default for simple logging.
local function table_to_json_string_for_logging(tbl)
    if game.table_to_json then
        return game.table_to_json(tbl)
    end
    return "(table data - game.table_to_json not available)"
end

-- Update the reference in on_script_path_request_finished
-- from वैश्विक.to_json_string_placeholder to table_to_json_string_for_logging
-- This change will be done by finding that line and replacing it.
-- Searching for: game.print("PathfindingModule: Path waypoints (first few): " .. वैश्विक.to_json_string_placeholder(event.path))
-- Replacing with: game.print("PathfindingModule: Path waypoints (first few): " .. table_to_json_string_for_logging(event.path))
-- The diff tool will handle this specific line change. I'll construct the diff for that.

return PathfindingModule
