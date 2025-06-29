-- Factorio Autonomo-Bot Mod
-- control.lua

-- Event registration
script.on_init(function()
  -- Initialize any global data structures for the mod here if needed
  -- For example, ensure the remote interface is set up
  if not remote.interfaces["factorio_autonomo_bot"] then
    remote.add_interface("factorio_autonomo_bot", {
      get_player_info = function() return get_player_info_impl() end
      -- Add more functions here as the agent's capabilities expand
    })
  end
  game.print("Factorio Autonomo-Bot Mod Initialized. Ready for RCON commands.")
end)

script.on_load(function()
  -- This is called when loading a save game that already has the mod.
  -- Ensure the remote interface is available.
  if not remote.interfaces["factorio_autonomo_bot"] then
    remote.add_interface("factorio_autonomo_bot", {
      get_player_info = function() return get_player_info_impl() end
    })
  end
  game.print("Factorio Autonomo-Bot Mod Loaded with save game.")
end)

-- Function to be called via RCON
-- It's good practice to wrap the actual implementation in a local function
-- and expose it via remote.call through an interface.
function get_player_info_impl()
  local player = game.players[1] -- Assuming single player or first player control

  if not player then
    return serpent.block({error = "Player not found"}) -- Using serpent for robust serialization
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

  local player_data = {
    position = {x = position.x, y = position.y},
    inventory = inventory_contents,
    health = player.character and player.character.health or nil, -- Example of adding more data
    tick = game.tick -- Current game tick
  }

  -- Factorio's game.print for RCON usually expects a string.
  -- JSON is a good format for structured data.
  -- We need a robust JSON encoder. Factorio doesn't have one built-in for all data types.
  -- Using serpent.block for reliable serialization to a Lua table string,
  -- which can then be processed by Python.
  -- For direct JSON, one might need to include a Lua JSON library with the mod.
  -- However, game.print output via RCON might have limitations on complex JSON strings.
  -- A simpler approach for now is to use serpent, and Python can parse this Lua table string.
  -- Or, we can manually construct a JSON string, being careful with escaping.

  -- Let's try manual JSON construction for simplicity with RCON limitations in mind.
  local json_parts = {}
  table.insert(json_parts, "{")

  -- Position
  table.insert(json_parts, "\"position\":{\"x\":" .. tostring(position.x) .. ",\"y\":" .. tostring(position.y) .. "},")

  -- Inventory
  table.insert(json_parts, "\"inventory\":{")
  local inv_parts = {}
  for name, count in pairs(inventory_contents) do
    table.insert(inv_parts, "\"" .. name .. "\":" .. tostring(count))
  end
  table.insert(json_parts, table.concat(inv_parts, ","))
  table.insert(json_parts, "},")

  -- Health
  if player.character and player.character.health then
    table.insert(json_parts, "\"health\":" .. tostring(player.character.health) .. ",")
  else
    table.insert(json_parts, "\"health\":null,")
  end

  -- Tick
  table.insert(json_parts, "\"tick\":" .. tostring(game.tick))

  -- Close main object
  table.insert(json_parts, "}")

  return table.concat(json_parts, "")
end

-- Example of how to directly register a command (less flexible than interface)
-- commands.add_command("get_player_info_cmd", "Gets player info", function(cmd)
--   local player_data_json = get_player_info_impl()
--   game.print(player_data_json) -- Print to RCON console
-- end)

-- The remote.call interface is generally better for structured interaction.
-- The Python agent will use:
-- /sc remote.call("factorio_autonomo_bot", "get_player_info")
-- The output will appear in the server log, which RCON can capture.
-- game.print() can also be used if the RCON client captures general server console output.
-- For commands that return data directly to RCON, `game.write_file` is often used with a temporary file,
-- and then RCON is used to read that file. This is more robust for large data.
-- However, for simplicity, we'll start with printing to console, assuming the RCON client can get it.
-- The `mcrcon` library typically gets the last line of output after a command.
-- So, the Lua function should just `return` the string, and `remote.call` will make `game.print` it.

-- A note on JSON encoding in Lua for Factorio:
-- Factorio's Lua environment is sandboxed and doesn't have a built-in `json` library
-- like `cjson` that standard Lua might.
-- For complex data, developers often bundle a lightweight Lua JSON encoder with their mod.
-- The manual construction above is for simple cases.
-- If issues arise, we might need to add a JSON library to the mod.
-- For now, the manual construction should work for the specified data.

-- To ensure the RCON command output is clean, the result of remote.call will be printed.
-- The Python client will need to parse this printed string.
-- e.g. server output: `"[REMOTE] factorio_autonomo_bot.get_player_info: {"position":{"x":10,"y":20},"inventory":{"iron-plate":100}}"`
-- The RCON client needs to grab the part after the colon.
-- A more direct way if the RCON client supports it is if `game.print` output from the command itself is captured.
-- If we use `commands.add_command` and then call `/get_player_info_cmd` via RCON, `game.print` within that function
-- will be the direct output.
-- Let's adjust to use `game.print` within the RCON-called function for direct output.

-- Re-defining the interface to ensure it calls a function that uses game.print for RCON.
if remote.interfaces["factorio_autonomo_bot"] and remote.interfaces["factorio_autonomo_bot"]["get_player_info"] then
  -- already added
else
  remote.add_interface("factorio_autonomo_bot", {
    get_player_info = function()
      local result_json = get_player_info_impl()
      -- game.print will make this available to RCON client that executes remote.call
      -- The remote.call itself will print the *return value* of this function.
      return result_json
    end
  })
end

-- For testing via in-game console: /c remote.call("factorio_autonomo_bot", "get_player_info")
-- Then check server console/log for the JSON output.
-- Or, for a command that prints directly:
commands.add_command("fab_get_player_info", "Prints player info as JSON for Autonomo-Bot.", function()
    local player_data_json = get_player_info_impl()
    game.print(player_data_json) -- This print goes to the server log/console
end)

-- The Python agent will use:
-- `/silent-command remote.call("factorio_autonomo_bot", "get_player_info")`
-- The result of `get_player_info_impl` will be returned and printed to the RCON console by `remote.call`.
-- Or, the agent can call `/fab_get_player_info` and `mcrcon` will capture the output from `game.print`.
-- Let's assume the agent will use the `remote.call` via `/silent-command` or `/sc`.
-- The `silent-command` ensures it doesn't also go to game chat.
-- The output format from remote.call is usually:
-- `[LUA] return value: "{\"position\": ...}"`
-- The Python side will need to parse this.
-- If we use `/fab_get_player_info`, the output is just the JSON string. This is simpler to parse.
-- Let's stick to the plan of using `remote.call` for now, as it's a common pattern for mod interaction.
-- The Python client will send `/sc remote.call("factorio_autonomo_bot", "get_player_info")`
-- and parse the output.
-- The `get_player_info_impl` function returns the JSON string.
-- The `remote.call` mechanism will print this string to the RCON console.
-- Example: `SCRIPT remote.call output: ("{\"position\":{\"x\":0.5,\"y\":-1.5},\"inventory\":{},\"health\":100,\"tick\":0}")`
-- The python client will need to extract the JSON from this.
-- A slightly cleaner way for RCON output:
-- If `game.rcon_print` is available (Factorio 1.1+), it's designed for this.
-- `game.rcon_print(get_player_info_impl())`
-- Let's use that if available, falling back to game.print.

-- Revised function for remote call
function get_player_info_for_rcon()
  local data_string = get_player_info_impl()
  if game.rcon_print then
    game.rcon_print(data_string)
  else
    game.print(data_string)
  end
  -- This function doesn't need to return anything if it prints directly.
  -- However, the remote.add_interface expects a function that can be called.
  -- Let's have get_player_info_impl return the string,
  -- and the interface function will print it.
end

-- Re-setup interface for clarity
remote.add_interface("factorio_autonomo_bot", {
  get_player_info = function()
    local result_json = get_player_info_impl()
    -- This ensures the result is printed to RCON when called via remote.call
    -- The remote.call itself will print the *return value* of this function.
    return result_json
  end
  -- Adding a direct print version for easier RCON parsing if needed
  -- Call with: /sc remote.call("factorio_autonomo_bot", "print_player_info")
  print_player_info = function()
    local result_json = get_player_info_impl()
    if game.rcon_print then
      game.rcon_print(result_json)
    else
      game.print(result_json)
    end
    -- No return value needed here as it prints directly
  end
})

-- The agent should call: `/silent-command game.print(remote.call('factorio_autonomo_bot', 'get_player_info'))`
-- This will make Factorio execute the remote call, get the JSON string, and then print that string to the console.
-- The mcrcon client should capture this printed JSON string.
-- The `get_player_info_impl` function correctly returns the JSON string.
-- The `remote.add_interface` part correctly registers `get_player_info` to point to `get_player_info_impl`.
-- So, `remote.call('factorio_autonomo_bot', 'get_player_info')` will execute `get_player_info_impl` and return its string.
-- `game.print(...)` will then print that returned string. This is a good approach.
