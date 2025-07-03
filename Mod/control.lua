-- Factorio Autonomo-Bot Mod
-- control.lua
-- Refactored to use pathfinding.lua module.

local actions = {}
local Pathfinding = require("pathfinding")

-- Utility function for simple JSON construction
local function to_json_string(data_table)
    if type(data_table) ~= "table" then
        if type(data_table) == "string" then return "\"" .. string.gsub(data_table, "\"", "\\\"") .. "\""
        elseif type(data_table) == "boolean" then return tostring(data_table)
        else return tostring(data_table) end
    end
    local parts = {}
    local is_array = true; local max_idx = 0
    for k, _ in pairs(data_table) do
        if type(k) ~= "number" or k < 1 or k > #data_table + 1000 then is_array = false end
        if type(k) == "number" and k > max_idx then max_idx = k end
    end
    if max_idx > 0 and #data_table ~= max_idx then is_array = false end
    if is_array then
        table.insert(parts, "[")
        for i = 1, #data_table do
            table.insert(parts, to_json_string(data_table[i]))
            if i < #data_table then table.insert(parts, ",") end
        end
        table.insert(parts, "]")
    else
        table.insert(parts, "{")
        local first = true
        for k, v in pairs(data_table) do
            if not first then table.insert(parts, ",") end
            table.insert(parts, "\"" .. tostring(k) .. "\":" .. to_json_string(v))
            first = false
        end
        table.insert(parts, "}")
    end
    return table.concat(parts, "")
end

-- RCON function implementations
function actions.get_player_info()
  local player = game.players[1]
  if not player then return to_json_string({error = "Player not found"}) end
  return to_json_string({
    position = {x = string.format("%.2f", player.position.x), y = string.format("%.2f", player.position.y)},
    inventory = (function()
        local c = {}
        if player.get_main_inventory() then
            for i=1, #player.get_main_inventory() do
                local stack = player.get_main_inventory()[i]
                if stack.valid and stack.count > 0 then c[stack.name] = (c[stack.name] or 0) + stack.count end
            end
        end
        return c
    end)(),
    health = player.character and string.format("%.1f", player.character.health) or nil,
    tick = game.tick
  })
end

-- This uses the basic "dumb walk" by directly setting the character's walking target.
-- It has NO obstacle avoidance.
-- DOES NOT WORK AS OF NOW
-- TODO: FIX PATHFINDING
function actions.move_to_position(params)
  local player = game.players[1]
  if not (player and player.character) then return to_json_string({status = "error", message = "Player or character not found"}) end
  if not (params and params.x and params.y) then return to_json_string({status = "error", message = "Target coordinates not provided"}) end

  local target_pos = {x = tonumber(params.x), y = tonumber(params.y)}
  
  -- DEBUG 1: Print the walking_state BEFORE we touch it.
  game.print("--- BEFORE ---")
  game.print("walking_state: " .. to_json_string(player.character.walking_state))

  -- Attempt to modify the properties
  player.character.walking_state.target = target_pos
  player.character.walking_state.walking = true

  -- DEBUG 2: Print the walking_state AFTER we touch it.
  game.print("--- AFTER ---")
  game.print("walking_state: " .. to_json_string(player.character.walking_state))

  return to_json_string({status = "movement_initiated"})
end

-- This is simplified to just check the character's walking state.
function actions.get_movement_status()
  local player = game.players[1]
  if not (player and player.character) then return to_json_string({is_moving = false}) end

  local is_moving = player.character.walking_state.walking
  return to_json_string({is_moving = is_moving})
end

function actions.scan_nearby_entities(params)
  local player = game.players[1]
  if not (player and player.character) then return to_json_string({error = "Player not found"}) end
  if not (params and params.radius) then return to_json_string({error = "Radius not provided"}) end
  local radius = tonumber(params.radius)
  if not (radius and radius > 0) then return to_json_string({error = "Invalid radius"}) end
  local area = {{player.position.x - radius, player.position.y - radius}, {player.position.x + radius, player.position.y + radius}}
  local resource_names = { "iron-ore", "copper-ore", "stone", "coal", "tree" }
  local found_entities = {}
  for _, name in ipairs(resource_names) do
    local entities_found
    if name == "tree" then entities_found = player.surface.find_entities_filtered{area=area, type="tree"} else entities_found = player.surface.find_entities_filtered{area=area, name=name, type="resource"} end
    for _, entity in pairs(entities_found) do
      if entity.valid then
        local data = { name = entity.name, position = {x = string.format("%.2f", entity.position.x), y = string.format("%.2f", entity.position.y)}, unit_number = entity.unit_number }
        if entity.type == "resource" and entity.amount then data.amount = entity.amount end
        table.insert(found_entities, data)
      end
    end
  end
  return to_json_string({entities = found_entities})
end

function actions.get_all_unlocked_recipes()
  local player = game.players[1]
  if not player then return to_json_string({error = "Player not found"}) end
  local force = player.force
  if not (force and force.recipes) then return to_json_string({error = "Player force or recipes not available."}) end
  local recipes = {}
  for _, recipe in pairs(force.recipes) do
    if recipe.enabled then
      local data = { name = recipe.name, ingredients = {}, products = {} }
      for _, ingredient in ipairs(recipe.ingredients) do table.insert(data.ingredients, { name = ingredient.name, amount = ingredient.amount, type = ingredient.type or "item" }) end
      for _, product in ipairs(recipe.products) do table.insert(data.products, { name = product.name, amount = product.amount, type = product.type or "item" }) end
      table.insert(recipes, data)
    end
  end
  return to_json_string({recipes = recipes})
end

function actions.mine_target_entity(params)
  local player = game.players[1]
  if not player or not player.character then return to_json_string({status = "error", message = "Player or character not found"}) end
  if not (params and params.unit_number) then return to_json_string({status = "error", message = "unit_number not provided"}) end
  local entities = player.surface.find_entities_filtered{position = player.position, radius = 10, unit_number = params.unit_number}
  if #entities == 0 then return to_json_string({status = "error", message = "Target entity not found", entity_id = params.unit_number}) end
  local target = entities[1]
  if not player.character.can_mine(target) then return to_json_string({status = "error", message = "Target not mineable", entity_id = params.unit_number, entity_name = target.name}) end
  player.character.mine(target)
  return to_json_string({ status = "mining_initiated", entity_id = params.unit_number, entity_name = target.name })
end

-- Setup function
local function setup_mod()
  remote.add_interface("factorio_autonomo_bot", actions)
end

-- Utility to get a vehicle entity (can be player character or actual vehicle)
-- This is kept in control.lua for actions.pf_set_destination to use before calling the module.
local function get_control_lua_vehicle_entity(unit_number, player_index)
    if unit_number then
        for _, surface in pairs(game.surfaces) do
            local entity = surface.find_entity_by_unit_number(unit_number)
            if entity and entity.valid and (entity.type == "player" or entity.commandable) then
                return entity
            end
        end
        return nil, "Control.lua: Vehicle with unit number " .. unit_number .. " not found or not commandable."
    end
    local player = game.players[player_index or 1]
    if player and player.character and player.character.valid then
        return player.character, nil
    end
    return nil, "Control.lua: Player " .. (player_index or 1) .. " character not found."
end


-- RCON action to set destination and trigger pathfinding
function actions.pf_set_destination(params)
    local player_index = params.player_index or 1
    local unit_number = params.unit_number
    local target_x = tonumber(params.x)
    local target_y = tonumber(params.y)

    if not (target_x and target_y) then
        return to_json_string({status = "error", message = "Target coordinates (x, y) not provided or invalid."})
    end

    local vehicle_entity, err_msg = get_vehicle_entity(unit_number, player_index)
    if not vehicle_entity then
        return to_json_string({status = "error", message = err_msg})
    end

    local vehicle_key
    if vehicle_entity.unit_number then
        vehicle_key = vehicle_entity.unit_number
    else
        vehicle_key = "player_" .. vehicle_entity.player.index
    end

    -- Ensure basic structure exists for this vehicle
    if not global.pf_vehicles[vehicle_key] then
        global.pf_vehicles[vehicle_key] = {}
        global.pf_vehicles[vehicle_key].entity_name = vehicle_entity.name
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE) -- Initialize to IDLE
    else
        -- If vehicle is already known, ensure its name is up-to-date
        global.pf_vehicles[vehicle_key].entity_name = vehicle_entity.name
    end

    local request_id, req_err_msg = request_vehicle_path(vehicle_entity, {x = target_x, y = target_y})
    if request_id then
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.REQUESTING_PATH)
        return to_json_string({status = "path_requested", vehicle_key = vehicle_key, request_id = request_id, entity_name = vehicle_entity.name, state = global.pf_vehicles[vehicle_key].pf_state})
    else
        -- If request_vehicle_path itself fails before sending, it's a path failure.
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.PATH_FAILED)
        return to_json_string({status = "error", message = "Failed to initiate path request: " .. (req_err_msg or "Unknown error"), state = global.pf_vehicles[vehicle_key].pf_state})
    end
end

-- Event handler for path request completion
local function on_script_path_request_finished_handler(event)
    local request_id = event.id
    local vehicle_key = global.pf_request_to_vehicle_map[request_id]

    if not vehicle_key then
        -- game.print("Path request finished for an unknown request ID: " .. request_id) -- Can be noisy
        return
    end

    local vehicle_data = global.pf_vehicles[vehicle_key]
    if not vehicle_data or vehicle_data.active_request_id ~= request_id then
        game.print("Path request finished for vehicle key " .. vehicle_key .. ", but ID mismatch or no active request. Event ID: " .. request_id .. ", Stored ID: " .. (vehicle_data and vehicle_data.active_request_id or "nil"))
        return
    end

    game.print("Path request finished for vehicle key: " .. vehicle_key .. " (Name: " .. (vehicle_data.entity_name or "N/A") .. ")")
    if event.success then
        game.print("Path found successfully! Number of waypoints: " .. #event.path)
        if #event.path < 10 and #event.path > 0 then
             game.print("Path waypoints: " .. to_json_string(event.path))
        elseif #event.path == 0 then
            game.print("Path found, but it has zero waypoints (start is likely at/near goal).")
        else
            game.print("Path is too long to print all waypoints here (" .. #event.path .. " waypoints).")
        end
        vehicle_data.current_path = event.path -- Store the path for later use
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.PATH_RECEIVED)
    else
        game.print("Pathfinding failed for vehicle key: " .. vehicle_key)
        vehicle_data.current_path = nil
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.PATH_FAILED)
    end

    vehicle_data.active_request_id = nil -- Clear the active request ID
    global.pf_request_to_vehicle_map[request_id] = nil -- Clean up map

    -- If path was received successfully, attempt to start movement
    if vehicle_data.pf_state == PF_VEHICLE_STATES.PATH_RECEIVED and vehicle_data.current_path and #vehicle_data.current_path > 0 then
        vehicle_data.current_waypoint_index = 1 -- Start with the first waypoint
        execute_next_movement_command(vehicle_key)
    elseif vehicle_data.pf_state == PF_VEHICLE_STATES.PATH_RECEIVED and vehicle_data.current_path and #vehicle_data.current_path == 0 then
        -- Path received but it's empty (e.g. start is goal), so consider it done.
        game.print("Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") received an empty path. Considering navigation complete.")
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE)
    end
end

local function get_vehicle_key_from_entity(entity)
    if not (entity and entity.valid) then return nil end
    if entity.unit_number then return entity.unit_number end
    -- For player character, entity.player exists
    if entity.type == "player" and entity.player and entity.player.valid then
        return "player_" .. entity.player.index
    end
    return nil
end

local function execute_next_movement_command(vehicle_key)
    local vehicle_data = global.pf_vehicles[vehicle_key]
    if not vehicle_data then
        game.print("Execute movement: No data for vehicle_key: " .. vehicle_key)
        return
    end

    -- Ensure entity is still valid and commandable before proceeding
    local entity_unit_number
    local entity_player_index
    if type(vehicle_key) == "string" and string.sub(vehicle_key, 1, 7) == "player_" then
        entity_player_index = tonumber(string.sub(vehicle_key, 8))
    else
        entity_unit_number = vehicle_key
    end
    local vehicle_entity, err_msg = get_vehicle_entity(entity_unit_number, entity_player_index)

    if not (vehicle_entity and vehicle_entity.valid and vehicle_entity.commandable) then
        game.print("Vehicle " .. vehicle_key .. " (Name: " .. (vehicle_data.entity_name or "N/A") .. "): Entity not found, invalid, or not commandable for movement. Error: " .. (err_msg or "N/A"))
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.PATH_FAILED)
        vehicle_data.current_path = nil
        vehicle_data.current_waypoint_index = nil
        return
    end

    if not (vehicle_data.current_path and vehicle_data.current_waypoint_index) then
        game.print("Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. "): Cannot execute movement. Missing path or waypoint index.")
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE)
        return
    end

    if vehicle_data.current_waypoint_index > #vehicle_data.current_path then
        game.print("Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") has completed all waypoints.")
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE)
        vehicle_data.current_path = nil
        vehicle_data.current_waypoint_index = nil
        return
    end

    local destination = vehicle_data.current_path[vehicle_data.current_waypoint_index]
    if not destination then
        game.print("Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. "): Invalid destination at waypoint index " .. vehicle_data.current_waypoint_index)
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.PATH_FAILED)
        vehicle_data.current_path = nil
        vehicle_data.current_waypoint_index = nil
        return
    end

    local command = {type = defines.command.go_to_location, destination = destination, follow_path = true}
    -- `follow_path = true` is used as per guide's initial suggestion for `set_command`.
    -- Refinements for stuttering (section 2.4) can be future work.

    vehicle_entity.commandable.set_command(command)
    set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.FOLLOWING_PATH)
    game.print("Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") moving to waypoint " .. vehicle_data.current_waypoint_index .. "/" .. #vehicle_data.current_path .. " at {" .. string.format("%.2f", destination.x) .. ", " .. string.format("%.2f", destination.y) .. "}")
end

local function on_ai_command_completed_handler(event)
    if not (event and event.entity and event.entity.valid) then return end

    local vehicle_entity = event.entity
    local vehicle_key = get_vehicle_key_from_entity(vehicle_entity)

    if not vehicle_key then
        -- Not an entity we are tracking by this keying scheme
        return
    end

    local vehicle_data = global.pf_vehicles[vehicle_key]
    if not (vehicle_data and vehicle_data.pf_state == PF_VEHICLE_STATES.FOLLOWING_PATH) then
        -- Not our vehicle or not in the correct state to process command completion
        return
    end

    -- TODO: As per guide, check event.result for more robust error handling (e.g. defines.command_result.fail)
    game.print("Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") AI command completed to waypoint " .. (vehicle_data.current_waypoint_index or "?") .. ". Result: " .. event.result)

    if vehicle_data.current_waypoint_index then -- Ensure it was set
        vehicle_data.current_waypoint_index = vehicle_data.current_waypoint_index + 1
        execute_next_movement_command(vehicle_key) -- Attempt to move to the next waypoint or finalize
    else
        game.print("Vehicle " .. vehicle_key .. " (Name: " .. vehicle_data.entity_name .. ") completed a command but current_waypoint_index was nil. Setting to IDLE.")
        set_vehicle_pf_state(vehicle_key, PF_VEHICLE_STATES.IDLE)
    end
end

-- Event Registrations
script.on_init(function()
    setup_mod()
    initialize_pf_globals()
end)
script.on_load(function()
    setup_mod()
    initialize_pf_globals()
end)

script.on_event(defines.events.on_script_path_request_finished, on_script_path_request_finished_handler)
script.on_event(defines.events.on_ai_command_completed, on_ai_command_completed_handler)
