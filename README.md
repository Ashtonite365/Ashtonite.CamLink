# Ashtonite.CamLink

**A multi-camera spectator system for Orion Drift, by Ashtonite365.**

CamLink lets several spectators work as one camera crew. One person flies the **Center** camera, a smooth free cam that can also lock onto a player's head. Everyone else runs a **Side** camera linked to any spectator in the server. A Side camera holds a left or right position beside that spectator, can predict where they're going so it doesn't lag, and in **hair mode** becomes a spring-damped link in a chain of cameras that gets looser toward the tail.

> **Licence:** CamLink is MIT-licensed (see [LICENSE](LICENSE)). Its free cam controls are credited to August ProCam as inspiration, and no ProCam code is included. The author should check ProCam's licence terms to confirm nothing further is needed.

> **Status:** version 1.0.4 compiles with `luau-compile`. It has **not yet been tested in game.**

---

## Install
1. Download `Ashtonite.CamLink.luau`.
2. Put it in `Documents\Another-Axiom\A2\Cameras\Behaviors\`.
3. Restart Orion Drift. (Scripts added while the game is running don't load until a restart.)
4. In the spectator client, open the Cameras panel (**F2**) and activate **Ashtonite.CamLink**. Its settings panel shows `build: v1.0.4`.

## Features

### Roles
Choose **Center camera** or **Side camera** at the top of the panel.

### Center camera: free cam
- Smooth acceleration and braking, eased look, a cruise speed you set with the scroll wheel, Shift to boost, Ctrl to go slow, roll, and field of view on keys.
- **Mouse look** works by default: just move the mouse. An optional "Hold right mouse to look" setting is off by default.
- **Gamepad support**: left stick to move, right stick to look, triggers for down/up, shoulder buttons to roll, D-pad for field of view, and left-stick click to boost.
- **Align to gravity** (checkbox, on by default): turning left/right happens around the local gravity's "up", pitch stops just short of straight up/down, and the horizon slowly levels itself to gravity when you aren't rolling. Separately, **R** levels the horizon at any time and holding **Alt** makes up/down movement follow gravity instead of the camera's own up.

### Center camera: player head link
- A **Player** dropdown lists the players in the current match (players, not spectators). Pick **None / Free cam** to detach.
- **Stare & follow** (default): the rest point is **behind the player's head**. It's the head position minus the head's facing, levelled to horizontal, × distance (80 cm by default), at head height plus a small height offset (5 cm by default). The camera trails that point with a slight springy lag and **always aims at the head's position**, never where the player is facing. Pitch and vertical speed are ignored, so it doesn't drift overhead. Z/C rolls and R levels.
  - **Rigidity-controlled springs:** the pull back behind the head (horizontal) and the hold on head height (vertical) are separate springs with no overshoot. Their strength is the hair-mode rigidity (base stiffness) times a multiplier for each.
  - **Leash:** a hard cap (3 m by default) on how far the camera can lag behind its rest point.
- **First-person (on head):** the camera sits on the player's head with a small forward/side offset, and their head model is hidden.
- **Just behind head:** a fixed spot behind and above the head, with a small velocity-based lead.
- **Follow head rotation** (First-person and Just behind head only): use the head's rotation, or turn it off and look around freely with the mouse or stick.

### Side camera
- **Link to any spectator** in the server, picked from a live list. It can be the Center camera or any other camera.
- **Left / Right** placement, plus side, height and forward offsets and a toe-in angle. The camera uses the linked spectator's rotation.
- **Predictive follow:** CamLink estimates the linked spectator's velocity from their replicated position and places you ahead by that velocity × (lead time + their reported ping, optional). That way you move with them instead of trailing a network update behind.

### Hair mode (Side camera)
- Instead of a rigid offset, the camera hangs off its link on a **damped spring**: a ragdoll-like "hair" chain made of cameras. Each spectator's camera is one link. CamLink doesn't simulate any separate segments.
- **Primary / secondary chain:** the Center camera is the primary (the top of the chain). Each Side camera works out its depth by walking from the spectator it's linked to, to the nearest spectator within a search radius, and so on up to the top. Depth updates every second and whenever the link changes, and you can also set it by hand.
- **Rigidity falls off down the chain:** stiffness = base × falloff^(depth − 1), with a minimum, so links near the primary are stiff and the tail is looser.

### Floor rest (no bounce)
A ray cast along gravity stops the camera from going through the floor. On contact it's held just above the surface, any into-floor speed is removed and sliding is strongly damped. Nothing bounces back; it settles and stays put. This works in both roles and can be switched off.

### Settings
Only saved when you press **Save settings** while CamLink is the active camera. **Reset to defaults** restores the defaults without saving.

## Controls (Center camera)

| Action | Keyboard / mouse | Gamepad |
|---|---|---|
| Move | W A S D | Left stick |
| Down / up | Q / E | Left / right trigger |
| Look | Move the mouse (or hold RMB, if that setting is on) | Right stick |
| Boost / slow | Hold Shift / hold Ctrl | Left stick click (boost) |
| Cruise speed | Scroll wheel | - |
| Roll left / right | Z / C | Left / right shoulder |
| Level horizon | R | Right stick click |
| Field of view | - / = | D-pad down / up |
| Move along gravity | Hold Alt | - |

Side cameras are driven by their link and the panel; they don't use movement keys.

## Settings overview

| Group | Settings (defaults) |
|---|---|
| Free cam | Cruise speed (800 cm/s), Acceleration time (0.18 s), Boost (×3), Slow (×0.25), Mouse sensitivity (3.6), Hold right mouse to look (off), Stick look (140°/s), Look smoothing (0.06 s), Roll rate (60°/s), FOV (90), Align to gravity (on), Rest on floor (on) |
| Head link | Player (None), Placement (Stare & follow), Distance (80 cm), Height above head (5 cm), Behind-head pull × rigidity (0.5), Height hold × rigidity (1.0), Leash (300 cm), Follow head rotation (on), Behind distance / height / lead, First-person forward offset, Side offset, Smoothing |
| Side link | Linked camera, Left / Right (Right), Side offset (150 cm), Height and forward offsets, Toe-in, Position smoothing (0.05 s), FOV, Rest on floor |
| Predictive | On, Lead time (0.10 s), Add linked spectator's ping (on) |
| Hair mode | Off, Base stiffness / rigidity (120), Falloff per link (0.7), Min stiffness (8), Damping ratio (0.9), Chain search radius (600 cm), Depth override (0 = auto) |

## Limitations
- **Chain depth is inferred.** Scripts can see other spectators' positions but not which camera each one is linked to, so depth is a nearest-spectator guess. You can override it in the panel.
- **Velocity is estimated** from replicated spectator positions, which arrive at an unknown network rate, so predictive follow is an approximation.
- Other spectators' field of view can't be read, so Side cameras use their own FOV setting.
- With mouse look always on, moving the cursor over the settings panel also turns the free cam.
- **Not yet tested in game.** Please report issues.

## Credits & Acknowledgments
- **August ProCam** (the `august.procam` camera by August): inspiration for CamLink's free cam movement and controls. **No ProCam code is included.** The free cam was written from scratch using common free-cam conventions and Orion Drift's built-in free cam documentation.
- Developed by **Ashtonite365** with AI assistance (Grok Bot agents).
- This product is not affiliated with Another Axiom Inc. or its videogames Gorilla Tag and Orion Drift and is not endorsed or otherwise sponsored by Another Axiom. Portions of the materials contained herein are property of Another Axiom. ©2025 Another Axiom Inc. See [NOTICE](NOTICE).

## Licence
MIT © 2026 Ashtonite365. See [LICENSE](LICENSE).
