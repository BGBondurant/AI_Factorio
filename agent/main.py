import json
import re
from mcrcon import MCRcon

class FactorioRCONClient:
    def __init__(self, host, port, password):
        self.host = host
        self.port = port
        self.password = password
        self.rcon = MCRcon(self.host, self.password, port=self.port)

    def connect(self):
        try:
            self.rcon.connect()
            print(f"Successfully connected to Factorio server at {self.host}:{self.port}")
        except Exception as e:
            print(f"Failed to connect to RCON: {e}")
            raise

    def disconnect(self):
        try:
            self.rcon.disconnect()
            print("Disconnected from RCON.")
        except Exception as e:
            print(f"Error during RCON disconnect: {e}")

    def _execute_command(self, command):
        if not self.rcon.socket: # Check if socket is alive, mcrcon doesn't have a public is_connected
            print("RCON not connected. Attempting to reconnect...")
            self.connect()
            if not self.rcon.socket:
                raise ConnectionError("RCON reconnection failed.")

        try:
            print(f"Sending command: {command}")
            response = self.rcon.command(command)
            print(f"Raw RCON response: {response}")
            return response
        except Exception as e:
            print(f"Error executing RCON command '{command}': {e}")
            # Attempt to determine if the connection was lost
            if "Broken pipe" in str(e) or "Connection reset" in str(e) or "Not connected" in str(e):
                print("Connection lost. Will attempt to reconnect on next command.")
                try:
                    self.rcon.disconnect() # Clean up old socket
                except:
                    pass # Ignore errors during cleanup
            raise

    def get_player_info(self):
        """
        Calls the get_player_info function in the Lua mod and parses the JSON response.
        The Lua command is designed to print the JSON string to the console.
        Example Lua command: /silent-command game.print(remote.call("factorio_autonomo_bot", "get_player_info"))
        """
        # Command to make Lua mod print the JSON to console
        lua_command_to_execute = 'game.print(remote.call("factorio_autonomo_bot", "get_player_info"))'
        # Use /c or /command for general commands, /silent-command to avoid chat output if it's a command.
        # For game.print, /script or /silent-command is appropriate.
        # /sc is a shortcut for /silent-command
        rcon_command = f"/sc {lua_command_to_execute}"

        try:
            raw_response = self._execute_command(rcon_command)

            # The raw_response from mcrcon for a game.print might be just the printed string.
            # Or it might have prefixes like [LUA] or [PRINT].
            # We need to extract the JSON part.
            # Assuming the JSON string is the primary content of the response.
            # A simple heuristic: find the first '{' and last '}'

            json_match = re.search(r'\{.*\}', raw_response)
            if json_match:
                json_str = json_match.group(0)
                try:
                    data = json.loads(json_str)
                    return data
                except json.JSONDecodeError as e:
                    print(f"Failed to decode JSON: {e}")
                    print(f"Received string that failed parsing: '{json_str}'")
                    return None
            else:
                print(f"Could not find JSON in response: '{raw_response}'")
                return None

        except ConnectionError as e:
            print(f"RCON Connection error: {e}")
            return None
        except Exception as e:
            print(f"An unexpected error occurred while getting player info: {e}")
            return None

def main():
    # --- Configuration ---
    # IMPORTANT: Replace with your Factorio server's RCON details
    # These are placeholders and will likely not work.
    factorio_server_host = "127.0.0.1"  # Or your server's IP address
    factorio_rcon_port = 27015          # Default Factorio RCON port
    factorio_rcon_password = "YOUR_RCON_PASSWORD" # Set this in server-settings.json

    print("Factorio Autonomo-Bot Agent")
    print("---------------------------")
    print(f"Attempting to connect to Factorio server at {factorio_server_host}:{factorio_rcon_port}...")

    # It's good practice to load password from env or config file in a real app
    if factorio_rcon_password == "YOUR_RCON_PASSWORD":
        print("\nWARNING: Please update 'factorio_rcon_password' in main.py with your actual RCON password.")
        print("The script will likely fail to connect without the correct password.\n")
        # return # Optionally exit if password not set, or let it try and fail.

    client = FactorioRCONClient(factorio_server_host, factorio_rcon_port, factorio_rcon_password)

    try:
        client.connect() # Initial connection attempt

        player_data = client.get_player_info()

        if player_data:
            print("\n--- Player Information ---")
            if "error" in player_data:
                print(f"Error from mod: {player_data['error']}")
            else:
                position = player_data.get("position", {})
                inventory = player_data.get("inventory", {})
                health = player_data.get("health")
                tick = player_data.get("tick")

                print(f"  Position: X={position.get('x', 'N/A')}, Y={position.get('y', 'N/A')}")
                print(f"  Health: {health if health is not None else 'N/A'}")
                print(f"  Game Tick: {tick if tick is not None else 'N/A'}")
                print("  Inventory:")
                if inventory:
                    for item, count in inventory.items():
                        print(f"    - {item}: {count}")
                else:
                    print("    Inventory is empty or not available.")
        else:
            print("\nFailed to retrieve player information.")
            print("Check server logs and ensure the mod 'factorio_autonomo_bot' is running correctly.")
            print("Ensure RCON is enabled on the Factorio server and credentials are correct.")

    except ConnectionError as e: # Catch connection errors specifically from connect()
        print(f"Could not establish initial RCON connection: {e}")
        print("Please ensure your Factorio server is running, RCON is enabled,")
        print("and the host, port, and password in main.py are correct.")
    except Exception as e:
        print(f"An unexpected error occurred in main: {e}")
    finally:
        if client.rcon.socket: # Check if connection was ever made
             client.disconnect()

if __name__ == "__main__":
    main()
