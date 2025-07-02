import json
import re
import time
import os
from mcrcon import MCRcon
import google.generativeai as genai

class FactorioRCONClient:
    def __init__(self, host, port, password):
        self.host = host
        self.port = port
        self.password = password
        self.rcon = MCRcon(self.host, self.password, port=self.port)
        self._is_connected = False

    def connect(self):
        try:
            self.rcon.connect()
            self._is_connected = True
            print(f"Successfully connected to Factorio server at {self.host}:{self.port}")
        except Exception as e:
            self._is_connected = False
            print(f"Failed to connect to RCON: {e}")
            raise

    def disconnect(self):
        try:
            self.rcon.disconnect()
            self._is_connected = False
            print("Disconnected from RCON.")
        except Exception as e:
            print(f"Error during RCON disconnect: {e}")

    def _parse_json_from_response(self, raw_response):
        if not raw_response:
            print("Received empty response from RCON.")
            return None
        # Try to find JSON within the string, accommodating potential prefixes/suffixes from Factorio console
        # Matches {...} or [...]
        json_match = re.search(r'(\{.*\})|(\[.*\])', raw_response)
        if json_match:
            json_str = json_match.group(0)
            try:
                data = json.loads(json_str)
                return data
            except json.JSONDecodeError as e:
                print(f"Failed to decode JSON: {e}")
                print(f"Received string that failed parsing: '{json_str}'")
                print(f"Full raw response for context: '{raw_response}'")
                return None
        else:
            print(f"Could not find valid JSON in RCON response: '{raw_response}'")
            return None

    def _execute_command(self, command):
        if not self._is_connected:
            print("RCON not connected. Attempting to reconnect...")
            try:
                self.connect()
            except Exception as e:
                    raise ConnectionError(f"RCON reconnection failed: {e}")

        try:
            # print(f"Sending RCON command: {command}") # Verbose
            response = self.rcon.command(command)
            # print(f"Raw RCON response: {response}") # Verbose
            return response
        except Exception as e:
            print(f"Error executing RCON command '{command}': {e}")
            self._is_connected = False # Assume connection is lost on error
            # Attempt to determine if the connection was lost
            if "Broken pipe" in str(e) or "Connection reset" in str(e) or "Not connected" in str(e) or "Socket is not connected" in str(e):
                print("Connection lost. Will attempt to reconnect on next command.")
            raise

    def _execute_lua_call(self, function_name, params=None):
        """
        Helper to execute a remote.call to a Lua function in the mod.
        Ensures the call is wrapped with game.print for output and handles parameter formatting.
        """
        param_str = ""
        if params is not None:
            # Basic Lua table representation for simple dicts/lists
            # For more complex structures, a proper Lua serializer might be needed on Python side,
            # or pass as JSON string and have Lua parse it (if Lua has JSON lib).
            # Current Lua mod expects simple {x=number, y=number} table for start_pathfinding_to.
            if isinstance(params, dict):
                parts = []
                for k, v in params.items():
                    if isinstance(v, str):
                        parts.append(f'{k}="{v}"') # Basic string quoting
                    else:
                        parts.append(f'{k}={v}') # Numbers, booleans
                param_str = ", {" + ", ".join(parts) + "}"
            else: # Should not happen with current functions
                print(f"Warning: Unsupported parameter type for Lua call: {type(params)}")


        lua_command = f'game.print(remote.call("factorio_autonomo_bot", "{function_name}"{param_str}))'
        rcon_command = f"/sc {lua_command}" # /silent-command

        try:
            raw_response = self._execute_command(rcon_command)
            return self._parse_json_from_response(raw_response)
        except ConnectionError as e:
            print(f"RCON Connection error during Lua call '{function_name}': {e}")
            return None
        except Exception as e:
            print(f"An unexpected error occurred during Lua call '{function_name}': {e}")
            return None

    def get_player_info(self):
        return self._execute_lua_call("get_player_info")

    def start_walking(self, x, y):
        """
        Commands the player character to start walking to the given x, y coordinates.
        """
        params = {"x": x, "y": y}
        return self._execute_lua_call("start_pathfinding_to", params)

    def check_movement_status(self):
        """
        Checks the current movement status of the player character.
        """
        return self._execute_lua_call("get_movement_status")

    def scan_area(self, radius):
        """
        Scans the area around the player for entities.
        """
        return self._execute_lua_call("scan_nearby_entities", {"radius": radius})

    def get_recipes(self):
        """
        Retrieves all unlocked recipes for the player's force.
        """
        return self._execute_lua_call("get_all_unlocked_recipes")


    def mine_target_entity(self, entity_id):
        """
        Commands the player to mine the entity with the given unit_number.
        """
        if entity_id is None:
            print("RCONClient Error: entity_id cannot be None for mine_target_entity.")
            return {"status": "error", "message": "entity_id was None"}
        return self._execute_lua_call("mine_target_entity", {"unit_number": entity_id})

class GeminiAgent:
    def __init__(self, api_key):
        if not api_key:
            raise ValueError("Gemini API key not provided.")
        genai.configure(api_key=api_key)
        # Consider making model configurable e.g. 'gemini-1.5-flash' for speed/cost
        self.model = genai.GenerativeModel('gemini-1.0-pro')
        print("Gemini Agent initialized with gemini-1.0-pro.")

    def decide_next_action(self, game_state_dict, nearby_entities_list, known_recipes_dict):
        """
        Asks the Gemini model for a strategic action based on full game state.
        """
        if not game_state_dict:
            print("GeminiAgent: Player game state not provided.")
            return None

        # Prepare concise representations for the prompt
        inventory_summary = game_state_dict.get('inventory', {})
        position_summary = game_state_dict.get('position', {})

        # For recipes, sending all might be too much. For now, let's send a count.
        # A better approach might be to let Gemini ask for specific recipe details if needed,
        # or provide a way to query recipes based on item names.
        # For this iteration, we'll include a snippet of recipes, e.g. for basic iron items.
        recipes_summary_list = []
        if known_recipes_dict and 'recipes' in known_recipes_dict:
            recipes_summary_list.append(f"Total recipes known: {len(known_recipes_dict['recipes'])}.")
            # Example: Find a few key recipes to include
            for recipe in known_recipes_dict['recipes'][:5]: # Show first 5 for brevity
                    recipes_summary_list.append(f"  - {recipe['name']}: Produces {[(p['name'], p['amount']) for p in recipe['products']]}")

        recipes_summary = "\n".join(recipes_summary_list) if recipes_summary_list else "No recipes loaded."

        # Define current task based on a simple logic for now
        # This can be expanded into a more sophisticated task planner/state machine later

        iron_ore_needed = 20
        coal_needed_for_smelting = 10 # Assuming we'll need fuel

        iron_ore_count = inventory_summary.get("iron-ore", 0)
        coal_count = inventory_summary.get("coal", 0)

        if iron_ore_count < iron_ore_needed:
            current_task_description = f"Current Task: Acquire at least {iron_ore_needed} iron ore. You currently have {iron_ore_count}."
        elif coal_count < coal_needed_for_smelting:
            current_task_description = f"Current Task: Acquire at least {coal_needed_for_smelting} coal for smelting. You have {iron_ore_count} iron ore and {coal_count} coal."
        else:
            current_task_description = f"Current Task: You have {iron_ore_count} iron ore and {coal_count} coal. Consider next steps for iron plate production (e.g., finding a spot for furnaces, or gathering more resources if needed for building them, or crafting a furnace if possible)."

        # Update entities summary to include amount if available
        entities_prompt_list_updated = []
        if nearby_entities_list and 'entities' in nearby_entities_list:
            for entity in nearby_entities_list['entities'][:15]: # Limit to avoid excessive prompt length
                amount_str = f", amount: {entity['amount']}" if 'amount' in entity else ""
                entities_prompt_list_updated.append(f"- {entity['name']} at ({entity['position']['x']}, {entity['position']['y']}) id:{entity.get('unit_number', 'N/A')}{amount_str}")
        entities_summary_updated = "\n".join(entities_prompt_list_updated) if entities_prompt_list_updated else "None visible"


        prompt = f"""You are an AI agent playing Factorio.
Overall Goal: Automate the production of iron gear wheels, which requires iron plates, which requires iron ore and coal.
{current_task_description}

Current Player State:
Position: {position_summary}
Inventory: {inventory_summary}
Health: {game_state_dict.get('health')}
Game Tick: {game_state_dict.get('tick')}

Nearby Resources (max 15 shown, with their unique unit_number as 'id' and remaining 'amount' if applicable):
{entities_summary_updated}

Known Recipes (sample of first 5):
{recipes_summary}

Based on ALL this information, what is the single most important action to perform NEXT to achieve your CURRENT TASK and progress the OVERALL GOAL?
Respond with ONLY a valid JSON object specifying the action and its parameters.
Valid actions are:
1. "MOVE": To move to a specific x, y coordinate.
   Parameters: {{"x": float, "y": float}}
   Use this if you need to get closer to resources or a strategic location.

2. "MINE": To mine a target resource.
   Parameters: {{"target_entity_id": int | null, "target_name": "resource-name" | null}}
   - Provide `target_entity_id` if you see a specific resource entity in 'Nearby Resources' that you want to mine. Use its 'id' value. Consider its 'amount' if available.
   - Provide `target_name` (e.g., "iron-ore", "coal", "stone", "tree") if you want to mine that type of resource but don't have a specific ID, or if the ID is not critical.
   - If you specify `target_entity_id`, the agent will attempt to move to and mine that specific entity.
   - If you only specify `target_name`, the agent will try to find the closest one from its scan.
   Priority: Use `target_entity_id` if a suitable one is listed in 'Nearby Resources'.

3. "CRAFT": To craft an item from a recipe. (Currently, the agent can only craft items that don't require a machine).
   Parameters: {{"recipe_name": "recipe-internal-name", "quantity": int}}

Example Response for MOVE to coordinates 123.5, -45.0:
{{"action": "MOVE", "parameters": {{"x": 123.5, "y": -45.0}}, "reasoning": "Moving to a large iron ore patch spotted earlier."}}

Example Response for MINE a specific iron ore entity with id 789 (which has 5000 ore remaining):
{{"action": "MINE", "parameters": {{"target_entity_id": 789, "target_name": "iron-ore"}}, "reasoning": "Need iron ore for plates, and entity 789 is the closest rich iron ore patch."}}

Example Response for MINE any nearby coal if no specific ID is crucial:
{{"action": "MINE", "parameters": {{"target_entity_id": null, "target_name": "coal"}}, "reasoning": "Need coal for fuel."}}

Example Response for CRAFT (e.g., a stone furnace, assuming it's a player-craftable recipe):
{{"action": "CRAFT", "parameters": {{"recipe_name": "stone-furnace", "quantity": 1}}, "reasoning": "Need a furnace to smelt iron ore."}}

Your decision must be strategic.
- If you need a resource for your current task and it's listed in 'Nearby Resources', prefer 'MINE' with the `target_entity_id`. Choose richer patches (higher 'amount') if multiple options exist.
- If you need a resource not immediately visible, you might need to 'MOVE' to a known location or explore.
- Only 'CRAFT' if you have the ingredients and the item is essential for the current task.
Ensure your response is ONLY the JSON object. No other text, explanations, or markdown formatting.
"""
        # print(f"\n--- Gemini Prompt (Refined Further) ---\n{prompt}\n--------------------") # Verbose debug

        try:
            response = self.model.generate_content(prompt)
            # print(f"Raw Gemini Response Text: {response.text}") # Verbose debug

            json_match = re.search(r'\{[\s\S]*\}', response.text) # More robust regex for JSON block
            if json_match:
                json_str = json_match.group(0)
                try:
                    action_plan = json.loads(json_str)
                    # Basic validation
                    if isinstance(action_plan, dict) and "action" in action_plan and "parameters" in action_plan:
                        print(f"Gemini decided action: {action_plan.get('action')}, Parameters: {action_plan.get('parameters')}, Reasoning: {action_plan.get('reasoning')}")
                        return action_plan
                    else:
                        print(f"Gemini response JSON does not match expected structure: {json_str}")
                        return None
                except json.JSONDecodeError as e:
                    print(f"Failed to decode JSON from Gemini response: {e}. String was: {json_str}")
                    return None
            else:
                print(f"Could not find valid JSON in Gemini response: '{response.text}'")
                return None

        except Exception as e:
            print(f"Error calling Gemini API or processing response: {e}")
            return None

def main():
    # --- Configuration ---
    factorio_server_host = os.getenv("FACTORIO_HOST", "127.0.0.1")
    factorio_rcon_port = int(os.getenv("FACTORIO_RCON_PORT", 27015))
    factorio_rcon_password = os.getenv("FACTORIO_RCON_PASSWORD", "YOUR_RCON_PASSWORD")
    gemini_api_key = os.getenv("GEMINI_API_KEY")
    scan_radius = int(os.getenv("SCAN_RADIUS", 32)) # Default scan radius if not set

    print("Factorio Autonomo-Bot Agent - Environmental Awareness Update")
    print("-------------------------------------------------------------")

    if factorio_rcon_password == "YOUR_RCON_PASSWORD" or not factorio_rcon_password:
        print("\nCRITICAL WARNING: FACTORIO_RCON_PASSWORD is not set or using default. Agent will likely fail.")
        # return # Optionally exit
    if not gemini_api_key:
        print("\nCRITICAL WARNING: GEMINI_API_KEY environment variable not set. GeminiAgent will not function.")
        # return

    rcon_client = FactorioRCONClient(factorio_server_host, factorio_rcon_port, factorio_rcon_password)

    ai_agent = None
    if gemini_api_key:
        try:
            ai_agent = GeminiAgent(api_key=gemini_api_key)
        except ValueError as e:
            print(f"Error initializing Gemini Agent: {e}")
    else:
        print("Proceeding without Gemini Agent due to missing API key.")

    all_recipes_data = None # To store recipes

    try:
        rcon_client.connect() # Initial connection attempt

        # Get recipes once at the beginning
        print("Fetching all unlocked recipes...")
        all_recipes_data = rcon_client.get_recipes()
        if not all_recipes_data or "recipes" not in all_recipes_data:
            print("CRITICAL: Failed to fetch recipes. Check mod and RCON connection. Exiting.")
            return
        print(f"Successfully fetched {len(all_recipes_data['recipes'])} recipes.")


        loop_count = 0
        max_loops = 10 # Limit loops for testing
        print(f"*** Running for a maximum of {max_loops} loops for this test run. ***")

        while loop_count < max_loops :
            loop_count += 1
            print(f"\n--- Main Loop Iteration: {loop_count}/{max_loops} ---")

            # 1. SENSE
            print("SENSE: Gathering game state...")
            player_info = rcon_client.get_player_info()
            if not player_info or "error" in player_info: # Basic check for player_info validity
                print(f"Failed to get player info: {player_info.get('error', 'Unknown error') if player_info else 'No response'}. Retrying in 5s...")
                time.sleep(5)
                continue

            # Log key inventory items at the start of the Sense phase
            current_inventory = player_info.get('inventory', {})
            print(f"  Inventory Snapshot: Iron Ore: {current_inventory.get('iron-ore', 0)}, Coal: {current_inventory.get('coal', 0)}, Stone: {current_inventory.get('stone', 0)}, Copper Ore: {current_inventory.get('copper-ore', 0)}")

            nearby_entities = rcon_client.scan_area(radius=scan_radius)
            if not nearby_entities or "error" in nearby_entities: # Basic check for nearby_entities validity
                print(f"Failed to scan nearby entities: {nearby_entities.get('error', 'Unknown error') if nearby_entities else 'No response'}. Using empty scan for this cycle.")
                nearby_entities = {"entities": []}

            print(f"  Player Pos: {player_info.get('position')}")
            print(f"  Nearby Entities Scanned: {len(nearby_entities.get('entities', []))} found within radius {scan_radius}.")
            # Optional: Log a few scanned entities for quick check
            # for i, entity in enumerate(nearby_entities.get('entities', [])[:3]):
            #     print(f"     Entity {i+1}: {entity.get('name')} at {entity.get('position')} ID: {entity.get('unit_number')} Amt: {entity.get('amount')}")

            if not ai_agent:
                print("THINK: Skipping AI decision (GeminiAgent not initialized).")
                print("Stopping loop as no decisions can be made.")
                break

            # 2. THINK
            print("THINK: Asking Gemini for the next action...")
            action_to_perform = ai_agent.decide_next_action(player_info, nearby_entities, all_recipes_data)

            if not action_to_perform or "action" not in action_to_perform:
                print("Gemini failed to provide a valid action. Retrying decision in 10 seconds...")
                time.sleep(10)
                continue

            action_type = action_to_perform.get("action")
            action_params = action_to_perform.get("parameters", {})
            action_reasoning = action_to_perform.get("reasoning", "No reasoning provided.")
            print(f"  AI Action: {action_type}, Params: {action_params}, Reasoning: {action_reasoning}")

            # 3. ACT
            print(f"ACT: Executing action: {action_type}")
            if action_type == "MOVE":
                dest_x = action_params.get("x")
                dest_y = action_params.get("y")
                if dest_x is not None and dest_y is not None:
                    print(f"  Commanding player to walk to ({dest_x}, {dest_y})...")
                    walk_command_response = rcon_client.start_walking(dest_x, dest_y)
                    if not walk_command_response or walk_command_response.get("path_found") is False:
                        print(f"  Failed to initiate walking or path not found. Response: {walk_command_response}")
                        time.sleep(2) # Brief pause before next cycle
                        continue

                    print(f"  Pathfinding response: {walk_command_response.get('status')}, Waypoints: {walk_command_response.get('waypoints', 'N/A')}")

                    # Monitor Movement
                    print("  Monitoring movement status...")
                    movement_timeout_seconds = 120 # Max time to wait
                    start_time = time.time()
                    destination_reached = False
                    while time.time() - start_time < movement_timeout_seconds:
                        time.sleep(2) # Check status every 2 seconds
                        status = rcon_client.check_movement_status()
                        if not status:
                            print("  Failed to get movement status. Assuming movement interrupted.")
                            break
                        if status.get("destination_reached"):
                            print("  Movement status: Destination Reached!")
                            destination_reached = True
                            break
                        else:
                            cp = status.get('current_position', {})
                            print(f"  Moving... Pos: {cp.get('x')},{cp.get('y')}. Target: {dest_x},{dest_y}. Waypoint {status.get('current_waypoint')}/{status.get('total_waypoints')}")

                    if not destination_reached:
                        print("  Movement timeout or interruption.")
                else:
                    print(f"  Invalid parameters for MOVE action: {action_params}")

            elif action_type == "MINE":
                target_id = action_params.get("target_entity_id")
                target_name = action_params.get("target_name") # Should usually be resource type like "iron-ore"

                if not target_id and not target_name:
                    print(f"  Invalid parameters for MINE action: Missing target_entity_id or target_name. Params: {action_params}")
                    time.sleep(2)
                    continue

                print(f"  Attempting MINE action. Target ID: {target_id}, Target Name: {target_name}")

                # Logic to handle MINE action
                entity_to_mine = None
                if target_id:
                    # Find the entity in the nearby_entities list to get its position
                    if nearby_entities and "entities" in nearby_entities:
                        for entity in nearby_entities["entities"]:
                            if entity.get("unit_number") == target_id:
                                entity_to_mine = entity
                                break
                    if not entity_to_mine:
                        print(f"  Warning: Target entity ID {target_id} for MINE action not found in recent scan. Gemini might be using outdated info or hallucinating.")
                        # Fallback: if Gemini also gave a name, we could try to find by name, or just re-scan/re-think next loop.
                        # For now, we'll just skip if specific ID not found in scan.
                        time.sleep(2)
                        continue

                elif target_name: # No ID given, try to find closest by name
                    if nearby_entities and "entities" in nearby_entities:
                        closest_entity_of_type = None
                        min_dist_sq = float('inf')
                        player_pos = player_info.get("position", None)

                        if player_pos:
                            px = float(player_pos.get("x", 0))
                            py = float(player_pos.get("y", 0))
                            for entity in nearby_entities["entities"]:
                                if entity.get("name") == target_name:
                                    ex = float(entity.get("position", {}).get("x", 0))
                                    ey = float(entity.get("position", {}).get("y", 0))
                                    dist_sq = (px - ex)**2 + (py - ey)**2
                                    if dist_sq < min_dist_sq:
                                        min_dist_sq = dist_sq
                                        closest_entity_of_type = entity
                            entity_to_mine = closest_entity_of_type

                    if not entity_to_mine:
                        print(f"  Warning: Could not find any entity of type '{target_name}' in recent scan for MINE action.")
                        time.sleep(2)
                        continue

                if entity_to_mine:
                    print(f"  Selected entity for mining: {entity_to_mine.get('name')} (ID: {entity_to_mine.get('unit_number')}, Pos: {entity_to_mine.get('position')}, Amt: {entity_to_mine.get('amount', 'N/A')})")
                    # TODO: For more precise mining, calculate an adjacent tile to the resource instead of its center.
                    # Current approach: move to the entity's position. Factorio's pathfinder/player interaction usually handles this fine for mining.
                    mine_target_pos = entity_to_mine.get("position")

                    target_mine_x = float(mine_target_pos.get("x"))
                    target_mine_y = float(mine_target_pos.get("y"))

                    # Check if already close enough to the target to skip walking
                    player_current_pos_dict = player_info.get("position", {})
                    player_x = float(player_current_pos_dict.get("x", 0))
                    player_y = float(player_current_pos_dict.get("y", 0))
                    distance_to_target_sq = (player_x - target_mine_x)**2 + (player_y - target_mine_y)**2
                    mining_reach_threshold_sq = 2.0**2 # Approx 2 tiles reach for mining

                    mine_move_reached = False
                    if distance_to_target_sq <= mining_reach_threshold_sq:
                        print(f"  Player is already close enough to mining target (Dist^2: {distance_to_target_sq:.2f}). Skipping movement.")
                        mine_move_reached = True
                    else:
                        print(f"  Moving to entity {entity_to_mine.get('unit_number')} at ({target_mine_x}, {target_mine_y}) to mine...")
                        walk_resp = rcon_client.start_walking(target_mine_x, target_mine_y)
                        if not walk_resp or walk_resp.get("path_found") is False:
                            print(f"    Failed to initiate walking to mining target. Response: {walk_resp}")
                            time.sleep(2)
                            continue # Skip to next main loop iteration

                        # Monitor movement to mining target
                        print(f"    Pathfinding for MINE: {walk_resp.get('status')}, Waypoints: {walk_resp.get('waypoints', 'N/A')}")
                        mine_move_timeout = 60 # Shorter timeout for moving to adjacent mining spot
                        mine_move_start_time = time.time()

                        while time.time() - mine_move_start_time < mine_move_timeout:
                            time.sleep(1.5) # Check status
                            status = rcon_client.check_movement_status()
                            if not status:
                                print("    Failed to get movement status while moving to mine.")
                                break
                            if status.get("destination_reached"):
                                print("    Reached mining position.")
                                mine_move_reached = True
                                break
                            else:
                                cp_m = status.get('current_position', {})
                                print(f"    Moving to mine... Pos: {cp_m.get('x')},{cp_m.get('y')}. Target: {target_mine_x},{target_mine_y}. Waypoint {status.get('current_waypoint')}/{status.get('total_waypoints')}")

                    if mine_move_reached:
                        print(f"  Executing MINE RCON command for {entity_to_mine.get('name')} (ID: {entity_to_mine.get('unit_number')}).")
                        # Log current inventory of the target resource BEFORE mining
                        resource_name_to_check = entity_to_mine.get('name') # e.g. "iron-ore"
                        inv_before_mine = player_info.get('inventory', {}).get(resource_name_to_check, 0)
                        print(f"    Inventory of '{resource_name_to_check}' before mining: {inv_before_mine}")

                        mine_init_response = rcon_client.mine_target_entity(entity_to_mine.get('unit_number'))
                        print(f"    MINE command RCON response: {mine_init_response}")

                        if mine_init_response and mine_init_response.get("status") == "mining_initiated":
                            simulated_mining_duration = 5 # seconds
                            print(f"    Mining initiated. Simulating mining duration of {simulated_mining_duration} seconds...")
                            time.sleep(simulated_mining_duration)
                            print("    Finished simulated mining duration.")
                            # Inventory check will happen in the next SENSE phase.
                        else:
                            print(f"    Failed to initiate mining via RCON or error reported: {mine_init_response}")
                            time.sleep(1) # Brief pause if mining failed to start
                    else:
                        print("    Failed to reach mining position or movement timed out.")
                else:
                    # This case should be caught by earlier checks for target_id and target_name
                    print(f"  Error: Could not determine a specific entity to mine based on parameters: {action_params}")

            elif action_type == "CRAFT":
                recipe_name = action_params.get("recipe_name")
                quantity = action_params.get("quantity", 1)
                print(f"  AI decided to CRAFT: Recipe: {recipe_name}, Quantity: {quantity}. (Action not yet implemented in Python agent)")
                # Placeholder for future CRAFT implementation

            else:
                print(f"  Unknown or unsupported action from AI: {action_type}")

            print("Waiting 5 seconds before next Sense-Think-Act cycle...")
            time.sleep(5)


    except ConnectionError as e:
        print(f"RCON Connection Error: {e}")
        print("Please ensure your Factorio server is running, RCON is enabled,")
        print("and the host, port, and password in environment variables or script are correct.")
    except KeyboardInterrupt:
        print("\nAgent loop interrupted by user.")
    except Exception as e:
        print(f"An unexpected error occurred in main loop: {e}")
    finally:
        if rcon_client._is_connected:
             rcon_client.disconnect()
        print("Factorio Autonomo-Bot Agent stopped.")

if __name__ == "__main__":
    main()