# Factorio Autonomo-Bot

**Factorio Version: 2.0.55 or newer**

Factorio Autonomo-Bot is a Python-based AI agent designed to play the game Factorio autonomously. It interacts with a headless Factorio server (version 2.0+) through a custom Lua mod and the server's RCON interface. Decision-making, including strategic actions like moving, mining, or crafting, is guided by Google's Gemini AI.

## Project Architecture

The project consists of three main components:

1.  **Factorio Lua Mod (`/factorio_mod`)**:
    *   This custom mod, compatible with Factorio 2.0+, is installed on the Factorio server.
    *   **Stateful Movement**: Uses Factorio's built-in pathfinder (`game.player.surface.find_path`) and an `on_tick` handler to manage character movement along a series of waypoints stored in the `global` Lua table.
    *   **Environmental Awareness & Game Knowledge**: Provides functions to:
        *   Scan the vicinity for resource entities (trees, ores, etc.).
        *   Retrieve all recipes currently unlocked by the player's force.
    *   **RCON Interface Functions**: Exposes Lua functions callable via RCON for player info, movement control, environmental scanning, and recipe lookups.

2.  **AI Agent (`/agent`)**:
    *   This Python application houses the "brain" of the AI.
    *   **RCON Client (`FactorioRCONClient`)**: Connects to the Factorio server's RCON interface to execute Lua functions in the custom mod.
    *   **Gemini Integration (`GeminiAgent`)**:
        *   Uses the `google-generativeai` library.
        *   The `decide_next_action()` method constructs a detailed prompt for the Gemini model. This prompt includes the current player status (inventory, position), data from environmental scans (nearby resources), and the list of known recipes.
        *   Gemini is asked to determine the single most important action (e.g., MOVE, MINE, CRAFT) and its parameters, returning this as a structured JSON object.
    *   **Sense, Think, Act Loop**: The `main.py` script implements this core AI cycle:
        1.  **Sense**: Gathers current player info, scans nearby entities, and (once at startup) retrieves all known recipes.
        2.  **Think**: Passes the comprehensive game state to `GeminiAgent` to get a structured action plan (e.g., `{"action": "MOVE", "parameters": {"x": 10, "y": 20}, "reasoning": "..."}`).
        3.  **Act**: Executes the action prescribed by Gemini. Currently, "MOVE" actions are fully implemented, with placeholders for future "MINE" and "CRAFT" actions.

3.  **RCON Interface**:
    *   Factorio's RCON interface allows external tools to send console commands.
    *   The Python agent uses commands like `/sc game.print(remote.call("factorio_autonomo_bot", "function_name", {params}))` to trigger Lua functions.
    *   The Lua mod returns JSON-formatted data via `game.print()`, which the Python RCON client captures and parses.

**Communication & Control Flow (Enhanced):**
```
+-------------------+  RCON Cmds (Lua Call) +----------------------+  Lua Calls (Mod Func) +-------------------------+  Game Actions
| Python AI Agent   |<--------------------| Factorio Server RCON |<--------------------| Custom Lua Mod          |---->(Pathfind, Move)
| (agent/main.py)   |                     |   Interface          |                     | (control.lua)           |
| - GeminiAgent     |    JSON Responses   |   (Port 27015)       |   JSON Responses    | - get_player_info       |<----(Player State)
| - FactorioRCONClient|                     |                      |                     | - start_pathfinding_to  |
| - Sense/Think/Act |                     |                      |                     | - get_movement_status   |
|                   |                     |                      |                     | - scan_nearby_entities  |<----(Nearby Entities)
|                   |                     |                      |                     | - get_all_unlocked_recipes|<--(Recipe Data)
+-------------------+                     +----------------------+                     | - on_tick_handler       |
                                                                                        +-------------------------+
```

## Environmental Awareness & Game Knowledge (Lua Mod)

The Lua mod provides crucial information to the AI agent:

*   **`scan_nearby_entities(radius)`**: This function acts as the agent's "vision."
    *   It uses `player.surface.find_entities_filtered` to locate resource entities (e.g., "iron-ore", "copper-ore", "stone", "coal") and trees (type "tree") within a specified `radius` around the player.
    *   Returns a JSON list of found entities, including their name, position, and unique `unit_number` (entity ID). This allows the AI to identify specific resource patches or individual trees.

*   **`get_all_unlocked_recipes()`**: This function provides the agent with its crafting knowledge base.
    *   It iterates through `game.player.force.recipes` and collects details for all `enabled` (unlocked) recipes.
    *   For each recipe, it extracts its name, ingredients (item names, amounts, types), and products (item names, amounts, types).
    *   Returns a comprehensive JSON object containing all this recipe data. This is typically called once at the start of an agent's session.

## Mod API / Available Agent Actions

The Python agent interacts with the Lua mod using these RCON-callable functions:

*   **`get_player_info()`**:
    *   **RCON Command**: `/sc game.print(remote.call("factorio_autonomo_bot", "get_player_info"))`
    *   **Returns (JSON)**: Player's current position, inventory, health, and game tick.
    ```json
    {"position": {"x": "10.50", "y": "-2.30"}, "inventory": {"iron-plate": 100}, "health": "100.0", "tick": 12345}
    ```

*   **`start_pathfinding_to(params)`**:
    *   **RCON Command Example**: `/sc game.print(remote.call("factorio_autonomo_bot", "start_pathfinding_to", {x=10.5, y=-20.0}))`
    *   **Parameters**: Lua table `{x=number, y=number}`.
    *   **Returns (JSON)**: Pathfinding status.
    ```json
    {"status": "Pathfinding initiated", "path_found": true, "waypoints": 15, "target": {"x": 10.5, "y": -20.0}}
    ```

*   **`get_movement_status()`**:
    *   **RCON Command**: `/sc game.print(remote.call("factorio_autonomo_bot", "get_movement_status"))`
    *   **Returns (JSON)**: Current movement state.
    ```json
    {"is_moving": true, "destination_reached": false, "target_position": {"x": 10.5, "y": -20.0}, "current_position": {"x": "5.20", "y": "-10.80"}}
    ```

*   **`scan_nearby_entities(params)`**:
    *   **RCON Command Example**: `/sc game.print(remote.call("factorio_autonomo_bot", "scan_nearby_entities", {radius=32}))`
    *   **Parameters**: Lua table `{radius=number}`.
    *   **Returns (JSON)**: List of nearby resource entities.
    ```json
    {
      "entities": [
        {"name": "iron-ore", "position": {"x": "12.75", "y": "-18.20"}, "unit_number": 12345},
        {"name": "tree-01", "position": {"x": "8.50", "y": "-15.00"}, "unit_number": 12346}
      ]
    }
    ```
    *(Note: `unit_number` is crucial for uniquely identifying entities for actions like mining).*

*   **`get_all_unlocked_recipes()`**:
    *   **RCON Command**: `/sc game.print(remote.call("factorio_autonomo_bot", "get_all_unlocked_recipes"))`
    *   **Returns (JSON)**: A list of all unlocked recipes.
    ```json
    {
      "recipes": [
        {
          "name": "iron-gear-wheel",
          "ingredients": [{"name": "iron-plate", "amount": 2, "type": "item"}],
          "products": [{"name": "iron-gear-wheel", "amount": 1, "type": "item"}]
        },
        // ... more recipes
      ]
    }
    ```

## AI Decision & Action Loop (Python Agent) - "Sense, Think, Act"

The Python agent (`agent/main.py`) now operates on a more intelligent "Sense, Think, Act" cycle:

1.  **Sense (Gather Information)**:
    *   **Once at Startup**: The agent calls `get_all_unlocked_recipes()` to build its knowledge base of available crafting options.
    *   **Each Loop Iteration**:
        *   Calls `get_player_info()` for current player status (position, inventory, etc.).
        *   Calls `scan_nearby_entities()` with a defined radius to "see" nearby resources.

2.  **Think (AI-Powered Decision Making)**:
    *   The comprehensive game state (player info, nearby entities, all known recipes) is compiled.
    *   This state is passed to `GeminiAgent.decide_next_action()`.
    *   The `GeminiAgent` constructs a detailed prompt for the Gemini AI model. The prompt includes the current game state, environmental data, recipe knowledge, and a strategic goal (e.g., "automate iron gear wheel production").
    *   Gemini is instructed to return a **structured JSON object** defining the single most important action to take next. This object specifies the `action` (e.g., "MOVE", "MINE", "CRAFT"), required `parameters` for that action, and `reasoning`.
    ```json
    // Example Gemini Response
    {
      "action": "MOVE",
      "parameters": {"x": 15.5, "y": -40.2},
      "reasoning": "Moving closer to the iron ore patch to prepare for mining."
    }
    ```

3.  **Act (Execute Action)**:
    *   The Python agent parses the JSON response from Gemini.
    *   Based on the `action` field:
        *   If **"MOVE"**: The agent calls `start_pathfinding_to(x, y)` with the coordinates from `parameters` and monitors movement completion as before.
        *   If **"MINE"** or **"CRAFT"**: (Currently placeholders) The agent acknowledges the decision. Future development will implement the RCON calls and logic to perform these actions (e.g., targeting a specific entity ID for mining, or selecting a recipe and ensuring ingredients are available for crafting).
    *   The loop then repeats, allowing for continuous, context-aware decision-making.

This enhanced loop allows the agent to not just decide *where to go*, but *what to do* (move, mine, craft, etc.) based on a richer understanding of its environment and capabilities.

## Setup Instructions

### 1. Factorio Headless Server Setup
*(No changes from previous version, instructions retained for completeness)*

*   **Download Factorio**:
    *   Go to the [Factorio website](https://www.factorio.com/download-headless) and download the headless server version for your operating system.
    *   Extract the archive to a directory of your choice (e.g., `~/factorio_server/`).
*   **Basic Configuration**:
    *   Navigate to the `data` directory within your Factorio server installation (e.g., `~/factorio_server/data/`).
    *   Copy `server-settings.example.json` to `server-settings.json`.
    *   Edit `server-settings.json`:
        *   Set a server name and description if desired.
        *   **Enable RCON**:
            *   Ensure `rcon_port` is set (e.g., `"rcon_port": 27015,`).
            *   Set a strong `rcon_password` (e.g., `"rcon_password": "your_secure_password_here",`).
*   **Create a Save File (Map)**:
    *   `./bin/x64/factorio --create my_server_save.zip` (adjust path as needed).
*   **Start the Server**:
    *   `./bin/x64/factorio --start-server my_server_save.zip --server-settings ./data/server-settings.json`

### 2. Install the Custom Mod (`factorio_autonomo_bot`)
*(No changes from previous version, instructions retained for completeness)*

*   **Locate Factorio Mods Directory**:
    *   **Windows**: `%APPDATA%\Factorio\mods`
    *   **Linux**: `~/.factorio/mods`
    *   **macOS**: `~/Library/Application Support/factorio/mods`
*   **Copy the Mod**:
    *   Copy the entire `factorio_mod` directory from this project into your Factorio mods directory.
    *   Rename the copied directory to `factorio_autonomo_bot_X.Y.Z` (matching `info.json` version, e.g., `factorio_autonomo_bot_0.1.0`). Factorio expects mod directories to be named `modname_version`.
    *   Alternatively, zip the *contents* of `factorio_mod` (info.json, control.lua at zip root) into `factorio_autonomo_bot_X.Y.Z.zip` and place it in the mods folder.
*   **Verify Mod Installation**: Check server log for messages like `Initializing mod factorio_autonomo_bot (...)` and `Factorio Autonomo-Bot Mod Initialized. Interface 'factorio_autonomo_bot' is ready with movement.`

### 3. Python Agent Setup

*   **Prerequisites**:
    *   Python 3.7+
*   **Clone the Repository**:
    ```bash
    git clone <repository_url>
    cd factorio-autonomo-bot
    ```
*   **Create a Virtual Environment (recommended)**:
    ```bash
    python -m venv venv
    source venv/bin/activate  # On Windows: venv\Scripts\activate
    ```
*   **Install Dependencies**:
    ```bash
    pip install -r requirements.txt
    ```
    (This will now include `google-generativeai` for Gemini).
*   **Configure Environment Variables**:
    The agent now uses environment variables for configuration:
    *   `FACTORIO_HOST`: The IP address of your Factorio server (defaults to `127.0.0.1`).
    *   `FACTORIO_RCON_PORT`: The RCON port of your server (defaults to `27015`).
    *   `FACTORIO_RCON_PASSWORD`: The RCON password for your server. **This must be set.**
    *   `GEMINI_API_KEY`: Your API key for the Google Gemini service. **This must be set for AI decision-making.**

    Set these variables in your shell environment or a `.env` file (if you use a library like `python-dotenv`, though it's not included by default).
    Example for bash:
    ```bash
    export FACTORIO_RCON_PASSWORD="your_rcon_password_here"
    export GEMINI_API_KEY="your_gemini_api_key_here"
    ```
*   **Run the Agent**:
    ```bash
    python agent/main.py
    ```
    If everything is configured correctly, the agent will connect, and you'll see it start its decision-making loop, including communication with Gemini and commanding player movement.

## Future Development
*   Implement more sophisticated game state parsing in Lua (e.g., nearby entities, terrain type).
*   Expand Lua functions for more granular actions (mining, crafting, building).
*   Refine Gemini prompts for more complex strategies and long-term planning.
*   Improve error handling and resilience in both the Lua mod and Python agent.
*   Explore methods for the agent to learn and adapt its strategies over time.
*   Consider visual input processing if Factorio modding allows for screen capture or map data extraction in a way that Gemini can interpret.
```
