-- Factorio Autonomo-Bot Mod
-- control.lua
-- Final version using a basic "dumb walk" for movement, a pattern validated by other AI mods.

local actions = {}

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

-- Event Registrations
script.on_init(setup_mod)
script.on_load(setup_mod)
