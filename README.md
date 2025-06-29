# Factorio Autonomo-Bot

Factorio Autonomo-Bot is a Python-based AI agent designed to play the game Factorio autonomously. It interacts with a headless Factorio server through a custom Lua mod and the server's RCON (Remote Console) interface.

## Project Architecture

The project consists of three main components:

1.  **Factorio Lua Mod (`/factorio_mod`)**:
    *   This is a custom mod installed on the Factorio server.
    *   It exposes Lua functions that can be called by the AI agent via RCON commands.
    *   The initial function, `get_player_info`, collects in-game data like player position and inventory and returns it as a JSON string.
    *   This mod acts as the bridge, allowing the external agent to query game state and eventually send commands to control game actions.

2.  **AI Agent (`/agent`)**:
    *   This is a Python application that contains the "brain" of the AI.
    *   It uses an RCON client library (`mcrcon`) to connect to the Factorio server's RCON interface.
    *   The agent sends specific commands to the server to execute functions within our custom Lua mod (e.g., `remote.call("factorio_autonomo_bot", "get_player_info")`).
    *   It parses the data (JSON strings) returned by the Lua mod to understand the current game state.
    *   Future development will involve implementing decision-making logic (e.g., using AI/ML models like Gemini) within this agent to determine game actions.

3.  **RCON Interface**:
    *   Factorio servers can enable an RCON interface, allowing external tools to send console commands.
    *   The Python agent uses this interface to send commands that trigger the Lua functions in our custom mod.
    *   The Lua functions then use `game.print()` or `game.rcon_print()` to send data back, which the RCON client in the Python agent captures.

**Communication Flow:**

```
Python AI Agent  <--TCP/IP-->  Factorio Server RCON  <-->  Custom Lua Mod  <-->  Factorio Game Engine
   (main.py)                         Interface          (control.lua)
                                     (port 27015)
      |                                   |                     |
      |--- Sends RCON command (e.g.,     |                     |
      |    "/sc game.print(remote.call('factorio_autonomo_bot', 'get_player_info'))") --> |                     |
      |                                   | --- Executes Lua command ---> |
      |                                   |                     | --- Calls get_player_info_impl()
      |                                   |                     | --- Returns JSON string
      |                                   | <--- Lua mod prints JSON ---- |
      | <--- Receives JSON string --------|                             |
      |      (via mcrcon response)        |                             |
```

## Setup Instructions

### 1. Factorio Headless Server Setup

*   **Download Factorio**:
    *   Go to the [Factorio website](https://www.factorio.com/download-headless) and download the headless server version for your operating system.
    *   Extract the archive to a directory of your choice (e.g., `~/factorio_server/`).

*   **Basic Configuration**:
    *   Navigate to the `data` directory within your Factorio server installation (e.g., `~/factorio_server/data/`).
    *   Copy `server-settings.example.json` to `server-settings.json`.
    *   Edit `server-settings.json`:
        *   Set a server name and description if desired.
        *   **Enable RCON**:
            *   Find or add the `rcon_port` setting and ensure it's set (e.g., `"rcon_port": 27015,`).
            *   Find or add the `rcon_password` setting and set a strong password (e.g., `"rcon_password": "your_secure_password_here",`). **Remember this password for the Python agent.**

*   **Create a Save File (Map)**:
    *   You need a map for the server to host. To create one for a headless server:
        ```bash
        ./bin/x64/factorio --create my_server_save.zip
        ```
        (Adjust path to `factorio` executable based on your OS/installation).
    *   This will create `my_server_save.zip` in the main Factorio server directory.

*   **Start the Server**:
    *   Run the server with the save file:
        ```bash
        ./bin/x64/factorio --start-server my_server_save.zip --server-settings ./data/server-settings.json
        ```
    *   You should see log output indicating the server is running and RCON is active.

### 2. Install the Custom Mod (`factorio_autonomo_bot`)

*   **Locate Factorio Mods Directory**:
    *   This is typically in your user's application data folder:
        *   **Windows**: `%APPDATA%\Factorio\mods`
        *   **Linux**: `~/.factorio/mods`
        *   **macOS**: `~/Library/Application Support/factorio/mods`
    *   If this directory doesn't exist, run Factorio (the graphical game client) once to create it, or create it manually.

*   **Copy the Mod**:
    *   Copy the entire `factorio_mod` directory from this project into your Factorio mods directory.
    *   Rename the copied directory from `factorio_mod` to `factorio_autonomo_bot_0.1.0` (or whatever version is in `info.json`). Factorio expects mod directories to be named `modname_version`.
        *   Alternatively, you can zip the *contents* of the `factorio_mod` directory (i.e., `info.json` and `control.lua` should be at the root of the zip) and name the zip file `factorio_autonomo_bot_0.1.0.zip`. Then place this zip file in the mods directory.

*   **Verify Mod Installation**:
    *   When you start your Factorio headless server (or the regular game client), the mod should be loaded.
    *   Check the server log (or in-game console if using the client) for a message like:
        `Info ModManager.cpp:NNN: Initializing mod factorio_autonomo_bot (0.1.0)`
        And from our mod:
        `Factorio Autonomo-Bot Mod Initialized. Interface 'factorio_autonomo_bot' is ready.`

### 3. Python Agent Setup

*   **Prerequisites**:
    *   Python 3.7+

*   **Clone the Repository (if you haven't already)**:
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

*   **Configure the Agent**:
    *   Open `agent/main.py`.
    *   Update the following variables with your Factorio server's RCON details:
        ```python
        factorio_server_host = "127.0.0.1"  # Or your server's IP if remote
        factorio_rcon_port = 27015          # Must match server-settings.json
        factorio_rcon_password = "YOUR_RCON_PASSWORD" # Must match server-settings.json
        ```

*   **Run the Agent**:
    ```bash
    python agent/main.py
    ```
    If everything is set up correctly, the agent will connect to the server, request player information using the mod, and print it to the console.

## Future Development
*   Implement more Lua functions for detailed game state queries (e.g., entity locations, research progress).
*   Develop Lua functions to send commands to the game (e.g., move player, place entity, select recipe).
*   Build out the Python agent's decision-making logic, potentially integrating with AI models like Gemini.
*   Explore multi-agent scenarios.
```
