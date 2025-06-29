-- Factorio Autonomo-Bot Mod
-- control.lua

-- Utility function for simple JSON construction (manual)
local function to_json_string(data_table)
    if type(data_table) ~= "table" then
        if type(data_table) == "string" then
            return "\"" .. string.gsub(data_table, "\"", "\\\"") .. "\""
        elseif type(data_table) == "boolean" then
            return tostring(data_table)
        else -- numbers, nil
            return tostring(data_table)
        end
    end

    local parts = {}
    local is_array = true
    local max_idx = 0
    for k, _ in pairs(data_table) do
        if type(k) ~= "number" or k < 1 or k > #data_table + 1000 then -- Heuristic for array detection
            is_array = false
        end
        if type(k) == "number" and k > max_idx then
            max_idx = k
        end
    end
    if max_idx > 0 and #data_table ~= max_idx then -- sparse array is not a JSON array
        is_array = false
    end


    if is_array then
        table.insert(parts, "[")
        for i = 1, #data_table do
            table.insert(parts, to_json_string(data_table[i]))
            if i < #data_table then
                table.insert(parts, ",")
            end
        end
        table.insert(parts, "]")
    else -- object
        table.insert(parts, "{")
        local first = true
        for k, v in pairs(data_table) do
            if not first then
                table.insert(parts, ",")
            end
            table.insert(parts, "\"" .. tostring(k) .. "\":" .. to_json_string(v))
            first = false
        end
        table.insert(parts, "}")
    end
    return table.concat(parts, "")
end


-- Initialize global data structures
local function initialize_global_data()
  if global.player_movement_data == nil then
    global.player_movement_data = {
      path = nil,
      current_waypoint_index = 0,
      destination_reached = true, -- Initially not moving
      target_x = 0,
      target_y = 0
    }
  end
end

-- Core implementation for getting player info
local function get_player_info_impl()
  local player = game.players[1]
  if not player then
    return to_json_string({error = "Player not found"})
  end

  local position = player.position
  local inventory = player.get_main_inventory()
  local inventory_contents = {}

  if inventory then
    for i = 1, #inventory do
      local item_stack = inventory[i]
      if item_stack and item_stack.valid and item_stack.count > 0 then
        inventory_contents[item_stack.name] = (inventory_contents[item_stack.name] or 0) + item_stack.count
      end
    end
  end

  return to_json_string({
    position = {x = string.format("%.2f", position.x), y = string.format("%.2f", position.y)},
    inventory = inventory_contents,
    health = player.character and string.format("%.1f", player.character.health) or nil,
    tick = game.tick
  })
end

-- RCON function to start pathfinding
-- Expects params from remote.call to be a table: {x = target_x, y = target_y}
local function start_pathfinding_to_impl(params)
  local player = game.players[1]
  if not (player and player.character) then
    return to_json_string({status = "Pathfinding failed", path_found = false, error = "Player or character not found"})
  end
  if not (params and params.x and params.y) then
    return to_json_string({status = "Pathfinding failed", path_found = false, error = "Target coordinates (x, y) not provided"})
  end

  local target_pos = {x = tonumber(params.x), y = tonumber(params.y)}
  local path_params = {
    surface = player.surface,
    start = player.position,
    goal = target_pos,
    force = player.force, -- Or game.forces.player for default
    bounding_box = player.character.bounding_box,
    collidable = true, -- Default
    path_resolution_modifier = 0, -- Default for character, higher for vehicles
    -- algorithm = "a*", -- default is A*
    -- collateral_damage_cost = 1000, -- example
    can_open_gates = true
  }

  local path = player.surface.find_path(path_params)

  if path and #path > 0 then
    global.player_movement_data = {
      path = path,
      current_waypoint_index = 1,
      destination_reached = false,
      target_x = target_pos.x,
      target_y = target_pos.y
    }
    -- game.print("Path found. Waypoints: " .. #path) -- For debugging
    return to_json_string({status = "Pathfinding initiated", path_found = true, waypoints = #path, target = target_pos})
  else
    global.player_movement_data.destination_reached = true -- Ensure not stuck in moving state
    global.player_movement_data.path = nil
    -- game.print("Path not found to X:" .. target_pos.x .. " Y:" .. target_pos.y) -- For debugging
    return to_json_string({status = "Pathfinding failed", path_found = false, target = target_pos, error = "No path found"})
  end
end

-- RCON function to get movement status
local function get_movement_status_impl()
  local player = game.players[1]
  local current_pos_str = {}
  if player and player.character then
    current_pos_str = {x = string.format("%.2f", player.position.x), y = string.format("%.2f", player.position.y)}
  else
    current_pos_str = {x = "N/A", y = "N/A"}
  end

  local pmd = global.player_movement_data
  return to_json_string({
    is_moving = (pmd.path ~= nil and not pmd.destination_reached),
    destination_reached = pmd.destination_reached,
    target_position = (pmd.path and {x = pmd.target_x, y = pmd.target_y}) or nil,
    current_waypoint = (pmd.path and pmd.current_waypoint_index) or 0,
    total_waypoints = (pmd.path and #pmd.path) or 0,
    current_position = current_pos_str
  })
end

-- RCON function to scan nearby entities
local function scan_nearby_entities_impl(params)
  local player = game.players[1]
  if not (player and player.character) then
    return to_json_string({error = "Player or character not found for scanning."})
  end
  if not (params and params.radius) then
    return to_json_string({error = "Radius not provided for scanning."})
  end

  local radius = tonumber(params.radius)
  if not (radius and radius > 0) then
    return to_json_string({error = "Invalid radius provided: " .. tostring(params.radius)})
  end

  local area_to_scan = {
    {player.position.x - radius, player.position.y - radius},
    {player.position.x + radius, player.position.y + radius}
  }

  -- Define the resource types we are interested in.
  -- Note: "tree" is a common name, but Factorio uses specific names like "tree-01", "tree-02", etc.
  -- or generally entities with type "tree". We'll filter by prototype names first.
  -- For Factorio 2.0, "simple-entity" with a resource category might be more general for some resources.
  -- Let's list common resource entity names.
  local resource_entity_names = {
    "iron-ore", "copper-ore", "stone", "coal",
    "tree" -- This will act as a general category for trees, find_entities_filtered can take type="tree"
    -- Crude oil needs "crude-oil" (which is a resource entity)
  }

  local found_entities_data = {}
  local surface = player.surface

  -- Scan for specific resource names
  for _, name_filter in ipairs(resource_entity_names) do
    local entities_found
    if name_filter == "tree" then
      entities_found = surface.find_entities_filtered{area=area_to_scan, type="tree"}
    else
      entities_found = surface.find_entities_filtered{area=area_to_scan, name=name_filter, type="resource"}
    end

    for _, entity in pairs(entities_found) do
      if entity.valid then -- Make sure entity still exists
        table.insert(found_entities_data, {
          name = entity.name,
          position = {x = string.format("%.2f", entity.position.x), y = string.format("%.2f", entity.position.y)},
          unit_number = entity.unit_number -- This is the unique ID
        })
      end
    end
  end

  return to_json_string({entities = found_entities_data})
end


-- RCON function to get all unlocked recipes for the player's force
local function get_all_unlocked_recipes_impl()
  local player = game.players[1]
  if not player then
    return to_json_string({error = "Player not found for recipe lookup."})
  end

  local force = player.force
  if not (force and force.recipes) then
    return to_json_string({error = "Player force or recipes not available."})
  end

  local unlocked_recipes_data = {}

  for recipe_name, recipe_prototype in pairs(force.recipes) do
    if recipe_prototype.enabled then -- 'enabled' is the correct field for unlocked/available recipes
      local recipe_data = {
        name = recipe_prototype.name,
        ingredients = {},
        products = {}
      }

      -- Process ingredients
      -- recipe.ingredients can be in two formats:
      -- 1. {type="item", name="iron-plate", amount=2}
      -- 2. {{"iron-plate", 2}, {"copper-plate", 1}} (older style, or for fluid ingredients sometimes)
      -- Factorio 2.0 typically uses the table-per-ingredient format.
      for _, ingredient in ipairs(recipe_prototype.ingredients) do
        table.insert(recipe_data.ingredients, {
          name = ingredient.name,
          amount = ingredient.amount,
          type = ingredient.type or "item" -- Default to item if not specified
        })
      end

      -- Process products
      for _, product in ipairs(recipe_prototype.products) do
        table.insert(recipe_data.products, {
          name = product.name,
          amount = product.amount,
          type = product.type or "item" -- Default to item if not specified
        })
      end
      table.insert(unlocked_recipes_data, recipe_data)
    end
  end

  return to_json_string({recipes = unlocked_recipes_data})
end


-- on_tick handler for movement
local function handle_player_movement_on_tick()
  local player = game.players[1]
  local pmd = global.player_movement_data

  if not (player and player.character and pmd and pmd.path and not pmd.destination_reached) then
    if player and player.character and player.character.walking_state.walking and not (pmd and pmd.path and not pmd.destination_reached) then
        -- If we are walking but shouldn't be (e.g. path cleared externally)
        player.character.walking_state = {walking = false}
    end
    return
  end

  local current_waypoint = pmd.path[pmd.current_waypoint_index]
  if not current_waypoint then
    -- game.print("Movement: Invalid waypoint index " .. pmd.current_waypoint_index) -- Debug
    pmd.destination_reached = true
    pmd.path = nil
    player.character.walking_state = {walking = false}
    return
  end

  local dx = current_waypoint.x - player.position.x
  local dy = current_waypoint.y - player.position.y
  local distance_to_waypoint = math.sqrt(dx*dx + dy*dy)

  -- Threshold for reaching a waypoint (e.g., 0.5 tiles)
  -- Factorio path waypoints can be quite close.
  local reach_threshold = 0.3

  if distance_to_waypoint < reach_threshold then
    pmd.current_waypoint_index = pmd.current_waypoint_index + 1
    if pmd.current_waypoint_index > #pmd.path then
      -- game.print("Movement: Destination reached at X:" .. string.format("%.2f", player.position.x) .. " Y:" .. string.format("%.2f", player.position.y)) -- Debug
      pmd.destination_reached = true
      pmd.path = nil
      player.character.walking_state = {walking = false}
    else
      -- Move to next waypoint, update walking_state if necessary
      local next_waypoint = pmd.path[pmd.current_waypoint_index]
      if next_waypoint then
         player.character.walking_state = {target = next_waypoint, arrive_distance = reach_threshold/2} -- Use target for smoother movement
      else -- Should not happen if path is valid
        pmd.destination_reached = true; pmd.path = nil; player.character.walking_state = {walking=false}
      end
    end
  else
    -- Continue moving towards the current waypoint
    -- Ensure walking_state is set, find_path command might not persist it across ticks if interrupted
    if not player.character.walking_state.walking or
       (player.character.walking_state.target and
        (player.character.walking_state.target.x ~= current_waypoint.x or player.character.walking_state.target.y ~= current_waypoint.y)) then
        player.character.walking_state = {target = current_waypoint, arrive_distance = reach_threshold/2}
    end
  end
end


-- Event registration
local function on_init_handler()
  initialize_global_data()

  if not remote.interfaces["factorio_autonomo_bot"] then
    remote.add_interface("factorio_autonomo_bot", {})
  end

  remote.add_interface("factorio_autonomo_bot", {
    get_player_info = function() return get_player_info_impl() end,
    start_pathfinding_to = function(params) return start_pathfinding_to_impl(params) end,
    get_movement_status = function() return get_movement_status_impl() end,
    scan_nearby_entities = function(params) return scan_nearby_entities_impl(params) end,
    get_all_unlocked_recipes = function() return get_all_unlocked_recipes_impl() end
  })

  game.print("Factorio Autonomo-Bot Mod Initialized. Interface 'factorio_autonomo_bot' is ready with movement, scanning, and recipe lookup.")
end

local function on_load_handler()
  initialize_global_data() -- Ensure data structure exists on load

  if not remote.interfaces["factorio_autonomo_bot"] then
    remote.add_interface("factorio_autonomo_bot", {})
  end

  -- Ensure all functions are registered on load as well
  remote.add_interface("factorio_autonomo_bot", {
    get_player_info = function() return get_player_info_impl() end,
    start_pathfinding_to = function(params) return start_pathfinding_to_impl(params) end,
    get_movement_status = function() return get_movement_status_impl() end,
    scan_nearby_entities = function(params) return scan_nearby_entities_impl(params) end,
    get_all_unlocked_recipes = function() return get_all_unlocked_recipes_impl() end
  })
  -- game.print("Factorio Autonomo-Bot Mod Loaded with save game. Movement, scanning, and recipes ready.")
end

script.on_init(on_init_handler)
script.on_load(on_load_handler)
script.on_event(defines.events.on_tick, handle_player_movement_on_tick)

-- Python agent RCON commands:
-- For get_player_info:
--   /sc game.print(remote.call("factorio_autonomo_bot", "get_player_info"))
-- For start_pathfinding_to (example with x=10, y=20):
--   /sc game.print(remote.call("factorio_autonomo_bot", "start_pathfinding_to", {x=10, y=20}))
-- For get_movement_status:
--   /sc game.print(remote.call("factorio_autonomo_bot", "get_movement_status"))
-- For scan_nearby_entities (example with radius 32):
--   /sc game.print(remote.call("factorio_autonomo_bot", "scan_nearby_entities", {radius=32}))
-- For get_all_unlocked_recipes:
--   /sc game.print(remote.call("factorio_autonomo_bot", "get_all_unlocked_recipes"))

-- Testing in Factorio console:
-- /c global.player_movement_data = nil; initialize_global_data() -- Reset state
-- /c game.print(remote.call("factorio_autonomo_bot", "start_pathfinding_to", {x = game.player.position.x + 10, y = game.player.position.y + 5}))
-- /c game.print(remote.call("factorio_autonomo_bot", "get_movement_status"))
-- /c game.print(remote.call("factorio_autonomo_bot", "scan_nearby_entities", {radius=16}))
-- /c game.print(remote.call("factorio_autonomo_bot", "get_all_unlocked_recipes"))
-- Observe player movement and status updates.
