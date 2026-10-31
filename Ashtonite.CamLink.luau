-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Ashtonite365
-- @name Ashtonite.CamLink
-- @version 1.0.4
-- @author Ashtonite365
-- @credits Developed with AI assistance (Grok Bot agents). Free cam controls inspired by August ProCam (no ProCam code included).
-- Unofficial community spectator camera script for Orion Drift.
-- Licence: MIT, see LICENSE.
-- This product is not affiliated with Another Axiom Inc. or its videogames Gorilla Tag and Orion Drift and is not endorsed or otherwise sponsored by Another Axiom. Portions of the materials contained herein are property of Another Axiom. ©2025 Another Axiom Inc.

-- CamLink: a multi-camera rig. One spectator flies the Center camera (free cam); other spectators
-- pick Side, link to any spectator in the server and hold a left/right offset beside them,
-- optionally extrapolating the linked spectator's motion (Predictive).

metadata = {
	name = "Ashtonite.CamLink",
	description = "Multi-camera rig: Center free cam or Side camera linked to another spectator",
	author = "Ashtonite365",
	defaultKeybind = "",
}

local VERSION = "1.0.4"
local K = Input.Key
local G = Input.Gamepad

-- ---------------------------------------------------------------- settings
local DEFAULTS = {
	role = "center",          -- "center" | "side"
	-- center (free cam)
	moveSpeed = 800,          -- cm/s cruise
	accelTime = 0.18,         -- s to reach ~63% of target speed
	boostMul = 3.0,
	slowMul = 0.25,
	mouseSens = 3.6,          -- degrees per getMouseDelta unit (official freecam default is 3.6)
	mouseLookHold = false,    -- true = only look while right mouse is held
	padLookRate = 140,        -- degrees per second at full stick
	lookSmooth = 0.06,        -- s, rotation easing time constant
	rollRate = 60,            -- degrees per second
	fov = 90,
	fovRate = 30,             -- degrees per second
	gravityAlign = true,
	-- center: attach to a player's head ("" = free cam)
	headPlayer = "",
	headMode = "stare",       -- "stare" (stare & follow) | "first" (on the head) | "behind" (just behind the head)
	stareHeight = 5,          -- cm above head height in stare mode
	stareDist = 80,           -- cm from the head in stare mode
	stareTightness = 0.5,     -- multiplier on the hair rigidity for the horizontal pull back behind the head
	stareHeightHold = 1.0,    -- multiplier on the hair rigidity for holding head height
	stareLeash = 300,         -- cm: hard cap on how far the camera may lag from its rest point
	headBack = 60,            -- cm behind the head (behind mode)
	headUp = 15,              -- cm above the head (behind mode)
	headSide = 0,             -- cm to the right (negative = left)
	headForward = 5,          -- cm in front of the eyes (first-person mode)
	headFollowRot = true,     -- true = view follows the head's rotation, false = free look
	headLead = 0.05,          -- s of predictive lead from the player's velocity (behind mode)
	headSmooth = 0.03,        -- s position easing
	floorRest = true,         -- settle softly on the floor, no bounce
	-- side
	linkName = "",
	side = "right",           -- "left" | "right"
	sideOffset = 150,         -- cm sideways
	heightOffset = 0,         -- cm up
	forwardOffset = 0,        -- cm forward
	toeIn = 0,                -- degrees turned toward the linked camera's view line
	predictive = true,
	leadTime = 0.10,          -- s extra extrapolation
	addPing = true,           -- add the linked spectator's reported ping to lead time
	followSmooth = 0.05,      -- s position easing
	-- hair mode (side): spring follow whose stiffness falls off with chain depth
	hairMode = false,
	hairStiffness = 120,      -- 1/s^2 spring strength for the first link (depth 1)
	hairFalloff = 0.7,        -- multiplier per extra link down the chain
	hairMinStiffness = 8,     -- floor
	hairDamping = 0.9,        -- damping ratio (1 = critical; below 1 is looser, never springs past 1.2)
	chainRadius = 600,        -- cm: how near a spectator must be to count as the next link up
	depthOverride = 0,        -- 0 = auto-detect, otherwise force this depth
}

local settings = {}
local function loadSettings()
	local c = (type(config) == "table") and config or {}
	for k, d in pairs(DEFAULTS) do
		local v = c[k]
		if v == nil or type(v) ~= type(d) then v = d end
		settings[k] = v
	end
end
loadSettings()

local statusMsg = ""
local function save()
	if not camera.isActive then
		statusMsg = "Save needs this camera to be active"
		return
	end
	local out = {}
	for k in pairs(DEFAULTS) do out[k] = settings[k] end
	config = out
	local ok = saveConfig()
	statusMsg = ok and "Saved" or "Save failed"
end

-- ---------------------------------------------------------------- helpers
local function ease(dt, tau)
	if tau <= 0 then return 1 end
	return 1 - math.exp(-dt / tau)
end

local function worldUp()
	if gravity and gravity.strength ~= 0 then return gravity.upDirection end
	return Vec3.upVector
end


-- Floor rest: zero restitution. If pos would sink into the floor (ray along gravity), clamp it to
-- the surface plus a small gap, remove the into-floor velocity and strongly damp the sliding part.
-- Nothing is reflected, so the camera settles and stays put instead of bouncing.
local FLOOR_GAP = 15      -- cm kept above the surface
local FLOOR_PROBE = 60    -- cm ray start above pos
local FLOOR_FRICTION = 0.04 -- s, tangential damping time constant while in contact
local function restOnFloor(pos, vel, dt)
	local up = worldUp()
	local hit = camera:castRay(pos + up * FLOOR_PROBE, pos - up * FLOOR_GAP)
	if hit == nil or not hit.successful then return pos, vel, false end
	local h = (pos - hit.position):dot(up)
	if h >= FLOOR_GAP then return pos, vel, false end
	pos = pos + up * (FLOOR_GAP - h)
	local vn = vel:dot(up)
	if vn < 0 then vel = vel - up * vn end
	local vt = vel - up * math.max(vel:dot(up), 0)
	vel = vel - vt * ease(dt, FLOOR_FRICTION)
	return pos, vel, true
end

local function liveFrame()
	local frames = getAllGameData()
	if frames == nil or #frames < 1 then return nil end
	return frames[1]
end

-- ---------------------------------------------------------------- center: free cam
-- Orientation is kept as an orthonormal basis (fwd, up) and turned with rotateAngleAxis (degrees).
local fc = {
	pos = Vec3.zeroVector,
	vel = Vec3.zeroVector,
	fwd = Vec3.forwardVector,
	up = Vec3.upVector,
	tFwd = Vec3.forwardVector, -- target basis (input applied here), eased into fwd/up
	tUp = Vec3.upVector,
	fov = 90,
	ready = false,
}

local function orthoUp(f, u)
	local r = u:cross(f)
	if r:length() < 1e-4 then return u end
	return f:cross(r:getSafeNormal()):getSafeNormal()
end

local function fcInitFrom(pos, rot)
	fc.pos = pos
	fc.vel = Vec3.zeroVector
	fc.fwd = rot:getForwardVector()
	fc.up = rot:getUpVector()
	fc.tFwd, fc.tUp = fc.fwd, fc.up
	fc.fov = settings.fov
	fc.ready = true
end

local function axis(pos, neg)
	return (Input.getKey(pos) and 1 or 0) - (Input.getKey(neg) and 1 or 0)
end

local head = { id = nil, pos = nil, vel = Vec3.zeroVector, dir = nil, roll = 0, lost = false }

local function listPlayers()
	local fr = liveFrame()
	if fr == nil or fr.players == nil then return {} end
	return fr.players
end

local function findHeadPlayer()
	if settings.headPlayer == "" then return nil end
	local ps = listPlayers()
	for i = 1, #ps do
		local p = ps[i]
		if (head.id ~= nil and p.playerId == head.id) or (head.id == nil and p.playerName == settings.headPlayer) then
			head.id = p.playerId
			return p
		end
	end
	return nil
end

-- Attach the free cam to a player's head (ReplayPlayer.head). Returns true if it placed the camera.
local function attachToHead(dt)
	local p = findHeadPlayer()
	if p == nil or p.head == nil then
		head.lost = settings.headPlayer ~= ""
		return false
	end
	head.lost = false
	local s = settings
	local hp, hr = p.head.position, p.head.rotation
	local hf, hu, hrt = hr:getForwardVector(), hr:getUpVector(), hr:getRightVector()
	local vel = p.velocity or Vec3.zeroVector
	local want
	if s.headMode == "stare" then
		-- position: behind the player's back, horizontally only (gravity up; pitch and vertical speed ignored)
		local up0 = worldUp()
		local function flat(v) return v - up0 * v:dot(up0) end
		-- anchor = head position; 'behind' = opposite the head's yaw (facing flattened to horizontal).
		-- Fallbacks if the head is looking straight up/down: horizontal movement direction, then last known.
		local target
		local hfFlat = flat(hf)
		local mv = flat(vel)
		if hfFlat:length() > 0.2 then
			target = -hfFlat:getSafeNormal()
		elseif mv:length() > 50 then
			target = -mv:getSafeNormal()
		elseif head.dir ~= nil then
			target = head.dir
		else
			target = flat(Vec3.backwardVector):getSafeNormal()
		end
		head.dir = head.dir or target
		local cur = flat(head.dir)
		if cur:length() < 0.01 then cur = target end
		head.dir = cur:getSafeNormal():lerp(target, ease(dt, 0.35)):getSafeNormal()
		if head.dir:length() < 0.01 then head.dir = target end
		want = hp + head.dir * s.stareDist + up0 * s.stareHeight + hrt * s.headSide
		if head.pos == nil or (want - head.pos):length() > 3000 then
			head.pos, head.vel = want, vel
		else
			-- critically damped spring: tight follow with a slight lag, no overshoot
			-- spring strength comes from the hair rigidity system: the Center camera is the primary
			-- (depth 0), so it uses the base stiffness. Separate horizontal and vertical springs,
			-- each critically damped (no overshoot). Higher rigidity = holds position harder, lower = more lag.
			local kH = math.max(s.hairStiffness * s.stareTightness, 0.25)
			local kV = math.max(s.hairStiffness * s.stareHeightHold, 0.25)
			local err, dv = want - head.pos, vel - head.vel
			local errV, dvV = up0 * err:dot(up0), up0 * dv:dot(up0)
			local acc = (err - errV) * kH + (dv - dvV) * (2 * math.sqrt(kH))
				+ errV * kV + dvV * (2 * math.sqrt(kV))
			head.vel = head.vel + acc * dt
			head.pos = head.pos + head.vel * dt
			-- leash: never lag further than stareLeash from the rest point
			local off = head.pos - want
			if off:length() > s.stareLeash then
				head.pos = want + off:getSafeNormal() * s.stareLeash
				local out = off:getSafeNormal()
				local vo = (head.vel - vel):dot(out)
				if vo > 0 then head.vel = head.vel - out * vo end
			end
		end
		if s.floorRest then head.pos, head.vel = restOnFloor(head.pos, head.vel, dt) end
		-- aim: look-at from the camera to the head POSITION (head rotation is never used for aim here); horizon level unless rolled with Z/C (R levels)
		head.roll += (axis(K.C, K.Z) * s.rollRate) * dt
		if Input.getKeyDown(K.R) then head.roll = 0 end
		local f = (hp - head.pos):getSafeNormal()
		local u = orthoUp(f, worldUp())
		if head.roll ~= 0 then u = u:rotateAngleAxis(head.roll, f) end
		fc.pos, fc.vel = head.pos, head.vel
		fc.fwd, fc.up, fc.tFwd, fc.tUp = f, u, f, u
		camera.hideNearestHead = false
		return true
	elseif s.headMode == "first" then
		want = hp + hf * s.headForward + hrt * s.headSide
	else
		local up = worldUp()
		local back = hf - up * hf:dot(up) -- flattened, so looking down doesn't swing the camera overhead
		if back:length() < 0.01 then back = hf end
		back = back:getSafeNormal()
		want = hp + vel * s.headLead - back * s.headBack + up * s.headUp + hrt * s.headSide
	end
	if head.pos == nil or (want - head.pos):length() > 3000 then
		head.pos = want
	else
		head.pos = head.pos:lerp(want, ease(dt, s.headSmooth))
	end
	if s.floorRest then head.pos, vel = restOnFloor(head.pos, vel, dt) end
	fc.pos, fc.vel = head.pos, vel
	if s.headFollowRot then
		fc.fwd, fc.up, fc.tFwd, fc.tUp = hf, hu, hf, hu
	end
	camera.hideNearestHead = (s.headMode == "first")
	return true
end

local function tickCenter(dt)
	if not fc.ready then fcInitFrom(camera.position, camera.rotation) end
	local s = settings

	-- look: mouse while RMB held, plus right stick
	local yaw, pitch, roll = 0, 0, 0
	if not s.mouseLookHold or Input.getKey(K.RightMouseButton) then
		local md = Input.getMouseDelta()
		if md and md.x then
			yaw += md.x * s.mouseSens
			pitch += md.y * s.mouseSens -- +y = mouse up = look up, same sign as the official freecam
		end
	end
	yaw += Input.getAnalog(G.RightX) * s.padLookRate * dt
	pitch += Input.getAnalog(G.RightY) * s.padLookRate * dt
	roll += (axis(K.C, K.Z) + ((Input.getKey(G.RightShoulder) and 1 or 0) - (Input.getKey(G.LeftShoulder) and 1 or 0))) * s.rollRate * dt

	local tf, tu = fc.tFwd, fc.tUp
	if yaw ~= 0 then
		local yawAxis = s.gravityAlign and worldUp() or tu
		tf = tf:rotateAngleAxis(yaw, yawAxis)
		tu = tu:rotateAngleAxis(yaw, yawAxis)
	end
	if pitch ~= 0 then
		local right = tu:cross(tf):getSafeNormal()
		local nf = tf:rotateAngleAxis(-pitch, right)
		-- stop pitching through straight up/down when gravity aligned
		if not s.gravityAlign or math.abs(nf:dot(worldUp())) < 0.985 then
			tf = nf
			tu = tu:rotateAngleAxis(-pitch, right)
		end
	end
	if roll ~= 0 then tu = tu:rotateAngleAxis(roll, tf) end
	if Input.getKeyDown(K.R) or Input.getKeyDown(G.RightThumbstick) then
		tu = worldUp() -- level the horizon
	end
	if s.gravityAlign and roll == 0 then
		-- drift the up vector back toward gravity's up, faster while the user is turning
		local turn = math.min(1, (math.abs(yaw) + math.abs(pitch)) * 0.2)
		tu = tu:lerp(worldUp(), ease(dt, 1.5) * (0.3 + turn))
	end
	tu = orthoUp(tf:getSafeNormal(), tu)
	fc.tFwd, fc.tUp = tf:getSafeNormal(), tu

	local a = ease(dt, s.lookSmooth)
	fc.fwd = fc.fwd:lerp(fc.tFwd, a):getSafeNormal()
	fc.up = orthoUp(fc.fwd, fc.up:lerp(fc.tUp, a))

	local attached = attachToHead(dt)
	if not attached then
	camera.hideNearestHead = false
	-- speed: wheel scales cruise speed, Shift boost, Ctrl slow
	if Input.getKeyDown(K.MouseScrollUp) then s.moveSpeed = math.min(s.moveSpeed * 1.15, 20000) end
	if Input.getKeyDown(K.MouseScrollDown) then s.moveSpeed = math.max(s.moveSpeed / 1.15, 20) end
	local speed = s.moveSpeed
	if Input.getKey(K.LeftShift) or Input.getKey(G.LeftThumbstick) then speed *= s.boostMul end
	if Input.getKey(K.LeftControl) then speed *= s.slowMul end

	-- move: WASD / left stick on the view plane, Q/E / triggers on the up axis
	local right = fc.up:cross(fc.fwd):getSafeNormal()
	local f = axis(K.W, K.S) + Input.getAnalog(G.LeftY)
	local r = axis(K.D, K.A) + Input.getAnalog(G.LeftX)
	local u = axis(K.E, K.Q) + Input.getAnalog(G.RightTriggerAxis) - Input.getAnalog(G.LeftTriggerAxis)
	local upAxis = Input.getKey(K.LeftAlt) and worldUp() or fc.up
	local wish = fc.fwd * f + right * r + upAxis * u
	if wish:length() > 1 then wish = wish:getSafeNormal() end
	local target = wish * speed
	fc.vel = fc.vel:lerp(target, ease(dt, s.accelTime))
	fc.pos = fc.pos + fc.vel * dt
	if settings.floorRest then fc.pos, fc.vel = restOnFloor(fc.pos, fc.vel, dt) end
	end

	-- FOV: - / = keys, D-pad up/down
	local fovIn = axis(K.Equals, K.Hyphen) + ((Input.getKey(G.DPad_Up) and 1 or 0) - (Input.getKey(G.DPad_Down) and 1 or 0))
	if fovIn ~= 0 then s.fov = math.clamp(s.fov - fovIn * s.fovRate * dt, 10, 140) end
	fc.fov += (s.fov - fc.fov) * ease(dt, 0.12)

	camera.position = fc.pos
	camera.rotation = Quat.fromXZ(fc.fwd, fc.up)
	camera.fieldOfView = fc.fov
end

-- ---------------------------------------------------------------- side: linked camera
local link = {
	id = nil,             -- playerId of the linked spectator in the live frame
	lastPos = nil,
	lastSampleClock = 0,
	vel = Vec3.zeroVector,
	clock = 0,
	pos = nil,
	lost = false,
	hairVel = Vec3.zeroVector,
	depth = 1,
	depthAge = 99,
}

-- Chain depth: the API exposes other spectators' positions but not which camera each one links to,
-- so the chain is inferred: from the linked spectator, repeatedly step to the nearest unvisited
-- spectator within chainRadius (not us). Each step is one link nearer the primary (the top of the
-- chain, which has no nearer spectator). Depth 1 = linked straight to the primary.
local function computeDepth(linked)
	if settings.depthOverride >= 1 then return math.floor(settings.depthOverride) end
	local fr = liveFrame()
	if fr == nil or fr.spectators == nil or linked == nil then return 1 end
	local visited = { [linked.playerId] = true }
	local cur = linked.transform.position
	local depth = 1
	for _ = 1, 32 do
		local best, bestD = nil, settings.chainRadius
		for i = 1, #fr.spectators do
			local sp = fr.spectators[i]
			if not sp.isLocalPlayer and not visited[sp.playerId] then
				local d = (sp.transform.position - cur):length()
				if d < bestD then best, bestD = sp, d end
			end
		end
		if best == nil then break end
		visited[best.playerId] = true
		cur = best.transform.position
		depth += 1
	end
	return depth
end

local function hairStiffness()
	local s = settings
	return math.max(s.hairStiffness * s.hairFalloff ^ (link.depth - 1), s.hairMinStiffness)
end

local function listSpectators()
	local out = {}
	local fr = liveFrame()
	if fr == nil or fr.spectators == nil then return out end
	for i = 1, #fr.spectators do
		local sp = fr.spectators[i]
		if not sp.isLocalPlayer then out[#out + 1] = sp end
	end
	return out
end

local function findLinked()
	local list = listSpectators()
	for i = 1, #list do
		local sp = list[i]
		if (link.id ~= nil and sp.playerId == link.id)
			or (link.id == nil and settings.linkName ~= "" and sp.playerName == settings.linkName) then
			link.id = sp.playerId
			return sp
		end
	end
	return nil
end

local function selectLink(sp)
	link.id = sp.playerId
	settings.linkName = sp.playerName
	link.lastPos, link.pos = nil, nil
	link.vel = Vec3.zeroVector
	link.hairVel = Vec3.zeroVector
	link.depthAge = 99
end

local function tickSide(dt)
	link.clock += dt
	local sp = findLinked()
	if sp == nil then
		link.lost = true
		return -- hold the current view
	end
	link.lost = false
	local tp = sp.transform.position
	local tr = sp.transform.rotation

	-- velocity estimate: only sample when the replicated position actually changes, so frames
	-- without a fresh network update don't read as zero velocity
	if link.lastPos == nil then
		link.lastPos, link.lastSampleClock = tp, link.clock
	elseif (tp - link.lastPos):squaredLength() > 0.0001 then
		local span = link.clock - link.lastSampleClock
		if span > 0 and span < 0.5 then
			local v = (tp - link.lastPos) / span
			link.vel = link.vel:lerp(v, 0.5)
		else
			link.vel = Vec3.zeroVector -- teleport or long gap
		end
		link.lastPos, link.lastSampleClock = tp, link.clock
	elseif link.clock - link.lastSampleClock > 0.5 then
		link.vel = Vec3.zeroVector -- stopped
	end

	local s = settings
	local base = tp
	if s.predictive then
		local lead = (link.clock - link.lastSampleClock) + s.leadTime
		if s.addPing and type(sp.ping) == "number" then lead += math.clamp(sp.ping, 0, 500) / 1000 end
		base = tp + link.vel * math.min(lead, 1)
	end

	local fwd = tr:getForwardVector()
	local up = tr:getUpVector()
	local right = tr:getRightVector()
	local sign = (s.side == "left") and -1 or 1
	local want = base + right * (s.sideOffset * sign) + up * s.heightOffset + fwd * s.forwardOffset

	link.depthAge += dt
	if link.depthAge > 1 then
		link.depth = computeDepth(sp)
		link.depthAge = 0
	end

	if link.pos == nil or (want - link.pos):length() > 5000 then
		link.pos = want
		link.hairVel = link.vel
	elseif s.hairMode then
		-- damped spring toward the slot; softer further down the chain. The linked camera's
		-- velocity is the spring's rest velocity, so a still chain hangs still and a moving one trails.
		local k = hairStiffness()
		local c = 2 * math.clamp(s.hairDamping, 0.3, 1.2) * math.sqrt(k)
		local acc = (want - link.pos) * k + (link.vel - link.hairVel) * c
		link.hairVel = link.hairVel + acc * dt
		link.pos = link.pos + link.hairVel * dt
	else
		-- in predictive mode the rig also carries the estimated velocity, so easing only removes jitter
		link.pos = link.pos:lerp(want, ease(dt, s.followSmooth))
	end

	local outFwd = fwd
	if s.toeIn ~= 0 then outFwd = fwd:rotateAngleAxis(-s.toeIn * sign, up) end
	if s.floorRest then link.pos, link.hairVel = restOnFloor(link.pos, link.hairVel, dt) end
	camera.position = link.pos
	camera.rotation = Quat.fromXZ(outFwd, up)
	camera.fieldOfView = s.fov
end

-- ---------------------------------------------------------------- engine callbacks
local function prepCamera()
	camera.positionSmoothing = 0
	camera.rotationSmoothing = 0
	camera.fieldOfViewSmoothing = 0
	camera.nearClippingPlane = 1
	camera.hideNearestHead = false
end

function main()
	prepCamera()
	fc.ready = false
	link.pos = nil
end

function onTransitionBegin(info)
	prepCamera()
	if info and info.startPosition and info.startRotation then
		fcInitFrom(info.startPosition, info.startRotation)
	end
end

function onConfigChanged()
	loadSettings()
end

function tick(dt)
	if not (camera.isActive or camera.isFollowed) then return end
	if dt <= 0 then return end
	if settings.role == "side" then tickSide(dt) else tickCenter(dt) end
end

-- ---------------------------------------------------------------- GUI
local function slider(label, key, lo, hi)
	settings[key] = Gui.sliderFloat(label, settings[key], lo, hi)
end

function onGui()
	Gui.textDisabled("build: v" .. VERSION)
	Gui.separatorText("Role")
	if Gui.selectable("Center camera (free cam)##role", settings.role == "center") then
		if settings.role ~= "center" then fc.ready = false end
		settings.role = "center"
	end
	if Gui.selectable("Side camera (linked)##role", settings.role == "side") then
		settings.role = "side"
		link.pos = nil
	end

	if settings.role == "center" then
		Gui.separatorText("Attach to player head")
		local preview = settings.headPlayer ~= "" and settings.headPlayer or "None / Free cam"
		if Gui.beginCombo("Player", preview) then
			if Gui.selectable("None / Free cam##hp", settings.headPlayer == "") then
				settings.headPlayer, head.id, head.pos = "", nil, nil
				fc.vel = Vec3.zeroVector
			end
			local ps = listPlayers()
			if #ps == 0 then Gui.textDisabled("No players in the match") end
			for i = 1, #ps do
				local p = ps[i]
				if Gui.selectable(p.playerName .. "##hp" .. tostring(p.playerId), p.playerId == head.id) then
					settings.headPlayer, head.id, head.pos, head.vel, head.dir = p.playerName, p.playerId, nil, Vec3.zeroVector, nil
				end
			end
			Gui.endCombo()
		end
		if settings.headPlayer ~= "" then
			Gui.text(head.lost and ("Waiting for " .. settings.headPlayer .. " (not in match)") or ("Attached to " .. settings.headPlayer))
			if Gui.selectable("Stare & follow##hm", settings.headMode == "stare") then settings.headMode = "stare"; head.vel = fc.vel end
			Gui.sameLine()
			if Gui.selectable("First-person (on head)##hm", settings.headMode == "first") then settings.headMode = "first" end
			Gui.sameLine()
			if Gui.selectable("Just behind head##hm", settings.headMode == "behind") then settings.headMode = "behind" end
			if settings.headMode ~= "stare" then
				settings.headFollowRot = Gui.checkbox("Follow head rotation (off = free look)", settings.headFollowRot)
			end
			if settings.headMode == "stare" then
				slider("Distance (cm)##h", "stareDist", 30, 300)
				slider("Rigidity (hair base stiffness)##h", "hairStiffness", 5, 400)
				slider("Behind-head pull x rigidity##h", "stareTightness", 0.05, 3)
				slider("Height hold x rigidity##h", "stareHeightHold", 0.05, 3)
				slider("Leash (cm)##h", "stareLeash", 30, 1000)
				slider("Height above head (cm)##h", "stareHeight", -50, 50)
				Gui.textDisabled("Always looks at the head. Z/C roll, R levels.")
			elseif settings.headMode == "first" then
				slider("Forward offset (cm)##h", "headForward", -30, 50)
			else
				slider("Behind distance (cm)##h", "headBack", 0, 400)
				slider("Height (cm)##h", "headUp", -100, 200)
				slider("Predictive lead (s)##h", "headLead", 0, 0.3)
			end
			slider("Side offset (cm)##h", "headSide", -200, 200)
			slider("Smoothing (s)##h", "headSmooth", 0, 0.3)
		end
		Gui.separatorText("Free cam")
		Gui.textWrapped("WASD move, Q/E down/up, mouse to look (or hold RMB if set below), Shift boost, Ctrl slow, scroll = cruise speed, Z/C roll, R level, -/= FOV, Alt = move along gravity. Gamepad: sticks, triggers, shoulders roll, D-pad FOV.")
		slider("Cruise speed (cm/s)", "moveSpeed", 20, 20000)
		slider("Acceleration time (s)", "accelTime", 0, 1)
		slider("Boost x", "boostMul", 1, 10)
		slider("Slow x", "slowMul", 0.05, 1)
		slider("Mouse sensitivity", "mouseSens", 0.1, 10)
		settings.mouseLookHold = Gui.checkbox("Hold right mouse to look", settings.mouseLookHold)
		slider("Stick look (deg/s)", "padLookRate", 30, 360)
		slider("Look smoothing (s)", "lookSmooth", 0, 0.3)
		slider("Roll rate (deg/s)", "rollRate", 10, 180)
		slider("FOV", "fov", 10, 140)
		settings.gravityAlign = Gui.checkbox("Align to gravity", settings.gravityAlign)
		settings.floorRest = Gui.checkbox("Rest on floor (no bounce)", settings.floorRest)
	else
		Gui.separatorText("Link")
		local list = listSpectators()
		local preview = settings.linkName ~= "" and settings.linkName or "(choose a spectator)"
		if Gui.beginCombo("Linked camera", preview) then
			if #list == 0 then Gui.textDisabled("No other spectators in this server") end
			for i = 1, #list do
				local sp = list[i]
				if Gui.selectable(sp.playerName .. "##sp" .. tostring(sp.playerId), sp.playerId == link.id) then
					selectLink(sp)
				end
			end
			Gui.endCombo()
		end
		if settings.linkName ~= "" then
			Gui.text(link.lost and ("Waiting for " .. settings.linkName .. " (not in server)") or ("Linked to " .. settings.linkName))
		end
		Gui.separatorText("Side")
		if Gui.selectable("Left##side", settings.side == "left") then settings.side = "left" end
		Gui.sameLine()
		if Gui.selectable("Right##side", settings.side == "right") then settings.side = "right" end
		slider("Side offset (cm)", "sideOffset", 0, 2000)
		slider("Height offset (cm)", "heightOffset", -500, 500)
		slider("Forward offset (cm)", "forwardOffset", -1000, 1000)
		slider("Toe-in (deg)", "toeIn", -45, 45)
		slider("Position smoothing (s)", "followSmooth", 0, 0.5)
		slider("FOV", "fov", 10, 140)
		settings.floorRest = Gui.checkbox("Rest on floor (no bounce)", settings.floorRest)
		Gui.separatorText("Hair mode")
		settings.hairMode = Gui.checkbox("Hair mode (springy chain)", settings.hairMode)
		Gui.setItemTooltip("Follow on a spring. Stiffest just behind the primary, softer the further down the chain")
		if settings.hairMode then
			slider("Base stiffness", "hairStiffness", 5, 400)
			slider("Falloff per link", "hairFalloff", 0.3, 1)
			slider("Min stiffness", "hairMinStiffness", 1, 100)
			slider("Damping ratio", "hairDamping", 0.3, 1.2)
			slider("Chain search radius (cm)", "chainRadius", 100, 3000)
			slider("Depth override (0 = auto)", "depthOverride", 0, 10)
			Gui.text(string.format("Chain depth %d, stiffness %.1f", link.depth, hairStiffness()))
		end
		Gui.separatorText("Predictive")
		settings.predictive = Gui.checkbox("Predictive movement", settings.predictive)
		Gui.setItemTooltip("Extrapolates the linked camera's motion so this camera moves with it instead of trailing behind")
		slider("Lead time (s)", "leadTime", 0, 0.5)
		settings.addPing = Gui.checkbox("Add linked spectator's ping to lead", settings.addPing)
	end

	Gui.separator()
	if Gui.button("Save settings") then save() end
	Gui.sameLine()
	if Gui.button("Reset to defaults") then
		for k, d in pairs(DEFAULTS) do settings[k] = d end
		statusMsg = "Defaults restored (not saved)"
	end
	if statusMsg ~= "" then Gui.textDisabled(statusMsg) end
end
