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

        entities_prompt_list = []
        if nearby_entities_list and 'entities' in nearby_entities_list:
            for entity in nearby_entities_list['entities'][:15]: # Limit to avoid excessive prompt length
                entities_prompt_list.append(f"- {entity['name']} at ({entity['position']['x']}, {entity['position']['y']}) id:{entity.get('unit_number', 'N/A')}")
        entities_summary = "\n".join(entities_prompt_list) if entities_prompt_list else "None visible"

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


        prompt = f"""You are an AI agent playing Factorio. Your current primary goal is to automate the production of iron gear wheels.
Consider the steps: acquire iron ore, smelt iron ore into iron plates, then craft iron plates into iron gear wheels.

Current Player State:
Position: {position_summary}
Inventory: {inventory_summary}
Health: {game_state_dict.get('health')}
Game Tick: {game_state_dict.get('tick')}

Nearby Resources (max 15 shown):
{entities_summary}

Known Recipes (sample):
{recipes_summary}

Based on ALL this information, what is the single most important action to perform NEXT to progress towards automating iron gear wheel production?
Respond with ONLY a JSON object specifying the action and its parameters.
Valid actions are:
1. "MOVE": To move to a specific x, y coordinate.
   Parameters: {{"x": float, "y": float}}
2. "MINE": To mine a target resource. Provide target_entity_id if known from scan, otherwise target_name.
   Parameters: {{"target_entity_id": int_or_null, "target_name": "resource-name_or_null"}}
3. "CRAFT": To craft an item from a recipe.
   Parameters: {{"recipe_name": "recipe-internal-name", "quantity": int}}

Example Response for MOVE:
{{"action": "MOVE", "parameters": {{"x": 123.5, "y": -45.0}}, "reasoning": "Moving to iron ore patch."}}
Example Response for MINE (if you see iron ore with ID 789):
{{"action": "MINE", "parameters": {{"target_entity_id": 789, "target_name": "iron-ore"}}, "reasoning": "Need iron ore."}}
Example Response for CRAFT:
{{"action": "CRAFT", "parameters": {{"recipe_name": "iron-plate", "quantity": 5}}, "reasoning": "Smelting iron ore."}}

Your decision should be strategic and directly contribute to the goal. If you need a resource you don't have, and it's nearby, consider MINE. If you have ingredients for a key recipe, consider CRAFT. If resources or crafting stations are far, MOVE.
Provide your response as a single, valid JSON object and nothing else.
"""
        # print(f"\n--- Gemini Prompt ---\n{prompt}\n--------------------") # Verbose debug

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

        while loop_count < max_loops :
            loop_count += 1
            print(f"\n--- Main Loop Iteration: {loop_count}/{max_loops} ---")

            # 1. SENSE
            print("SENSE: Gathering game state...")
            player_info = rcon_client.get_player_info()
            if not player_info or "error" in player_info:
                print(f"Failed to get player info: {player_info.get('error', 'Unknown error')}. Retrying in 5s...")
                time.sleep(5)
                continue

            nearby_entities = rcon_client.scan_area(radius=scan_radius)
            if not nearby_entities or "error" in nearby_entities:
                print(f"Failed to scan nearby entities: {nearby_entities.get('error', 'Unknown error')}. Using empty scan.")
                nearby_entities = {"entities": []} # Allow loop to continue with empty scan

            print(f"  Player Info: Pos={player_info.get('position')}, Inv Keys={list(player_info.get('inventory', {}).keys())}")
            print(f"  Nearby Entities: {len(nearby_entities.get('entities', []))} found within radius {scan_radius}.")

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
                target_name = action_params.get("target_name")
                print(f"  AI decided to MINE: Target ID: {target_id}, Name: {target_name}. (Action not yet implemented in Python agent)")
                # Placeholder for future MINE implementation

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
