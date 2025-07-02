# Factorio Autonomo-Bot (Factorio 2.0 / Space Age Compatible)

This package contains the Factorio Autonomo-Bot, a mod designed for **Factorio 2.0 and the Space Age expansion**. It allows an AI agent to control a player in Factorio, and includes the Python-based AI agent itself.

**Mod Version**: 0.3.0 (or newer compatible versions)
**Factorio Version**: 2.0+
**Required Dependencies**: Base Game (2.0+), Space Age Expansion

## Installation Options

You have two primary ways to use this package:

1.  **Simple Mod-Only Installation**: If you only want to use the in-game mod features (e.g., for other scripts or manual RCON commands) without the AI agent.
2.  **Advanced - Connecting the AI Agent**: If you want the full AI-driven experience.

---

## 1. Simple Installation (Mod Only)

This setup allows the Factorio Autonomo-Bot mod to run in your game, providing an RCON interface that can be used by external tools or for manual command testing. The Python AI agent will **not** be active in this setup.

**Steps:**

1.  **Download the Mod Package**:
    *   You should have a `.zip` file or a folder containing this `README.md` and two sub-folders:
        *   `Factorio_Autonomo-Bot_Mod/`
        *   `Python_Agent/`

2.  **Locate Your Factorio Mods Directory**:
    *   The location depends on your operating system:
        *   **Windows**: `%APPDATA%\Factorio\mods`
        *   **Linux**: `~/.factorio/mods`
        *   **macOS**: `~/Library/Application Support/factorio/mods`
    *   If the `mods` directory doesn't exist, run Factorio once to create it.

3.  **Install the Mod**:
    *   Navigate to the `Factorio_Autonomo-Bot_Mod/` folder from the downloaded package.
    *   Inside, you'll find a folder named `factorio_autonomo_bot_v0.3.0` (or the version you downloaded). This is the actual mod folder.
    *   **Copy** this `factorio_autonomo_bot_v0.3.0` folder into your Factorio `mods` directory.

4.  **Enable the Mod in Factorio**:
    *   Launch Factorio 2.0 (with the Space Age expansion).
    *   Go to "Mods" from the main menu.
    *   Find "Factorio Autonomo-Bot Controller (Factorio 2.0 / Space Age Compatible)" in the list and make sure it's enabled.
    *   The mod version should match (e.g., 0.3.0).
    *   Ensure the "Space Age" dependency is also enabled (this should happen automatically if listed correctly in `info.json`).
    *   Factorio might need to restart.

5.  **Usage**:
    *   Start a new game (ensure Space Age content is active if applicable to your scenario) or load an existing one.
    *   The mod is now active and provides RCON functions.

---

## 2. Advanced - Connecting the AI Agent

This setup enables the Python-based AI agent to connect to the Factorio mod (running in Factorio 2.0 with Space Age), observe the game, make decisions using Google's Gemini AI, and control the player character.

**Prerequisites:**

*   You have completed the "Simple Installation (Mod Only)" steps above. The mod **must be version 0.3.0 or newer** for Factorio 2.0 compatibility.
*   Python 3.7+ installed on your system.
*   Your Factorio server must be running **Factorio 2.0 with the Space Age expansion** and RCON enabled.
    *   In `server-settings.json` (usually in `factorio/data/` or your user data directory for dedicated servers), ensure `rcon_port` is set and you have a strong `rcon_password`.
    *   Example `server-settings.json` snippet:
        ```json
        {
          "rcon_port": 27015,
          "rcon_password": "your_very_secure_password"
        }
        ```

**Steps:**

1.  **Navigate to the Python Agent Directory**:
    *   In the downloaded package, find the `Python_Agent/` folder. This is where you'll work for the agent setup.

2.  **Create a Virtual Environment (Recommended)**:
    *   Open a terminal or command prompt in the `Python_Agent/` directory.
    *   Run:
        ```bash
        python -m venv venv
        ```
    *   Activate the virtual environment:
        *   **Windows (cmd.exe)**: `venv\Scripts\activate.bat`
        *   **Windows (PowerShell)**: `venv\Scripts\Activate.ps1`
        *   **Linux/macOS (bash/zsh)**: `source venv/bin/activate`

3.  **Install Dependencies**:
    *   With the virtual environment active, install the required Python libraries:
        ```bash
        pip install -r requirements.txt
        ```

4.  **Set Environment Variables**:
    *   The Python agent requires sensitive information to be set as environment variables. **Do not hardcode these into the script.**
    *   **`FACTORIO_RCON_PASSWORD`**: The RCON password you set in your Factorio server's `server-settings.json`.
    *   **`GEMINI_API_KEY`**: Your API key for the Google Gemini service (obtained from Google AI Studio or Google Cloud).

    *   **How to set environment variables (examples):**
        *   **Linux/macOS (temporary for current session)**:
            ```bash
            export FACTORIO_RCON_PASSWORD="your_very_secure_password"
            export GEMINI_API_KEY="your_gemini_api_key"
            ```
        *   **Windows (Command Prompt - temporary for current session)**:
            ```cmd
            set FACTORIO_RCON_PASSWORD="your_very_secure_password"
            set GEMINI_API_KEY="your_gemini_api_key"
            ```
        *   **Windows (PowerShell - temporary for current session)**:
            ```powershell
            $env:FACTORIO_RCON_PASSWORD="your_very_secure_password"
            $env:GEMINI_API_KEY="your_gemini_api_key"
            ```
        *   For persistent settings, consider adding these to your shell's profile script (e.g., `.bashrc`, `.zshrc`) or using system environment variable settings.
        *   You can also set `FACTORIO_HOST` (defaults to `127.0.0.1`) and `FACTORIO_RCON_PORT` (defaults to `27015`) if your server is not local or uses a different port.

5.  **Run the Python Agent**:
    *   Ensure your Factorio game/server is running with the mod enabled.
    *   In your terminal (still in the `Python_Agent/` directory with the virtual environment active), run the main script:
        ```bash
        python main.py
        ```

6.  **Observe**:
    *   The agent will attempt to connect to the Factorio RCON server.
    *   You'll see log messages in the console as it performs actions: SENSE (gathering info), THINK (querying Gemini AI), and ACT (sending commands to the game).
    *   The player character in Factorio should start moving and interacting with the game world based on the AI's decisions.

### RCON Command Examples (for reference or testing mod functionality)

These are the types of commands the Python agent sends. You can also use them manually via an RCON tool or the in-game console (`/sc <command>`) if you want to test the mod's functions directly.

*   **Get Player Info**:
    `/sc game.print(remote.call("factorio_autonomo_bot", "get_player_info"))`
*   **Start Pathfinding (e.g., to x=10, y=20)**:
    `/sc game.print(remote.call("factorio_autonomo_bot", "start_pathfinding_to", {x=10, y=20}))`
*   **Get Movement Status**:
    `/sc game.print(remote.call("factorio_autonomo_bot", "get_movement_status"))`
*   **Scan Nearby Entities (e.g., radius 32)**:
    `/sc game.print(remote.call("factorio_autonomo_bot", "scan_nearby_entities", {radius=32}))`
*   **Get All Unlocked Recipes**:
    `/sc game.print(remote.call("factorio_autonomo_bot", "get_all_unlocked_recipes"))`
*   **Mine Target Entity (e.g., entity with unit_number 123)**:
    `/sc game.print(remote.call("factorio_autonomo_bot", "mine_target_entity", {unit_number=123}))`

---

Enjoy using the Factorio Autonomo-Bot!
