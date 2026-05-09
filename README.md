# pickle_wheelv2

**pickle_wheelv2** is a FiveM resource fork based on [Pickle Wheel](https://github.com/PickleModifications/pickle_wheel) that keeps full steering wheel and pedal support and adds an optional **manual transmission** layer: synchronized gears, stall logic, redline engine stress, NUI gear/RPM display, and ox_lib integration.

Use this README when installing or troubleshooting the resource on a fresh server or when replacing an older wheel script.

---

## What you get

- **Wheel & pedals** — Browser-based device capture (no Script Hook / controller emulation required for the wheel UI path), axis deadzone, per-button binds for controls or chat commands, locally saved settings (KVP key `picklewheel`).
- **Manual mode (toggle in UI)** — Shifting with keyboard binds (default `=` / `-`), optional wheel button type `gearshift`, clutch simulation timing, shift animations, passenger/driver gear sync via entity state + server event.
- **Gameplay extras** — Stall when RPM is too low for the gear; prolonged redline can reduce engine health; debug/help commands for admins and testing.

---

## Requirements

| Requirement | Notes |
|-------------|--------|
| **FiveM server** | Standard FXServer deployment. |
| **Game build** | **3095 or newer** on the client for manual gearbox native usage. Older builds may not support the manual gear path reliably (see startup logic in `client.lua`). |
| **[ox_lib](https://github.com/overextended/ox_lib)** | Required (`fxmanifest.lua` lists `ox_lib` as a dependency and loads `@ox_lib/init.lua`). Ensure `ox_lib` starts **before** `pickle_wheelv2`. |
| **Lua 5.4** | Enabled in `fxmanifest.lua` (`lua54 'yes'`). |
| **Multiplayer gear sync** | Uses **entity state** (`gearchange`, etc.) and `pickle-gearbox:server:setGear`. **OneSync** (or equivalent state bag support your stack relies on) is strongly recommended so passengers see the correct gear. |

No framework (QBCore/ESX) is required for the core script.

---

## Installation

1. Copy the resource folder into your server `resources` directory.
2. Name the folder **`pickle_wheelv2`** (or any name you prefer — but keep it consistent everywhere below).
3. In `server.cfg`, ensure order similar to:

   ```cfg
   ensure ox_lib
   ensure pickle_wheelv2
   ```

4. Restart the server or run `ensure pickle_wheelv2` after `ox_lib` is running.

### Replacing another copy of Pickle Wheel

- Remove or disable the old resource (e.g. `pickle_wheel`) so **only one** wheel resource owns NUI focus and control injection.
- Player settings are stored under KVP `picklewheel`; renaming the resource folder does not wipe KVP, but a clean test profile may need to open the UI once and save again.

---

## Usage (players)

1. **Sit in a vehicle** as the driver.
2. Open the panel: **`/wheel`**
3. Choose your device, tune axes/deadzone, bind buttons (including **gearshift** `up` / `down` if you shift from the wheel).
4. Toggle **Manual** in the UI when you want manual mode (vehicle handling must support it — see below).
5. **Save settings** before closing.

Disable continuous wheel→game mapping without closing the panel logic entirely: **`/wheeloff`**

Quick help in chat: **`/pickle_help`**

---

## Manual transmission & vehicles

Manual behavior applies when:

- The player enables **Manual** in the UI, and  
- The vehicle’s handling has the appropriate **advanced flags** so the script detects a manual gearbox (see `vehicleHasFlag` / `strAdvancedFlags` in `client.lua` — manual flag **1024**).

Vehicles without that handling profile will not behave as manuals even if the toggle is on.

---

## Configuration (developers)

Most tuning lives in the **`Config`** table near the top of **`client.lua`**:

- **`Keys.gearUp` / `Keys.gearDown`** — Default shift keys (`EQUALS` / `MINUS`); ox_lib keybinds use these when ox_lib is available.
- **`NotifyManual`**, **`ManualNotificationText`** — Notification when entering a manual-eligible vehicle.
- **`UseServerSideStateSet`** — When `true`, gear changes notify the server (`pickle-gearbox:server:setGear`) so **`Entity(...).state.gearchange`** stays in sync for other clients.
- **`GearCheckSleep`**, **`ClutchTime`** — Passenger/driver resync interval and clutch delay feel.

Debug logging for deep troubleshooting: set **`useDebug = true`** at the top of `client.lua` (very verbose; turn off on production).

---

## Commands reference

| Command | Purpose |
|---------|---------|
| `/wheel` | Open wheel/manual UI (must be in a vehicle). |
| `/wheeloff` | Stop applying wheel axis mapping to controls. |
| `/pickle_help` | Short usage and debug command hints. |
| `/pickle_test` | Quick “loaded” status in chat. |
| `/pickle_debug` | Manual/gear/RPM/flags snapshot (in vehicle). |
| `/resetgear` | Reset internal gear state (may need re-enter vehicle). |
| `/force_gear [n]` | Force gear index for testing (driver, in vehicle). |
| `/engine_debug` | Engine health / redline timing info. |
| `/stall_debug` | Stall system state. |
| `/force_stall` | Force a stall (manual enabled). |
| `/toggle_stall_system` | Toggle stall grace behavior (testing). |

---

## Technical notes

- **Resource display name** in `fxmanifest.lua` is `Pickle Wheel Enhanced` / version `2.0.0`; the **repository and folder name** for this fork is **`pickle_wheelv2`**.
- **Server script** (`server.lua`) only registers `pickle-gearbox:server:setGear` to mirror gear to state bags — keep `server.lua` enabled for multiplayer sync when `UseServerSideStateSet` is true.
- **NUI** loads jQuery from CDN (`nui/index.html`). If your server blocks outbound HTTPS from clients, host jQuery locally and update the script tag.
- **Performance**: wheel mapping runs `Wait(0)` while `wheelActive` is true (same pattern as typical input forwarding). Toggle **`/wheeloff`** when not using a wheel to reduce idle cost.

---

## Credits

- Original **Pickle Wheel** concept and wheel stack — [PickleModifications](https://github.com/PickleModifications/pickle_wheel) / [picklemods.com](https://picklemods.com/).
- Wheel & pedal gamepad API reference — [Spendibus prototype snippet](http://spenibus.net/b/p/F/PC-steering-wheel-viewer-prototype-in-html-javascript).
- **pickle_wheelv2** — community fork combining enhanced manual transmission behavior with the Pickle Wheel UI.

---

## Support

This README documents **pickle_wheelv2** as shipped in this repo. For the original Pickle Wheel product line and vendor support, see [picklemods.com](https://picklemods.com/).
