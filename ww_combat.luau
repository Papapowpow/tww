--[[
    Silent Aim + Player ESP + Extras - The Wild West
    =====================================================================
    BUILD 8

    AIM.  The single chokepoint is

      ReplicatedStorage.Modules.Utils.Utils.GetMouseHit(range, ...)
        -> Position, Instance, Normal, Material

      Global.Utils is the same table as require(...Utils.Utils), so one
      assignment replaces it everywhere. Two consumers read it:

        Modules.Character.Items.Types.GunItemType : Fire()
            v5 = GetMouseHit(2000, ...)             -- aim point
            Unit = (v5 - muzzle).Unit               -- shot direction

        Modules.Character.FaceMouse : UpdateGoal()
            goal = GetMouseHit(2000, ...)           -- arm / torso spring

      Nothing in the projectile path validates aim: the server rebuilds the
      shot from the origin/direction this client sends, and reproduces the
      spread deterministically from `seed` + `accuracy`
      (radius = rad(12.5) * clamp(1 - accuracy, 0, 1)). Pinning accuracy = 1
      gives a zero cone.

    THE RANGE LIMIT (build 5 -> 6).
      The circle is measured in SCREEN pixels, so a player standing far away
      who covers only a few pixels near the middle is still a perfectly good
      lock at 3000 studs. MaxRange adds the world-space cut that was missing:
      a candidate is only locked when it is within Config.MaxRange studs of the
      camera - the same origin the ESP distance readout uses, so the two
      numbers in the interface agree with each other. The test sits in
      resolveTarget ahead of the visibility raycast, so an out-of-range player
      is skipped for the cost of one vector subtraction, and because bestDist
      is only advanced by a candidate that passes, a close-but-too-far player
      can never shadow a valid one. 100..3000 studs, default 3000 - i.e. the
      old, effectively unlimited behaviour until the slider is moved.

      Only calls with a range of 1000+ are redirected, so the custom-cursor
      click detector and item placement (GetMouseHit(50)) stay untouched.

    THE HOLD BIND FIX (build 3 -> 4).
      Build 3 tracked the hold from InputBegan/InputEnded and compared
      `input.KeyCode == Config.HoldKey`. Two things were wrong with that:

        * A mouse input carries `KeyCode = Enum.KeyCode.Unknown`, and the
          keybind left on its default reports `Enum.KeyCode.None`, which IS
          `Enum.KeyCode.Unknown` (value 0). So the bind matched every mouse
          button AND every mouse release.

        * Firing is a left-mouse click, so LMB-up delivered a matching
          InputEnded -> `holding = false` -> the aim switched itself off after
          every shot, and only a fresh RMB press turned it back on.

      The hold is now POLLED every frame (`IsKeyDown` / `IsMouseButtonPressed`)
      instead of being tracked from events, keyboard binds are only compared
      against real key codes, mouse binds only against mouse UserInputTypes,
      and "None"/Unknown means unbound (always on while enabled). An event that
      is never delivered can no longer leave the aim stuck either way.

    THE PASSTHROUGH FIX (build 4 -> 5).
      Build 4 switched older copies of itself off around a passthrough call by
      clearing active/target on every state table in the list published in
      getgenv().WW_SA_States - and that list also held ITS OWN state. The game
      asks for GetMouseHit(50) about 60 times a second for its custom cursor, so
      the live state was wiped, frame after frame, moments before Fire and
      FaceMouse read it. The lock dot kept drawing (it is computed one step
      earlier, in RenderStepped) while the shots and the arm quietly stopped
      tracking. The list is now private to this run and never contains its own
      state, and the hook reads active/target as a pair.

    ESP.  Player.Character is ALWAYS nil in this game - the rigs live in
      Workspace.WORKSPACE_Entities.Players/<playerName> as R15 Models with a
      Humanoid. The box is built from the rig's own body parts (so a hat, a
      weapon or a hitbox box cannot inflate it) and projected with
      WorldToViewportPoint, which is the inset-free projection that maps 1:1
      onto Real's Drawing surface.

    THE HEALTH READOUT (build 6 -> 7).
      Humanoid.Health is a decoy here: every rig - other players' and your own -
      reports 100 for the whole session, so the number beside the box could
      never move, however badly its owner was hurt. The health the game actually
      tracks (and draws the little bar over each rig from) lives in that
      character's replicated state, reachable as

        Global.RepCharHandler:GetRepChar(player).State.Health

      That is read first. The rig's own health bar fill is the fallback and the
      Humanoid the last resort, so a rig caught mid-spawn still shows something.

    INFINITE HORSE BOOST (build 7).
      Spurring spends one charge from the ridden animal's own Boosts counter
      (HorseBoost -> Animal:Boost). At zero the next spur plays the Exhausted
      animation and then knocks you off the horse. Boosts is a plain field on
      the animal object, so holding it at MaxBoosts keeps you spurring for as
      long as you like, and ExhaustedWarning is cleared so the knock-out cannot
      latch on the frame the counter dips.

    2x FAST RELOAD (build 8).
      Feeding a gun is a different action from firing it, and this is the former.
      The manual reload is GunItemType:Load, whose only knob is
      SharedData.LoadSpeed: the "Load" animation is keyframed to insert one
      bullet at a time, so doubling that speed doubles how fast the gun fills.
      That is deliberately all that is touched - the shot cycle reads FireSpeed
      and ReloadSpeed, so the firing rate is exactly what it was. The speed is
      read when the animation is played, so the config tables are only scaled
      once, on the toggle, and never need a per-shot hook.

    LEGENDARY ANIMAL ESP (build 7).
      Rarity is size, not health. A legendary spawns at exactly 1.5x the
      ordinary animal of its species - "far larger, faster, and significantly
      harder to kill... massive health and regeneration" - while Health drops
      with every hit and stops being a marker the moment shooting starts. The
      per-species body length is a constant (measured: Bear 3.005, Deer 1.893,
      Bison 4.325, Gator 1.372, Capybara 1.812 studs), so a body at or above
      1.15x its species' figure is flagged, labelled with its species and
      distance, and - because a legendary worth finding is usually not in front
      of you - also reported once in the corner as the nearest one.
]]

--=========================== services ===========================--
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local RS         = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer

local Global     = require(RS.SharedModules.Global)                  -- live client state
local Utils      = require(RS.Modules.Utils.Utils)                   -- GetMouseHit lives here
local Projectile = require(RS.SharedModules.World.ProjectileHandler)  -- InitProjectiles

local genv = getgenv()

--=========================== runtime shim ===========================--
-- STATE is supplied by Real's live-reload harness (also reachable as
-- getgenv().STATE). Pasted straight into a normal executor there is nothing to
-- supply it, so the same small surface is defined here instead.
local STATE = genv.STATE
if not (type(STATE) == "table" and type(STATE.connect) == "function") then
    local connections, alive = {}, true
    STATE = {
        connect = function(signal, fn)
            local c = signal:Connect(fn)
            table.insert(connections, c)
            return c
        end,
        onCleanup = function(fn)
            table.insert(connections, { Disconnect = fn })
        end,
        alive = function() return alive end,
    }
end

--=========================== previous run ===========================--
-- A build can die part-way (an error, a reload, a wedged client) and leave
-- behind live connections, hooked functions and Drawing handles. Everything of
-- ours is held in getgenv() under a stable name, so teardown is exact, and an
-- upvalue sweep catches builds that predate the registry.
local prevState = genv.WW_SA_State
local prevConns = genv.WW_SA_Conns
local prevDraws = genv.WW_SA_Drawings
-- States belonging to runs that came BEFORE this one. Copied into a list of our
-- own instead of aliasing getgenv().WW_SA_States: an older copy of this script
-- holds that very table and clears active/target on every entry of it around its
-- own passthrough (see throughPrevious). While the table was shared, an old copy
-- switched the LIVE state off on every cursor raycast - and the wiped state is
-- exactly what Fire and FaceMouse read moments later in the same frame, which is
-- why the lock dot drew but the arm would not follow it.
local prevStates = {}
if type(genv.WW_SA_States) == "table" then
    for _, s in ipairs(genv.WW_SA_States) do
        prevStates[#prevStates + 1] = s
    end
end

local myConns    = {}   -- every connection this run makes
local myDrawings = {}   -- every Drawing handle this run makes
genv.WW_SA_Conns    = myConns
genv.WW_SA_Drawings = myDrawings

local function sweepPrevious()
    -- 1. the registry, when the previous run managed to write it
    if type(prevConns) == "table" then
        for _, c in ipairs(prevConns) do
            pcall(function() c:Disconnect() end)
        end
    end
    if type(prevDraws) == "table" then
        for _, d in ipairs(prevDraws) do
            pcall(function() d:Remove() end)
        end
    end

    -- 2. builds from before the registry: find their connections by the only
    --    thing they have in common - the state table they closed over.
    if type(prevState) == "table" and (prevState.active ~= nil or prevState.holding ~= nil) then
        local signals = {
            RunService.RenderStepped,
            RunService.Heartbeat,
            UIS.InputBegan,
            UIS.InputEnded,
        }
        for _, sig in ipairs(signals) do
            local ok, list = pcall(getconnections, sig)
            if ok and type(list) == "table" then
                for _, conn in ipairs(list) do
                    local fn = conn.Function
                    if typeof(fn) == "function" then
                        local okU, ups = pcall(debug.getupvalues, fn)
                        if okU and type(ups) == "table" then
                            local isOurs = false
                            for _, v in pairs(ups) do
                                if rawequal(v, prevState) then isOurs = true end
                            end
                            if isOurs then
                                for _, v in pairs(ups) do
                                    if isrenderobj and isrenderobj(v) then
                                        pcall(function() v:Remove() end)
                                    end
                                end
                                pcall(function() conn:Disconnect() end)
                            end
                        end
                    end
                end
            end
        end
    end
end

sweepPrevious()

--=========================== config ===========================--
-- Lives in getgenv() so the Rayfield callbacks keep pointing at the same
-- table across reloads.
local DEFAULTS = {
    -- aim
    Enabled     = false,
    HoldKey     = nil,   -- nil = always active while Enabled; bind one to gate it
    FOV         = 150,   -- circle radius in pixels, measured from screen centre
    MaxRange    = 3000,  -- studs from the camera; ignore anyone further out
    Part        = "Head",
    VisibleOnly = false,
    TeamCheck   = false,
    NoSpread    = true,
    DrawFOV     = true,
    DrawHUD     = true,
    FixCursor   = true,
    -- esp
    ESPEnabled   = false,
    ESPBox       = true,
    ESPFill      = true,
    ESPName      = true,
    ESPDistance  = true,
    ESPHealth    = true,
    ESPHealthBar = true,
    ESPTeam      = false,
    ESPMaxDist   = 0,    -- 0 = no limit
    ESPTextSize  = 14,
    -- legendary animals
    ESPLegendary    = false,
    ESPLegendaryBox = true,
    ESPAnimalAlert  = true,
    -- utility
    HorseBoost      = false,
    FastReload      = false,
}

local BUILD = 8

local Config = genv.WW_SA_Config
if not Config then
    Config = {}
    for k, v in pairs(DEFAULTS) do Config[k] = v end
    genv.WW_SA_Config = Config
else
    -- A config saved by an older build may be missing newer keys, and a nil
    -- reaches a Drawing property or a comparison as a silent failure.
    for k, v in pairs(DEFAULTS) do
        if Config[k] == nil then Config[k] = v end
    end
end

-- A slider can come back from a saved config as something other than a number,
-- and a string reaching the range comparison in resolveTarget would error out
-- every frame. Floor it and hold it inside the slider's own bounds.
if type(Config.MaxRange) ~= "number" then
    Config.MaxRange = DEFAULTS.MaxRange
end
Config.MaxRange = math.clamp(math.floor(Config.MaxRange), 100, 3000)

-- One-time migration. Builds up to 3 could never satisfy a keyboard-style bind,
-- because the keybind's "None" is Enum.KeyCode.Unknown - the very KeyCode every
-- mouse input reports - so it matched every mouse button, and every mouse
-- release cleared the hold. Drop that value so the aim is simply always on.
if Config.__build ~= BUILD then
    local k = Config.HoldKey
    if k == nil or typeof(k) ~= "EnumItem" or k == Enum.KeyCode.Unknown then
        Config.HoldKey = nil
    end
    Config.__build = BUILD
end

-- The camera can be replaced (respawn, spectate), so never cache it.
local function cam()
    return workspace.CurrentCamera
end

local State = { holding = false, active = false, target = nil, mine = nil }
genv.WW_SA_State = State   -- inspectable: getgenv().WW_SA_State.target

-- Publish older runs + this one, so the NEXT run can switch this run's hook off.
-- prevStates (what throughPrevious walks) deliberately does NOT contain State:
-- nothing may clear the live state, mid-frame or otherwise.
local trackedStates = {}
for _, s in ipairs(prevStates) do
    trackedStates[#trackedStates + 1] = s
end
trackedStates[#trackedStates + 1] = State
genv.WW_SA_States = trackedStates

local function armed()
    return Config.Enabled and State.holding
end

--=========================== target ===========================--
-- Characters are NOT on Player.Character in this game. The real rigs live
-- under Workspace.WORKSPACE_Entities.Players, named after the player.
local function entityRoot()
    local e = workspace:FindFirstChild("WORKSPACE_Entities")
    return e and e:FindFirstChild("Players") or nil
end

--- Middle of the screen: both the circle and the FOV test use this.
local function aimOrigin()
    return cam().ViewportSize * 0.5
end

local function toScreen(world)
    local p = cam():WorldToViewportPoint(world)
    if p.Z <= 0 then return nil end          -- behind the camera
    return Vector2.new(p.X, p.Y)
end

local wallCheck = RaycastParams.new()
wallCheck.FilterType = Enum.RaycastFilterType.Exclude
wallCheck.IgnoreWater = true

local function isVisible(part, model)
    local ignore = { cam() }
    if Global.PlayerCharacter.Character then table.insert(ignore, Global.PlayerCharacter.Character) end
    local ign = workspace:FindFirstChild("Ignore")
    if ign then table.insert(ignore, ign) end
    wallCheck.FilterDescendantsInstances = ignore

    local from = cam().CFrame.Position
    local hit = workspace:Raycast(from, part.Position - from, wallCheck)
    return (hit == nil) or hit.Instance:IsDescendantOf(model)
end

local function partOf(model)
    return model:FindFirstChild(Config.Part)
        or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("Head")
end

--- Closest player to the middle of the screen whose aim part is inside the
--- circle and within Config.MaxRange studs of the camera.
local function resolveTarget()
    local folder = entityRoot()
    if not folder then return nil end

    local origin = aimOrigin()
    local camera = cam()
    local worldOrigin = camera and camera.CFrame.Position
    local maxRange = Config.MaxRange
    local best, bestDist = nil, Config.FOV

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= lp and not (Config.TeamCheck and plr.Team and plr.Team == lp.Team) then
            local model = folder:FindFirstChild(plr.Name)
            local hum = model and model:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                local part = partOf(model)
                local screen = part and toScreen(part.Position)
                if screen then
                    local dist = (screen - origin).Magnitude
                    -- The circle is a screen-space test, so without this a dot
                    -- on the horizon is as good a lock as someone in front of
                    -- you. bestDist is only advanced by a candidate that gets
                    -- past here, so a too-far player never shadows a valid one.
                    local inRange = worldOrigin == nil
                        or (part.Position - worldOrigin).Magnitude <= maxRange
                    if inRange and dist <= bestDist
                        and (not Config.VisibleOnly or isVisible(part, model)) then
                        bestDist = dist
                        best = { part = part, model = model, pos = part.Position, player = plr }
                    end
                end
            end
        end
    end
    return best
end

--- Name of the held item, and whether it is actually a gun.
local function heldItem()
    local pc = Global.PlayerCharacter
    local item = pc and pc:GetEquippedItem()
    if not item then return "nothing", false end
    return tostring(item.Name), item.IsGunItem == true
end

--=========================== hold bind ===========================--
-- Polled, never event-tracked. See the header: a mouse release used to clear a
-- hold that the keybind's own default value had made match every mouse button.
local MOUSE_BUTTONS = {
    [Enum.UserInputType.MouseButton1] = true,
    [Enum.UserInputType.MouseButton2] = true,
    [Enum.UserInputType.MouseButton3] = true,
}

local function bindHeld()
    local k = Config.HoldKey
    if k == nil or typeof(k) ~= "EnumItem" then return true end   -- unbound: always on
    if k.EnumType == Enum.KeyCode then
        if k == Enum.KeyCode.Unknown then return true end         -- Rayfield's "None"
        local ok, down = pcall(function() return UIS:IsKeyDown(k) end)
        return ok and down
    end
    if k.EnumType == Enum.UserInputType then
        if not MOUSE_BUTTONS[k] then return true end
        local ok, down = pcall(function() return UIS:IsMouseButtonPressed(k) end)
        return ok and down
    end
    return true
end

--=========================== hooks ===========================--
local function swap(tbl, key, fn)
    local original = tbl[key]
    local ok = pcall(function() tbl[key] = fn end)
    if not ok and setreadonly then
        pcall(setreadonly, tbl, false)
        pcall(function() tbl[key] = fn end)
    end
    return original
end

--- Call a function an older copy of this script may have wrapped. That copy
--- only redirects while its own state says it is active, so switching every
--- past copy's state off around the call makes them pass straight through to
--- the game's real function - however many times this script has been rerun.
--- prevStates never holds this run's own State, so the live aim is untouched.
local function throughPrevious(fn, ...)
    for _, s in ipairs(prevStates) do
        s.active = false
        s.target = nil
    end
    return fn(...)
end

-- Aim chokepoint: hand back the target instead of the cursor raycast.
-- Declared first, then assigned, so the closure captures this local rather
-- than a nil global (a local is not in scope inside its own initialiser).
local originalGetMouseHit
originalGetMouseHit = swap(Utils, "GetMouseHit", function(range, ...)
    -- Auto mine first: while a mining stop is replaying, the swing and the
    -- arm spring have to point at the ore whatever the aim is doing. Same
    -- chokepoint FaceMouse already reads, so the rig turns onto it by itself.
    local m = State.mine
    if m and m.pos then
        return m.pos, m.part, Vector3.new(0, 1, 0), Enum.Material.Air
    end
    -- Read once, together. Anything that happens between here and the return
    -- must not be able to leave a half-cleared pair (active true, target gone).
    local active = State.active
    local t = State.target
    if active and t and range and range >= 1000 then
        return t.pos, t.part, Vector3.new(0, 1, 0), Enum.Material.Air
    end
    return throughPrevious(originalGetMouseHit, range, ...)
end)

-- Kill the deterministic spread cone that ships with the shot.
local originalInitProjectiles
originalInitProjectiles = swap(Projectile, "InitProjectiles", function(self, ptype, shared, params, cb)
    local active = State.active
    if active and Config.NoSpread and type(params) == "table" and params.accuracy ~= nil then
        params.accuracy = 1
    end
    return throughPrevious(originalInitProjectiles, self, ptype, shared, params, cb)
end)

--=========================== cursor ===========================--
-- One thing owns the cursor while a gun is out: the game. Modules.UI
-- .CursorUI.Cursor picks "LockCenter" whenever Camera:IsCustom() is true - which
-- is exactly the armed state - and hides the icon with it.
--
-- The Rayfield build carried a second opinion: its own "mouseOverride" pinned
-- the cursor to Default and re-enabled the icon on every property change, which
-- is what made aiming with the window open feel wrong, and why it was switched
-- off. There is no such override now, so the game's decision simply stands and
-- the listeners below are a backstop for anything else that resets it.
local CollectionService = game:GetService("CollectionService")
local GuiService        = game:GetService("GuiService")

--- Mirror of Cursor:IsMouseFree(). True means the game deliberately wants a
--- free mouse, so we must not interfere.
local function mouseIsMeantToBeFree()
    for _, gui in ipairs(CollectionService:GetTagged("CustomModalGui")) do
        local prop = gui:IsA("LayerCollector") and "Enabled" or "Visible"
        local ok, shown = pcall(function() return gui[prop] end)
        if ok and shown and gui:IsDescendantOf(lp) then
            return true                     -- a real game menu is up (map, shop, ...)
        end
    end
    if Global.UI.Spawn.Opened then return true end
    if not Global.Camera:IsCustom() then return true end     -- holstered: cursor belongs there
    if Global.Camera:IsPlayingCutScene() then return true end
    return false
end

local cursorGuard = false

local function holdCursor()
    if cursorGuard then return end
    cursorGuard = true
    pcall(function()
        if not Config.FixCursor or not Global.Camera:IsCustom() then return end
        if UIS:GetFocusedTextBox() then return end   -- typing in chat
        if GuiService.MenuIsOpen then return end     -- Roblox pause menu
        if mouseIsMeantToBeFree() then return end

        if UIS.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
            UIS.MouseBehavior = Enum.MouseBehavior.LockCenter
        end
        if UIS.MouseIconEnabled then
            UIS.MouseIconEnabled = false
        end
    end)
    cursorGuard = false
end

local function track(signal, fn)
    local c = STATE.connect(signal, fn)
    table.insert(myConns, c)
    return c
end

-- The property listeners are what win the race: whoever resets the state, we
-- correct it on the same event.
track(UIS:GetPropertyChangedSignal("MouseBehavior"), holdCursor)
track(UIS:GetPropertyChangedSignal("MouseIconEnabled"), holdCursor)
track(RunService.Heartbeat, function()
    if UIS.MouseBehavior ~= Enum.MouseBehavior.LockCenter or UIS.MouseIconEnabled then
        holdCursor()
    end
end)

--=========================== drawing ===========================--
local function newDraw(kind)
    local d = Drawing.new(kind)
    table.insert(myDrawings, d)
    return d
end

local FONT = (Drawing.Fonts and Drawing.Fonts.Plex) or 2

-- aim overlay
local fovCircle = newDraw("Circle")
fovCircle.Thickness, fovCircle.Filled, fovCircle.Transparency = 1.5, false, 0.75
fovCircle.Color, fovCircle.Visible, fovCircle.ZIndex = Color3.fromRGB(255, 255, 255), false, 1

local lockDot = newDraw("Circle")
lockDot.Thickness, lockDot.Filled, lockDot.Transparency, lockDot.Radius = 1.5, false, 0.9, 5
lockDot.Color, lockDot.Visible, lockDot.ZIndex = Color3.fromRGB(255, 64, 64), false, 2

local hud = newDraw("Text")
hud.Size, hud.Center, hud.Outline, hud.Transparency, hud.Font = 16, false, true, 1, FONT
hud.Position, hud.Visible, hud.ZIndex = Vector2.new(12, 72), false, 3

--=========================== esp ===========================--
-- Every rig is R15 and scaled per player, so the box is measured from the rig
-- itself rather than from a fixed stud height. Parts that are not body parts
-- (hats, tools, the small Boxing/Kick hitboxes) are deliberately excluded.
local BODY_PARTS = {
    "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart",
    "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
    "LeftHand", "RightHand",
    "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg",
    "LeftFoot", "RightFoot",
}

local CORNERS = {
    { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 },
    { 0, 0, 1 }, { 1, 0, 1 }, { 0, 1, 1 }, { 1, 1, 1 },
}

--- World-axis-aligned bounds of the rig's body parts.
local function bodyBounds(model)
    local minX, minY, minZ, maxX, maxY, maxZ
    local found = false

    for _, name in ipairs(BODY_PARTS) do
        local p = model:FindFirstChild(name)
        if p and p:IsA("BasePart") then
            found = true
            local pos, sz = p.Position, p.Size
            local x0, x1 = pos.X - sz.X * 0.5, pos.X + sz.X * 0.5
            local y0, y1 = pos.Y - sz.Y * 0.5, pos.Y + sz.Y * 0.5
            local z0, z1 = pos.Z - sz.Z * 0.5, pos.Z + sz.Z * 0.5
            minX = (minX == nil) and x0 or math.min(minX, x0)
            maxX = (maxX == nil) and x1 or math.max(maxX, x1)
            minY = (minY == nil) and y0 or math.min(minY, y0)
            maxY = (maxY == nil) and y1 or math.max(maxY, y1)
            minZ = (minZ == nil) and z0 or math.min(minZ, z0)
            maxZ = (maxZ == nil) and z1 or math.max(maxZ, z1)
        end
    end

    if not found then return nil end
    return { minX = minX, minY = minY, minZ = minZ, maxX = maxX, maxY = maxY, maxZ = maxZ }
end

--- Screen rectangle for a world box, or nil when a corner is behind the camera
--- (a partially-behind box has no meaningful 2D rectangle).
local function project(box, camera)
    local minX, minY, maxX, maxY
    for _, c in ipairs(CORNERS) do
        local world = Vector3.new(
            c[1] == 1 and box.maxX or box.minX,
            c[2] == 1 and box.maxY or box.minY,
            c[3] == 1 and box.maxZ or box.minZ
        )
        local vp = camera:WorldToViewportPoint(world)
        if vp.Z <= 0 then return nil end
        minX = (minX == nil) and vp.X or math.min(minX, vp.X)
        maxX = (maxX == nil) and vp.X or math.max(maxX, vp.X)
        minY = (minY == nil) and vp.Y or math.min(minY, vp.Y)
        maxY = (maxY == nil) and vp.Y or math.max(maxY, vp.Y)
    end
    return minX, minY, maxX, maxY
end

local function hpColor(pct)
    return Color3.fromRGB(
        math.floor(255 - 175 * pct),
        math.floor(60 + 195 * pct),
        math.floor(60 + 60 * pct)
    )
end

--- Current health and maximum for a player, in the game's own numbers.
--- Humanoid.Health is 100 for every rig in this game at all times, so it can
--- only ever be the last resort. The real value sits in the character's
--- replicated state - the same one the bar hovering over each rig is drawn
--- from - and the bar's fill is the fallback for a state that has not arrived.
local function healthOf(plr, model, hum)
    local handler = Global and Global.RepCharHandler
    if handler then
        local ok, rc = pcall(function() return handler:GetRepChar(plr) end)
        local st = ok and rc and rc.State
        if type(st) == "table" and type(st.Health) == "number" then
            local max = type(st.MaxHealth) == "number" and st.MaxHealth or nil
            return st.Health, max or 100
        end
    end

    local max = (hum and type(hum.MaxHealth) == "number" and hum.MaxHealth > 0)
        and hum.MaxHealth or 100
    if model then
        local status = model:FindFirstChild("PlayerStatus", true)
        local bar = status and status:FindFirstChild("HealthBar", true)
        local fill = bar and bar:FindFirstChild("HealthProgressFrame")
        if fill then
            return fill.Size.X.Scale * max, max
        end
    end
    if hum then return hum.Health, max end
    return nil, nil
end

local EspPool = {}   -- [Player] = element set

local function newEspEntry()
    local e = { draws = {} }

    local function make(kind)
        local d = newDraw(kind)
        table.insert(e.draws, d)
        return d
    end

    e.fill = make("Square")
    e.fill.Filled, e.fill.Thickness, e.fill.Transparency = true, 1, 0.55
    e.fill.Color, e.fill.Visible, e.fill.ZIndex = Color3.fromRGB(0, 0, 0), false, 2

    e.outline = make("Square")
    e.outline.Filled, e.outline.Thickness, e.outline.Transparency = false, 1, 1
    e.outline.Color, e.outline.Visible, e.outline.ZIndex = Color3.fromRGB(255, 255, 255), false, 3

    e.name = make("Text")
    e.name.Center, e.name.Outline, e.name.OutlineColor = true, true, Color3.fromRGB(0, 0, 0)
    e.name.Transparency, e.name.Font = 1, FONT
    e.name.Color, e.name.Visible, e.name.ZIndex = Color3.fromRGB(255, 255, 255), false, 4

    e.dist = make("Text")
    e.dist.Center, e.dist.Outline, e.dist.OutlineColor = true, true, Color3.fromRGB(0, 0, 0)
    e.dist.Transparency, e.dist.Font = 1, FONT
    e.dist.Color, e.dist.Visible, e.dist.ZIndex = Color3.fromRGB(235, 235, 235), false, 4

    e.hpText = make("Text")
    e.hpText.Center, e.hpText.Outline, e.hpText.OutlineColor = false, true, Color3.fromRGB(0, 0, 0)
    e.hpText.Transparency, e.hpText.Font = 1, FONT
    e.hpText.Color, e.hpText.Visible, e.hpText.ZIndex = Color3.fromRGB(255, 255, 255), false, 4

    e.hpBg = make("Square")
    e.hpBg.Filled, e.hpBg.Thickness, e.hpBg.Transparency = true, 1, 0.45
    e.hpBg.Color, e.hpBg.Visible, e.hpBg.ZIndex = Color3.fromRGB(0, 0, 0), false, 3

    e.hpFill = make("Square")
    e.hpFill.Filled, e.hpFill.Thickness, e.hpFill.Transparency = true, 1, 1
    e.hpFill.Color, e.hpFill.Visible, e.hpFill.ZIndex = Color3.fromRGB(80, 255, 120), false, 4

    return e
end

local function espEntry(plr)
    local e = EspPool[plr]
    if not e then
        e = newEspEntry()
        EspPool[plr] = e
    end
    return e
end

local function hideEntry(e)
    e.fill.Visible, e.outline.Visible = false, false
    e.name.Visible, e.dist.Visible, e.hpText.Visible = false, false, false
    e.hpBg.Visible, e.hpFill.Visible = false, false
end

local function dropEntry(plr)
    local e = EspPool[plr]
    if not e then return end
    EspPool[plr] = nil

    -- drop the handles from the run's registry too, so a session that sees a
    -- lot of players come and go does not accumulate dead handles
    for _, d in ipairs(e.draws) do
        pcall(function() d:Remove() end)
        for i = #myDrawings, 1, -1 do
            if myDrawings[i] == d then
                table.remove(myDrawings, i)
                break
            end
        end
    end
end

local function updateEsp(camera)
    -- entries are created lazily, so nothing to do at all until one exists
    if next(EspPool) == nil and not Config.ESPEnabled then return end

    for plr, e in pairs(EspPool) do
        if plr.Parent == nil then
            dropEntry(plr)
        elseif not Config.ESPEnabled then
            hideEntry(e)
        end
    end
    if not Config.ESPEnabled then return end

    local folder = entityRoot()
    if not folder then return end

    local origin = camera.CFrame.Position
    local textSize = Config.ESPTextSize
    local maxDist = Config.ESPMaxDist

    for _, plr in ipairs(Players:GetPlayers()) do
        local e = EspPool[plr]
        local skip = plr == lp
            or (Config.ESPTeam and plr.Team and plr.Team == lp.Team)

        if skip then
            if e then hideEntry(e) end
        else
            local model = folder:FindFirstChild(plr.Name)
            local hum = model and model:FindFirstChildOfClass("Humanoid")
            local rectMinX, rectMinY, rectMaxX, rectMaxY
            local hp, hpMax = healthOf(plr, model, hum)

            if model and hp and hp > 0 then
                local box = bodyBounds(model)
                if box then
                    rectMinX, rectMinY, rectMaxX, rectMaxY = project(box, camera)
                end
            end

            if rectMinX and (maxDist <= 0 or (model:GetPivot().Position - origin).Magnitude <= maxDist) then
                e = espEntry(plr)
                hideEntry(e)

                local dist = (model:GetPivot().Position - origin).Magnitude
                local height = rectMaxY - rectMinY
                local width = rectMaxX - rectMinX
                local cx = (rectMinX + rectMaxX) * 0.5
                local cy = (rectMinY + rectMaxY) * 0.5
                local pct = math.clamp(hp / math.max(hpMax or 100, 1), 0, 1)

                if Config.ESPBox then
                    if Config.ESPFill then
                        e.fill.Position = Vector2.new(rectMinX, rectMinY)
                        e.fill.Size = Vector2.new(width, height)
                        e.fill.Visible = true
                    end
                    e.outline.Position = Vector2.new(rectMinX, rectMinY)
                    e.outline.Size = Vector2.new(width, height)
                    e.outline.Visible = true
                end

                if Config.ESPName then
                    e.name.Size = textSize
                    e.name.Text = plr.DisplayName
                    e.name.Position = Vector2.new(cx, rectMinY - textSize - 3)
                    e.name.Visible = true
                end

                if Config.ESPDistance then
                    e.dist.Size = textSize - 2
                    e.dist.Text = string.format("%d", math.floor(dist + 0.5))
                    e.dist.Position = Vector2.new(cx, rectMaxY + 3)
                    e.dist.Visible = true
                end

                if Config.ESPHealth then
                    e.hpText.Size = textSize - 2
                    e.hpText.Text = string.format("%d", math.floor(hp + 0.5))
                    e.hpText.Color = hpColor(pct)
                    e.hpText.Visible = true
                    -- right-aligned against the right edge of the health bar
                    e.hpText.Position = Vector2.new(
                        rectMinX - 8 - e.hpText.TextBounds.X,
                        cy - e.hpText.TextBounds.Y * 0.5
                    )
                end

                if Config.ESPHealthBar and height > 2 then
                    local barX = rectMinX - 5
                    e.hpBg.Position = Vector2.new(barX, rectMinY)
                    e.hpBg.Size = Vector2.new(2, height)
                    e.hpBg.Visible = true

                    local filled = height * pct
                    e.hpFill.Position = Vector2.new(barX, rectMinY + (height - filled))
                    e.hpFill.Size = Vector2.new(2, filled)
                    e.hpFill.Color = hpColor(pct)
                    e.hpFill.Visible = true
                end
            elseif e then
                hideEntry(e)
            end
        end
    end
end

track(Players.PlayerRemoving, function(plr)
    dropEntry(plr)
end)

--=========================== legendary wildlife ===========================--
-- See the note at the top of the file: rarity is size, and an ordinary animal's
-- body length is a fixed figure per species, so a body at or above 1.15x that
-- figure is a legendary (the one measured live was a bear at exactly 1.5x:
-- body 3.005 -> 4.507, health 300 -> 1260, which is what the guidebook's "far
-- larger... massive health and regeneration" describes). Cow and Horse are
-- deliberately absent - they are livestock, not game.
local LEGENDARY_BASE = {
    Bear     = 3.005,
    Deer     = 1.893,
    Bison    = 4.325,
    Gator    = 1.372,
    Capybara = 1.812,
}
local LEGENDARY_SCALE = 1.15
local LEGENDARY_COLOUR = Color3.fromRGB(255, 88, 33)   -- the guidebook's own red

local animalAlert = newDraw("Text")
animalAlert.Size, animalAlert.Center, animalAlert.Outline = 14, false, true
animalAlert.OutlineColor, animalAlert.Transparency, animalAlert.Font =
    Color3.fromRGB(0, 0, 0), 1, FONT
animalAlert.Color, animalAlert.Visible, animalAlert.ZIndex = LEGENDARY_COLOUR, false, 3
animalAlert.Position = Vector2.new(12, 96)

local LegendaryPool = {}   -- [Model] = element set

local function newLegendaryEntry()
    local e = { draws = {} }
    local function make(kind)
        local d = newDraw(kind)
        table.insert(e.draws, d)
        return d
    end

    e.box = make("Square")
    e.box.Filled, e.box.Thickness, e.box.Transparency = false, 1.5, 1
    e.box.Color, e.box.Visible, e.box.ZIndex = LEGENDARY_COLOUR, false, 3

    e.label = make("Text")
    e.label.Center, e.label.Outline, e.label.OutlineColor = true, true, Color3.fromRGB(0, 0, 0)
    e.label.Transparency, e.label.Font = 1, FONT
    e.label.Color, e.label.Visible, e.label.ZIndex = LEGENDARY_COLOUR, false, 4

    return e
end

local function hideLegendary(e)
    e.box.Visible, e.label.Visible = false, false
end

local function dropLegendary(model)
    local e = LegendaryPool[model]
    if not e then return end
    LegendaryPool[model] = nil

    for _, d in ipairs(e.draws) do
        pcall(function() d:Remove() end)
        for i = #myDrawings, 1, -1 do
            if myDrawings[i] == d then
                table.remove(myDrawings, i)
                break
            end
        end
    end
end

--- World-axis-aligned bounds of an animal's own body parts. Only direct
--- children count: the rig keeps its physics shapes inside a CollisionModel
--- child, which is bigger than the animal and would inflate the box.
local function animalBounds(model)
    local minX, minY, minZ, maxX, maxY, maxZ
    local found = false

    for _, p in ipairs(model:GetChildren()) do
        if p:IsA("BasePart") and p.Transparency < 0.9 then
            found = true
            local pos, sz = p.Position, p.Size
            local x0, x1 = pos.X - sz.X * 0.5, pos.X + sz.X * 0.5
            local y0, y1 = pos.Y - sz.Y * 0.5, pos.Y + sz.Y * 0.5
            local z0, z1 = pos.Z - sz.Z * 0.5, pos.Z + sz.Z * 0.5
            minX = (minX == nil) and x0 or math.min(minX, x0)
            maxX = (maxX == nil) and x1 or math.max(maxX, x1)
            minY = (minY == nil) and y0 or math.min(minY, y0)
            maxY = (maxY == nil) and y1 or math.max(maxY, y1)
            minZ = (minZ == nil) and z0 or math.min(minZ, z0)
            maxZ = (maxZ == nil) and z1 or math.max(maxZ, z1)
        end
    end

    if not found then return nil end
    return { minX = minX, minY = minY, minZ = minZ, maxX = maxX, maxY = maxY, maxZ = maxZ }
end

--- Legendary or not, on the one property that shooting does not change.
local function isLegendary(model)
    local base = LEGENDARY_BASE[model.Name]
    if not base then return false end
    local body = model:FindFirstChild("Body")
    if not (body and body:IsA("BasePart")) then return false end
    return body.Size.Y >= base * LEGENDARY_SCALE
end

local function updateLegendary(camera)
    -- a legendary that was killed or despawned must not leave a box in the air
    for model in pairs(LegendaryPool) do
        if model.Parent == nil then dropLegendary(model) end
    end

    local root = workspace:FindFirstChild("WORKSPACE_Entities")
    local animals = root and root:FindFirstChild("Animals")
    if not Config.ESPLegendary or not animals then
        for _, e in pairs(LegendaryPool) do hideLegendary(e) end
        animalAlert.Visible = false
        return
    end

    local origin = camera.CFrame.Position
    local textSize = Config.ESPTextSize
    local nearestName, nearestDist

    for _, model in ipairs(animals:GetChildren()) do
        local e = LegendaryPool[model]

        if not isLegendary(model) then
            if e then hideLegendary(e) end
        else
            local dist = (model:GetPivot().Position - origin).Magnitude
            if not nearestDist or dist < nearestDist then
                nearestName, nearestDist = model.Name, dist
            end

            local box = animalBounds(model)
            local minX, minY, maxX, maxY
            if box then minX, minY, maxX, maxY = project(box, camera) end

            if minX then
                if not e then
                    e = newLegendaryEntry()
                    LegendaryPool[model] = e
                end
                hideLegendary(e)

                if Config.ESPLegendaryBox then
                    e.box.Position = Vector2.new(minX, minY)
                    e.box.Size = Vector2.new(maxX - minX, maxY - minY)
                    e.box.Visible = true
                end

                e.label.Size = textSize
                e.label.Text = string.format(
                    "LEGENDARY %s  %d", string.upper(model.Name), math.floor(dist + 0.5)
                )
                e.label.Position = Vector2.new((minX + maxX) * 0.5, minY - textSize - 3)
                e.label.Visible = true
            elseif e then
                hideLegendary(e)
            end
        end
    end

    -- A legendary worth finding is usually not in front of you, so the nearest
    -- one is announced in the corner whether or not it is on screen.
    if nearestDist and Config.ESPAnimalAlert then
        animalAlert.Text = string.format(
            "legendary %s: %d st", string.lower(nearestName), math.floor(nearestDist + 0.5)
        )
        animalAlert.Visible = true
    else
        animalAlert.Visible = false
    end
end

--=========================== horse boost ===========================--
-- Spurring spends one of the ridden animal's boost charges, and at zero the
-- next spur plays the Exhausted animation and then knocks you off the horse.
-- The counter is a plain field on the animal object, so pinning it at MaxBoosts
-- is all it takes for the boost to never run out. ExhaustedWarning is cleared
-- as well, so a dip on the frame a spur lands cannot latch the knock-out.
local function updateHorseBoost()
    if not Config.HorseBoost then return end

    local wildlife = Global.WildLife
    if type(wildlife) ~= "table" then return end

    local animal
    local ok, res = pcall(function() return wildlife:GetRidingAnimal() end)
    if ok then animal = res end
    if animal == nil then animal = wildlife.RidingAnimal end
    if type(animal) ~= "table" then return end

    local max = animal.MaxBoosts
    if type(max) ~= "number" or max <= 0 then return end
    if animal.Boosts ~= max then animal.Boosts = max end
    animal.ExhaustedWarning = nil
end

--=========================== fast reload ===========================--
-- See the note at the top of the file. The manual reload is GunItemType:Load,
-- and the only thing it reads is SharedData.LoadSpeed: the "Load" animation it
-- plays is keyframed to insert one bullet at a time, so doubling that speed
-- doubles how fast the cylinder/magazine fills. The per-shot cycle reads
-- FireSpeed and ReloadSpeed instead, so the rate between shots is untouched.
--
-- Those values are read when the animation is played, so scaling the config
-- table once covers every weapon from then on, with no per-shot hook to race
-- against a spawned thread. A run that died before it could tear down holds its
-- originals in getgenv(); they are put back before anything is scaled again, so
-- the numbers can never compound.

local FAST_LOAD_FIELDS = { "LoadSpeed", "LoadStartSpeed", "LoadEndSpeed" }
local FAST_LOAD_MULT   = 2

local function playerItems()
    local shared = Global and Global.SharedData
    local items = shared and shared.PlayerItems
    return type(items) == "table" and items or nil
end

local function restoreFastLoad(originals, items)
    if type(originals) ~= "table" then return end
    items = items or playerItems()
    if not items then return end
    for name, saved in pairs(originals) do
        local entry = items[name]
        if type(entry) == "table" then
            for field, value in pairs(saved) do entry[field] = value end
        end
    end
end

local function scaleFastLoad(items)
    local originals = {}
    for name, entry in pairs(items) do
        if type(entry) == "table" then
            local saved, touched = {}, false
            for _, field in ipairs(FAST_LOAD_FIELDS) do
                if tonumber(entry[field]) then
                    saved[field] = entry[field]
                    entry[field] = entry[field] * FAST_LOAD_MULT
                    touched = true
                end
            end
            if touched then originals[name] = saved end
        end
    end
    return originals
end

-- build 7 hooked GunItemType:Shoot instead, and that one did change the firing
-- rate. Take a leftover hook back off, then put back any speeds a run left
-- scaled, before this build touches anything.
local prevShotHook = genv.WW_SA_FastReload
if type(prevShotHook) == "table" and prevShotHook.host ~= nil
    and type(prevShotHook.original) == "function" then
    pcall(function() prevShotHook.host.Shoot = prevShotHook.original end)
end
genv.WW_SA_FastReload = nil

restoreFastLoad(genv.WW_SA_FastLoad)
genv.WW_SA_FastLoad = nil

local FastLoadOriginals = nil

local function updateFastLoad()
    local items = playerItems()
    if not items then return end

    if Config.FastReload == true then
        if FastLoadOriginals then return end
        FastLoadOriginals = scaleFastLoad(items)
        genv.WW_SA_FastLoad = FastLoadOriginals
    elseif FastLoadOriginals then
        restoreFastLoad(FastLoadOriginals, items)
        FastLoadOriginals = nil
        genv.WW_SA_FastLoad = nil
    end
end

--=========================== frame loop ===========================--
track(RunService.RenderStepped, function()
    -- Hold state first: polled, so a dropped InputEnded cannot wedge it and a
    -- mouse release cannot cancel it either.
    State.holding = bindHeld()

    local pc = Global.PlayerCharacter
    State.active = armed() and pc ~= nil and pc.Character ~= nil and pc.RootPart ~= nil
    State.target = State.active and resolveTarget() or nil

    local camera = cam()
    if not camera then return end

    -- circle: always dead centre
    fovCircle.Visible = Config.DrawFOV and Config.Enabled
    if fovCircle.Visible then
        fovCircle.Position = aimOrigin()
        fovCircle.Radius = Config.FOV
        fovCircle.Color = State.target and Color3.fromRGB(255, 64, 64) or Color3.fromRGB(255, 255, 255)
    end

    local sp = State.target and toScreen(State.target.pos)
    lockDot.Visible = sp ~= nil
    if sp then lockDot.Position = sp end

    -- status readout, so it is obvious why nothing is being hit
    hud.Visible = Config.DrawHUD
    if hud.Visible then
        local gunName, isGun = heldItem()
        local label = "off"
        if Config.Enabled then
            if not State.holding then
                label = "hold " .. tostring(Config.HoldKey):gsub("Enum%.", "")
            elseif State.active then
                label = "ON"
            else
                label = "idle"
            end
        end
        hud.Text = string.format(
            "silent aim: %s    target: %s    holding: %s%s    esp: %s",
            label,
            State.target and State.target.player.Name or "-",
            gunName,
            isGun and "" or " (not a gun)",
            Config.ESPEnabled and "on" or "off"
        )
        hud.Color = State.target and Color3.fromRGB(130, 255, 140) or Color3.fromRGB(230, 230, 230)
    end

    updateEsp(camera)
    updateLegendary(camera)
    updateHorseBoost()
    updateFastLoad()
end)

--=========================== interface ===========================--
local torndown = false

local function deleteGuis()
    for _, gui in ipairs(genv.WW_SA_Guis or {}) do
        pcall(function() gui:Destroy() end)
    end
    genv.WW_SA_Guis = {}
    genv.WW_SA_Window = nil

    -- A run that dies part-way never reaches the line that registers its window,
    -- so the registry cannot see the wreckage it left sitting in CoreGui. One
    -- reload that threw during the build left exactly that behind: an empty
    -- black rectangle under the real window, invisible to every later cleanup.
    -- The name is the one thing an orphan can still be recognised by.
    local hidden = gethui and gethui() or nil
    if hidden ~= nil then
        for _, child in ipairs(hidden:GetChildren()) do
            if child.Name == "WW_CombatUI" then
                pcall(function() child:Destroy() end)
            end
        end
    end
end

local function teardown()
    if torndown then return end
    torndown = true

    pcall(function() Utils.GetMouseHit = originalGetMouseHit end)
    pcall(function() Projectile.InitProjectiles = originalInitProjectiles end)
    if FastLoadOriginals then
        restoreFastLoad(FastLoadOriginals)
        FastLoadOriginals = nil
    end
    genv.WW_SA_FastLoad = nil

    for _, c in ipairs(myConns) do
        pcall(function() c:Disconnect() end)
    end
    for _, d in ipairs(myDrawings) do
        pcall(function() d:Remove() end)
    end
    for plr in pairs(EspPool) do
        dropEntry(plr)
    end
    for model in pairs(LegendaryPool) do
        dropLegendary(model)
    end

    if genv.WW_SA_Conns == myConns then genv.WW_SA_Conns = nil end
    if genv.WW_SA_Drawings == myDrawings then genv.WW_SA_Drawings = nil end
end

STATE.onCleanup(teardown)

-- Rebuild the window on every run so the controls always match this code.
-- Every ScreenGui this script has ever created is tracked and destroyed first,
-- so reloads - including ones that died part-way - cannot leave a stacked
-- window behind.
deleteGuis()

--=========================== sleek ui ===========================--
-- Our own window, in place of Rayfield: black shell, orange accent, built from
-- Instances and parented into CoreGui. It exposes the same handful of calls the
-- controls further down already use (CreateTab / CreateToggle / CreateSlider /
-- CreateDropdown / CreateKeybind / CreateButton / CreateDivider), so the feature
-- list, the flags and the callbacks are unchanged - only the drawing is ours.
--
-- Nothing is fetched over HTTP any more, which also removes the one thing that
-- could fail on a bad connection and leave no menu at all.
local TweenService = game:GetService("TweenService")

local Sleek = {}

local function fontOf(name, fallback)
    local ok, f = pcall(function() return Enum.Font[name] end)
    if ok and f ~= nil then return f end
    return fallback
end

local FONT      = fontOf("GothamMedium", Enum.Font.SourceSans)
local FONT_SEMI = fontOf("GothamSemibold", FONT)
local FONT_BOLD = fontOf("GothamBold", Enum.Font.SourceSansBold)

local P = {
    window   = Color3.fromRGB(9, 9, 11),
    header   = Color3.fromRGB(13, 13, 16),
    card     = Color3.fromRGB(17, 17, 21),
    row      = Color3.fromRGB(23, 23, 28),
    rowHover = Color3.fromRGB(31, 31, 37),
    stroke   = Color3.fromRGB(34, 34, 41),
    off      = Color3.fromRGB(50, 50, 60),
    knob     = Color3.fromRGB(237, 237, 243),
    text     = Color3.fromRGB(238, 238, 244),
    muted    = Color3.fromRGB(124, 124, 138),
    accent   = Color3.fromRGB(255, 138, 32),
    accentLo = Color3.fromRGB(96, 52, 14),
    danger   = Color3.fromRGB(255, 84, 84),
}

local function make(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props) do inst[k] = v end
    if parent ~= nil then inst.Parent = parent end
    return inst
end

local function round(inst, radius)
    return make("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, inst)
end

local function outline(inst, colour, transparency)
    return make("UIStroke", {
        Color = colour or P.stroke,
        Thickness = 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, inst)
end

--- Tween that refuses to touch an instance a teardown already destroyed.
local function animate(inst, props, seconds)
    if inst == nil or inst.Parent == nil then return nil end
    local t = TweenService:Create(
        inst,
        TweenInfo.new(seconds or 0.13, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        props
    )
    t:Play()
    return t
end

local function text(parent, props)
    local base = {
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "",
        TextColor3 = P.text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    }
    for k, v in pairs(props) do base[k] = v end
    return make("TextLabel", base, parent)
end

--=========================== config files ===========================--
-- The Rayfield build kept its settings in Rayfield/Configurations. Those names
-- and shapes are reused here - same flags, same files - so nothing the user
-- tuned is lost in the swap: the first run reads the old file, and from then on
-- this window writes its own, which also takes over as the save from that point.
local CONFIG_PATH = "ww_combat.json"
local LEGACY_PATH = "Rayfield/Configurations/ww_silentaim.rfld"

local function readJson(path)
    local ok, exists = pcall(isfile, path)
    if not ok or not exists then return nil end
    local okRead, raw = pcall(readfile, path)
    if not okRead or type(raw) ~= "string" then return nil end
    local okDecode, decoded = pcall(function() return json.decode(raw) end)
    if okDecode and type(decoded) == "table" then return decoded end
    local okLegacy, legacy = pcall(function() return JSONDecode(raw) end)
    if okLegacy and type(legacy) == "table" then return legacy end
    return nil
end

local function writeJson(path, tbl)
    local encoded
    local ok, value = pcall(function() return json.encode(tbl) end)
    if ok and type(value) == "string" then encoded = value end
    if encoded == nil then
        local okLegacy, legacy = pcall(function() return JSONEncode(tbl) end)
        if okLegacy and type(legacy) == "string" then encoded = legacy end
    end
    if encoded == nil then return false end
    return (pcall(writefile, path, encoded))
end

-- EnumItems are the one thing JSON cannot carry, and a bind is an EnumItem.
-- [className, value] round-trips exactly the way Rayfield wrote it, so an old
-- bind still loads and a new one stays readable if the file is ever opened.
local function encodeEnum(v)
    if typeof(v) == "EnumItem" then return { v.EnumType.Name, v.Value } end
    return nil
end

local function decodeEnum(v)
    if type(v) ~= "table" then return nil end
    local class, value = v[1], v[2]
    if type(class) ~= "string" or type(value) ~= "number" then return nil end
    local okType, enumType = pcall(function() return Enum[class] end)
    if not okType or typeof(enumType) ~= "Enum" then return nil end
    local okItem, item = pcall(function() return enumType:FromValue(value) end)
    if not okItem then return nil end
    return item
end

--=========================== window shell ===========================--
function Sleek.newWindow(opts)
    opts = opts or {}

    local WIDTH, HEIGHT = 580, 408
    local HEADER_H = 48
    local RAIL_W = 146

    local gui = make("ScreenGui", {
        Name = "WW_CombatUI",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 1000,
    }, (gethui and gethui()) or game:GetService("CoreGui"))

    local shell = make("Frame", {
        Name = "Window",
        Size = UDim2.fromOffset(WIDTH, HEIGHT),
        Position = UDim2.new(0.5, -WIDTH / 2, 0.5, -HEIGHT / 2),
        BackgroundColor3 = P.window,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, gui)
    round(shell, 10)
    outline(shell, P.stroke)

    -- orange hairline along the top edge, fading out to the right
    local hairline = make("Frame", {
        Size = UDim2.new(1, 0, 0, 2),
        BackgroundColor3 = P.accent,
        BorderSizePixel = 0,
        ZIndex = 3,
    }, shell)
    make("UIGradient", {
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(0.65, 1),
            NumberSequenceKeypoint.new(1, 1),
        }),
    }, hairline)

    local header = make("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, HEADER_H),
        BackgroundColor3 = P.header,
        BorderSizePixel = 0,
    }, shell)

    local logoBox = make("Frame", {
        Size = UDim2.fromOffset(26, 26),
        Position = UDim2.fromOffset(16, 11),
        BackgroundColor3 = P.accent,
        BorderSizePixel = 0,
        ZIndex = 2,
    }, header)
    round(logoBox, 7)
    text(logoBox, {
        Text = "WW",
        Size = UDim2.fromScale(1, 1),
        Font = FONT_BOLD,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(12, 12, 14),
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = 2,
    })

    text(header, {
        Text = opts.title or "WILD WEST",
        Position = UDim2.fromOffset(52, 9),
        Size = UDim2.new(0, 260, 0, 15),
        Font = FONT_BOLD,
        TextSize = 13,
    })
    text(header, {
        Text = opts.subtitle or "",
        Position = UDim2.fromOffset(52, 25),
        Size = UDim2.new(0, 260, 0, 12),
        TextSize = 10,
        TextColor3 = P.accent,
    })

    local function headerButton(glyph, fromRight, tint)
        local b = make("TextButton", {
            Size = UDim2.fromOffset(24, 24),
            Position = UDim2.new(1, fromRight, 0.5, 0),
            AnchorPoint = Vector2.new(1, 0.5),
            BackgroundColor3 = P.row,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
        }, header)
        round(b, 6)
        local g = text(b, {
            Text = glyph,
            Size = UDim2.fromScale(1, 1),
            TextSize = 14,
            TextColor3 = tint or P.muted,
            TextXAlignment = Enum.TextXAlignment.Center,
        })
        track(b.MouseEnter, function()
            animate(b, { BackgroundTransparency = 0 })
            animate(g, { TextColor3 = tint or P.text })
        end)
        track(b.MouseLeave, function()
            animate(b, { BackgroundTransparency = 1 })
            animate(g, { TextColor3 = tint or P.muted })
        end)
        return b
    end

    local closeButton = headerButton("×", -14, P.danger)
    local minButton = headerButton("–", -42)

    local body = make("Frame", {
        Position = UDim2.fromOffset(0, HEADER_H),
        Size = UDim2.new(1, 0, 1, -HEADER_H),
        BackgroundTransparency = 1,
    }, shell)

    local rail = make("Frame", {
        Size = UDim2.new(0, RAIL_W, 1, 0),
        BackgroundColor3 = P.header,
        BorderSizePixel = 0,
    }, body)
    make("UIListLayout", {
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, rail)
    make("UIPadding", {
        PaddingTop = UDim.new(0, 10),
        PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 8),
    }, rail)
    make("Frame", {
        Size = UDim2.new(0, 1, 1, 0),
        Position = UDim2.fromOffset(RAIL_W - 1, 0),
        BackgroundColor3 = P.stroke,
        BorderSizePixel = 0,
    }, body)

    text(body, {
        Text = "RIGHT SHIFT · toggle",
        Position = UDim2.new(0, 8, 1, -22),
        Size = UDim2.new(0, RAIL_W - 16, 0, 14),
        TextSize = 9,
        TextColor3 = P.muted,
        TextXAlignment = Enum.TextXAlignment.Center,
    })

    local pages = make("Frame", {
        Position = UDim2.fromOffset(RAIL_W, 0),
        Size = UDim2.new(1, -RAIL_W, 1, 0),
        BackgroundTransparency = 1,
    }, body)

--=========================== window plumbing ===========================--
    local order = 0
    local function nextOrder()
        order = order + 1
        return order
    end

    local flags = {}          -- flag -> { get = fn, set = fn(value) }
    local saveQueued = false

    local function markDirty()
        if saveQueued then return end
        saveQueued = true
        task.delay(0.6, function()
            saveQueued = false
            local snapshot = {}
            for flag, entry in pairs(flags) do
                local ok, value = pcall(entry.get)
                if ok and value ~= nil then snapshot[flag] = value end
            end
            pcall(writeJson, CONFIG_PATH, snapshot)
        end)
    end

    local function hover(trigger, target, base, lit)
        track(trigger.MouseEnter, function()
            animate(target, { BackgroundColor3 = lit or P.rowHover })
        end)
        track(trigger.MouseLeave, function()
            animate(target, { BackgroundColor3 = base or P.row })
        end)
    end

    local window = { screenGui = gui, name = opts.title, flags = flags, active = 0 }
    local tabs = {}
    window.tabs = tabs

    --- One card holds a run of controls; a divider starts the next one.
    local function newCard(tab)
        local card = make("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = P.card,
            BorderSizePixel = 0,
            LayoutOrder = nextOrder(),
        }, tab.page)
        round(card, 8)
        outline(card)
        make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, card)
        make("UIPadding", {
            PaddingTop = UDim.new(0, 6),
            PaddingBottom = UDim.new(0, 6),
            PaddingLeft = UDim.new(0, 6),
            PaddingRight = UDim.new(0, 6),
        }, card)
        tab.card = card
        return card
    end

    local function cardFor(tab)
        if tab.card ~= nil and tab.card.Parent ~= nil then return tab.card end
        return newCard(tab)
    end

    local function newRow(card, height)
        local r = make("Frame", {
            Size = UDim2.new(1, 0, 0, height),
            BackgroundColor3 = P.row,
            BorderSizePixel = 0,
            LayoutOrder = nextOrder(),
        }, card)
        round(r, 6)
        return r
    end

    function window:SelectTab(index)
        window.active = index
        for i, t in ipairs(tabs) do
            local on = (i == index)
            t.page.Visible = on
            t.indicator.Visible = on
            t.caption.TextColor3 = on and P.accent or P.muted
            t.button.BackgroundTransparency = on and 0 or 1
            if not on then t.button.BackgroundColor3 = P.row end
        end
    end

    function window:SetVisible(visible)
        shell.Visible = visible and true or false
    end

    function window:Toggle()
        window:SetVisible(not shell.Visible)
    end

    function window:Minimize()
        local collapsed = (shell.Size.Y.Offset ~= HEADER_H)
        shell.Size = UDim2.fromOffset(WIDTH, collapsed and HEADER_H or HEIGHT)
        body.Visible = not collapsed
        hairline.Visible = not collapsed
    end

    --- Read the saved file, falling back to the Rayfield one, and push every
    --- stored value back through the control that owns it - which updates the
    --- drawing and fires the control's own callback, so Config ends up correct.
    function window:Load()
        local saved = readJson(CONFIG_PATH) or readJson(LEGACY_PATH)
        if saved == nil then return false end
        for flag, entry in pairs(flags) do
            local value = saved[flag]
            if value ~= nil then
                if flag == "sa_hold2" then value = decodeEnum(value) end
                pcall(entry.set, value)
            end
        end
        return true
    end

    function window:Destroy()
        pcall(function() gui:Destroy() end)
    end

    --- Dragging is done from the pointer's own delta, so it cannot be thrown off
    -- by the GUI inset the way an absolute position can.
    closeButton.MouseButton1Click:Connect(function() window:SetVisible(false) end)
    minButton.MouseButton1Click:Connect(window.Minimize)

    local dragging = false
    track(header.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
        end
    end)
    track(UIS.InputChanged, function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local p = shell.Position
        local d = input.Delta
        local camera = workspace.CurrentCamera
        local maxX = (camera and camera.ViewportSize.X or 1280) - 120
        local maxY = (camera and camera.ViewportSize.Y or 720) - 40
        local x = math.clamp(p.X.Offset + d.X, -WIDTH + 120, maxX)
        local y = math.clamp(p.Y.Offset + d.Y, 0, maxY)
        shell.Position = UDim2.new(p.X.Scale, x, p.Y.Scale, y)
    end)
    track(UIS.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)

--=========================== controls ===========================--
    function window:CreateTab(o)
        local index = #tabs + 1

        local button = make("TextButton", {
            Size = UDim2.new(1, 0, 0, 34),
            BackgroundColor3 = P.row,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            LayoutOrder = index,
        }, rail)
        round(button, 6)
        local indicator = make("Frame", {
            Size = UDim2.new(0, 2, 0, 15),
            Position = UDim2.fromOffset(0, 9.5),
            BackgroundColor3 = P.accent,
            BorderSizePixel = 0,
            Visible = false,
        }, button)
        round(indicator, 1)
        local caption = text(button, {
            Text = string.upper(o.name or "TAB"),
            Size = UDim2.new(1, -16, 1, 0),
            Position = UDim2.fromOffset(14, 0),
            Font = FONT_SEMI,
            TextSize = 11,
            TextColor3 = P.muted,
        })

        local page = make("ScrollingFrame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Visible = false,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            ScrollingDirection = Enum.ScrollingDirection.Y,
            ScrollBarThickness = 3,
            ScrollBarImageColor3 = P.stroke,
        }, pages)
        local layout = make("UIListLayout", {
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }, page)

        -- The canvas is driven from the list's own measured height.
        -- ScrollingFrame.AutomaticCanvasSize looks like the tidier answer and is
        -- a trap in exactly this shape: with cards that are themselves
        -- AutomaticSize as its children, the two size each other, the layout
        -- never settles, and the main thread stops answering anything - the
        -- window still draws, but no tool call gets a reply.
        track(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
            page.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 30)
        end)
        make("UIPadding", {
            PaddingTop = UDim.new(0, 12),
            PaddingBottom = UDim.new(0, 18),
            PaddingLeft = UDim.new(0, 12),
            PaddingRight = UDim.new(0, 10),
        }, page)

        local tab = { name = o.name, button = button, indicator = indicator, caption = caption, page = page, card = nil }
        tabs[index] = tab
        if index == 1 then window:SelectTab(1) end

        track(button.MouseButton1Click, function() window:SelectTab(index) end)
        track(button.MouseEnter, function()
            if tabs[window.active] ~= tab then animate(button, { BackgroundTransparency = 0 }) end
        end)
        track(button.MouseLeave, function()
            if tabs[window.active] ~= tab then animate(button, { BackgroundTransparency = 1 }) end
        end)

        --- A divider is just a heading: it closes the current card so the next
        --- controls land in a fresh one underneath it.
        function tab:CreateDivider(div)
            tab.card = nil
            local title = (div and div.text) and string.upper(div.text) or ""
            if title ~= "" then
                text(page, {
                    Text = title,
                    Size = UDim2.new(1, 2, 0, 14),
                    TextSize = 10,
                    Font = FONT_SEMI,
                    TextColor3 = P.muted,
                    LayoutOrder = nextOrder(),
                })
            end
        end

        function tab:CreateToggle(o)
            local card = cardFor(tab)
            local height = o.description and 54 or 38
            local r = newRow(card, height)

            text(r, {
                Text = o.name,
                Position = UDim2.fromOffset(12, o.description and 7 or 0),
                Size = UDim2.new(1, -72, 0, o.description and 15 or height),
                Font = FONT_SEMI,
                TextSize = 12,
            })
            if o.description then
                text(r, {
                    Text = o.description,
                    Position = UDim2.fromOffset(12, 23),
                    Size = UDim2.new(1, -72, 0, 26),
                    TextSize = 10,
                    TextColor3 = P.muted,
                    TextWrapped = true,
                    TextYAlignment = Enum.TextYAlignment.Top,
                })
            end

            local pill = make("Frame", {
                Size = UDim2.fromOffset(34, 18),
                Position = UDim2.new(1, -12, 0.5, 0),
                AnchorPoint = Vector2.new(1, 0.5),
                BackgroundColor3 = P.off,
                BorderSizePixel = 0,
            }, r)
            round(pill, 9)
            local knob = make("Frame", {
                Size = UDim2.fromOffset(12, 12),
                Position = UDim2.fromOffset(3, 3),
                BackgroundColor3 = P.knob,
                BorderSizePixel = 0,
            }, pill)
            round(knob, 6)

            local state = o.value == true

            local function paint(anim)
                local wanted = state and P.accent or P.off
                local at = UDim2.fromOffset(state and 19 or 3, 3)
                if anim then
                    animate(pill, { BackgroundColor3 = wanted })
                    animate(knob, { Position = at })
                else
                    pill.BackgroundColor3 = wanted
                    knob.Position = at
                end
            end
            paint(false)

            local function set(value, fire)
                state = value == true
                paint(true)
                if fire ~= false and o.callback then pcall(o.callback, state) end
                if fire ~= false then markDirty() end
            end

            -- One transparent button over the whole row: the label, the pill and
            -- the switch all toggle, which is a far bigger target than the pill.
            local hit = make("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
            }, r)
            hover(hit, r)
            track(hit.MouseButton1Click, function() set(not state) end)

            if o.flag then
                flags[o.flag] = { get = function() return state end, set = set }
            end
            return { set = set }
        end

        function tab:CreateSlider(o)
            local card = cardFor(tab)
            local r = newRow(card, 56)

            text(r, {
                Text = o.name,
                Position = UDim2.fromOffset(12, 8),
                Size = UDim2.new(1, -92, 0, 15),
                Font = FONT_SEMI,
                TextSize = 12,
            })
            local readout = text(r, {
                Text = "",
                Position = UDim2.new(1, -84, 0, 8),
                Size = UDim2.new(0, 72, 0, 15),
                Font = FONT_SEMI,
                TextSize = 11,
                TextColor3 = P.accent,
                TextXAlignment = Enum.TextXAlignment.Right,
            })

            local hit = make("TextButton", {
                Text = "",
                BackgroundTransparency = 1,
                AutoButtonColor = false,
                Position = UDim2.fromOffset(10, 36),
                Size = UDim2.new(1, -20, 0, 14),
            }, r)
            local bar = make("Frame", {
                Size = UDim2.new(1, 0, 0, 4),
                Position = UDim2.new(0, 0, 0.5, 0),
                AnchorPoint = Vector2.new(0, 0.5),
                BackgroundColor3 = P.off,
                BorderSizePixel = 0,
            }, hit)
            round(bar, 2)
            local fill = make("Frame", {
                Size = UDim2.new(0, 0, 1, 0),
                BackgroundColor3 = P.accent,
                BorderSizePixel = 0,
            }, bar)
            round(fill, 2)
            local knob = make("Frame", {
                Size = UDim2.fromOffset(12, 12),
                Position = UDim2.new(0, 0, 0.5, 0),
                AnchorPoint = Vector2.new(0.5, 0.5),
                BackgroundColor3 = P.knob,
                BorderSizePixel = 0,
            }, bar)
            round(knob, 6)

            local lo, hi = o.range[1], o.range[2]
            local step = o.increment or 1
            local suffix = o.suffix or ""
            local state = tonumber(o.value) or lo

            local function snap(v)
                v = math.floor((v / step) + 0.5) * step
                return math.clamp(v, lo, hi)
            end

            local function paint()
                local alpha = (hi > lo) and ((state - lo) / (hi - lo)) or 0
                fill.Size = UDim2.fromScale(alpha, 1)
                knob.Position = UDim2.new(alpha, 0, 0.5, 0)
                readout.Text = string.format("%d%s", math.floor(state + 0.5), suffix)
            end

            local function set(value, fire)
                state = snap(tonumber(value) or lo)
                paint()
                if fire ~= false and o.callback then pcall(o.callback, state) end
                if fire ~= false then markDirty() end
            end

            -- Only the X axis is used, so the GUI inset - which is vertical -
            -- cannot shift the value under the pointer.
            local function valueAt(x)
                local width = math.max(bar.AbsoluteSize.X, 1)
                local rel = math.clamp((x - bar.AbsolutePosition.X) / width, 0, 1)
                return lo + rel * (hi - lo)
            end

            local sliding = false
            track(hit.InputBegan, function(input)
                if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
                sliding = true
                animate(knob, { BackgroundColor3 = P.accent }, 0.08)
                set(valueAt(UIS:GetMouseLocation().X), true)
            end)
            track(UIS.InputChanged, function(input)
                if not sliding then return end
                if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
                set(valueAt(UIS:GetMouseLocation().X), true)
            end)
            track(UIS.InputEnded, function(input)
                if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
                sliding = false
                animate(knob, { BackgroundColor3 = P.knob }, 0.08)
            end)
            track(hit.MouseEnter, function()
                animate(knob, { BackgroundColor3 = P.accent })
            end)
            track(hit.MouseLeave, function()
                if not sliding then animate(knob, { BackgroundColor3 = P.knob }) end
            end)

            paint()
            if o.flag then
                flags[o.flag] = { get = function() return state end, set = set }
            end
            return { set = set }
        end

        function tab:CreateDropdown(o)
            local card = cardFor(tab)
            local r = newRow(card, 44)

            text(r, {
                Text = o.name,
                Position = UDim2.fromOffset(12, 0),
                Size = UDim2.new(1, -172, 1, 0),
                Font = FONT_SEMI,
                TextSize = 12,
            })

            local choices = {}
            for i, v in ipairs(o.options) do choices[i] = v end
            local state = type(o.value) == "table" and o.value[1] or o.value
            if state == nil then state = choices[1] end

            local button = make("TextButton", {
                Size = UDim2.fromOffset(140, 26),
                Position = UDim2.new(1, -12, 0.5, 0),
                AnchorPoint = Vector2.new(1, 0.5),
                BackgroundColor3 = P.rowHover,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = false,
            }, r)
            round(button, 5)
            outline(button, P.stroke)
            local shown = text(button, {
                Text = tostring(state),
                Position = UDim2.fromOffset(10, 0),
                Size = UDim2.new(1, -30, 1, 0),
                TextSize = 11,
            })
            text(button, {
                Text = "▾",
                Position = UDim2.new(1, -22, 0.5, 0),
                AnchorPoint = Vector2.new(0, 0.5),
                Size = UDim2.fromOffset(18, 18),
                TextSize = 11,
                TextColor3 = P.muted,
                TextXAlignment = Enum.TextXAlignment.Center,
            })
            track(button.MouseEnter, function() animate(button, { BackgroundColor3 = P.stroke }) end)
            track(button.MouseLeave, function() animate(button, { BackgroundColor3 = P.rowHover }) end)

            local list = nil
            local function closeList()
                if list ~= nil then
                    list:Destroy()
                    list = nil
                end
            end

            local function openList()
                closeList()
                list = make("Frame", {
                    Position = UDim2.fromOffset(
                        button.AbsolutePosition.X,
                        button.AbsolutePosition.Y + button.AbsoluteSize.Y + 4
                    ),
                    Size = UDim2.fromOffset(button.AbsoluteSize.X, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundColor3 = P.card,
                    BorderSizePixel = 0,
                    ZIndex = 40,
                }, shell)
                round(list, 6)
                outline(list, P.stroke)
                make("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)
                make("UIPadding", {
                    PaddingTop = UDim.new(0, 4),
                    PaddingBottom = UDim.new(0, 4),
                    PaddingLeft = UDim.new(0, 4),
                    PaddingRight = UDim.new(0, 4),
                }, list)

                for i, choice in ipairs(choices) do
                    local selected = (choice == state)
                    local item = make("TextButton", {
                        Size = UDim2.new(1, 0, 0, 26),
                        BackgroundColor3 = selected and P.accentLo or P.card,
                        BorderSizePixel = 0,
                        Text = "",
                        AutoButtonColor = false,
                        LayoutOrder = i,
                        ZIndex = 41,
                    }, list)
                    round(item, 4)
                    text(item, {
                        Text = tostring(choice),
                        Position = UDim2.fromOffset(8, 0),
                        Size = UDim2.new(1, -16, 1, 0),
                        TextSize = 11,
                        TextColor3 = selected and P.accent or P.text,
                        ZIndex = 42,
                    })
                    track(item.MouseEnter, function() animate(item, { BackgroundColor3 = P.rowHover }) end)
                    track(item.MouseLeave, function()
                        animate(item, { BackgroundColor3 = selected and P.accentLo or P.card })
                    end)
                    track(item.MouseButton1Click, function()
                        state = choice
                        shown.Text = tostring(choice)
                        closeList()
                        if o.callback then pcall(o.callback, choice) end
                        markDirty()
                    end)
                end
            end

            track(button.MouseButton1Click, function()
                if list ~= nil then closeList() else openList() end
            end)
            -- a click that lands outside the open list closes it
            track(UIS.InputBegan, function(input)
                if list == nil then return end
                if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
                local p = input.Position
                local ap, sz = list.AbsolutePosition, list.AbsoluteSize
                local inside = p.X >= ap.X and p.X <= ap.X + sz.X
                    and p.Y >= ap.Y and p.Y <= ap.Y + sz.Y
                if not inside then closeList() end
            end)

            local function set(value)
                if type(value) == "table" then value = value[1] end
                if value == nil then return end
                state = value
                shown.Text = tostring(value)
                if o.callback then pcall(o.callback, value) end
                markDirty()
            end

            if o.flag then
                flags[o.flag] = { get = function() return state end, set = set }
            end
            return { set = set }
        end

        function tab:CreateKeybind(o)
            local card = cardFor(tab)
            local height = o.description and 54 or 40
            local r = newRow(card, height)

            text(r, {
                Text = o.name,
                Position = UDim2.fromOffset(12, o.description and 7 or 0),
                Size = UDim2.new(1, -152, 0, o.description and 15 or height),
                Font = FONT_SEMI,
                TextSize = 12,
            })
            if o.description then
                text(r, {
                    Text = o.description,
                    Position = UDim2.fromOffset(12, 23),
                    Size = UDim2.new(1, -152, 0, 26),
                    TextSize = 10,
                    TextColor3 = P.muted,
                    TextWrapped = true,
                    TextYAlignment = Enum.TextYAlignment.Top,
                })
            end

            local button = make("TextButton", {
                Size = UDim2.fromOffset(118, 26),
                Position = UDim2.new(1, -12, 0.5, 0),
                AnchorPoint = Vector2.new(1, 0.5),
                BackgroundColor3 = P.rowHover,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = false,
            }, r)
            round(button, 5)
            outline(button, P.stroke)
            local shown = text(button, {
                Text = "",
                Size = UDim2.fromScale(1, 1),
                TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Center,
            })

            -- "None" is Enum.KeyCode.Unknown, which is also what every mouse
            -- input reports as its KeyCode - so Unknown is stored as unbound,
            -- exactly as the Rayfield build did.
            local state = nil
            if typeof(o.value) == "EnumItem" and o.value ~= Enum.KeyCode.Unknown then
                state = o.value
            end
            local listening = false

            local function paint()
                if listening then
                    shown.Text = "press a key"
                    shown.TextColor3 = P.accent
                    button.BackgroundColor3 = P.accentLo
                elseif state == nil then
                    shown.Text = "None"
                    shown.TextColor3 = P.muted
                    button.BackgroundColor3 = P.rowHover
                else
                    shown.Text = state.Name
                    shown.TextColor3 = P.text
                    button.BackgroundColor3 = P.rowHover
                end
            end

            local function commit(value)
                state = value
                listening = false
                paint()
                if o.onChanged then pcall(o.onChanged, state) end
                if o.callback then pcall(o.callback, state) end
                markDirty()
            end

            track(button.MouseButton1Click, function()
                listening = true
                paint()
            end)

            track(UIS.InputBegan, function(input)
                if not listening then return end
                if UIS:GetFocusedTextBox() ~= nil then return end
                if input.UserInputType == Enum.UserInputType.Keyboard then
                    local key = input.KeyCode
                    if key == Enum.KeyCode.Escape or key == Enum.KeyCode.Backspace then
                        commit(nil)
                    else
                        commit(key)
                    end
                elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
                    -- the click that opened the picker is not the bind
                    local ap, sz = button.AbsolutePosition, button.AbsoluteSize
                    local p = input.Position
                    local onButton = p.X >= ap.X and p.X <= ap.X + sz.X
                        and p.Y >= ap.Y and p.Y <= ap.Y + sz.Y
                    if not onButton then commit(Enum.UserInputType.MouseButton1) end
                elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
                    commit(nil)   -- right click clears it
                end
            end)
            paint()

            local function set(value)
                if type(value) == "table" then value = decodeEnum(value) end
                if typeof(value) ~= "EnumItem" or value == Enum.KeyCode.Unknown then
                    commit(nil)
                else
                    commit(value)
                end
            end

            if o.flag then
                flags[o.flag] = { get = function() return encodeEnum(state) end, set = set }
            end
            return { set = set }
        end

        function tab:CreateButton(o)
            local card = cardFor(tab)
            local r = make("TextButton", {
                Size = UDim2.new(1, 0, 0, 38),
                BackgroundColor3 = P.row,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = nextOrder(),
            }, card)
            round(r, 6)
            text(r, {
                Text = o.name,
                Size = UDim2.fromScale(1, 1),
                Font = FONT_SEMI,
                TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Center,
            })
            hover(r, r)
            track(r.MouseButton1Click, function()
                animate(r, { BackgroundColor3 = P.accentLo }, 0.08)
                task.delay(0.15, function()
                    -- the Unload button tears the whole window down, so this
                    -- had better not assume the row still exists
                    pcall(function() animate(r, { BackgroundColor3 = P.row }, 0.08) end)
                end)
                if o.callback then pcall(o.callback) end
            end)
        end

        return tab
    end

    window:SelectTab(1)
    return window
end

--=========================== build the window ===========================--
local Window = Sleek.newWindow({ title = "WILD WEST", subtitle = "silent aim + esp" })

genv.WW_SA_Window = Window
table.insert(genv.WW_SA_Guis, Window.screenGui)

-- Right shift shows and hides the window. The game keeps the cursor locked and
-- hidden while a gun is out, so holster it to click anything - unchanged from
-- the Rayfield build.
track(UIS.InputBegan, function(input)
    if input.KeyCode ~= Enum.KeyCode.RightShift then return end
    if UIS:GetFocusedTextBox() ~= nil then return end
    Window:Toggle()
end)

local Combat = Window:CreateTab({ name = "Combat" })

Combat:CreateToggle({
    name = "Silent Aim",
    description = "Shots go to whoever is inside the circle. The crosshair never moves.",
    value = Config.Enabled,
    flag = "sa_enabled",
    callback = function(v) Config.Enabled = v end,
})

Combat:CreateKeybind({
    name = "Hold to Aim",
    description = "None = always on. Backspace clears it. Keys and mouse both work.",
    value = Config.HoldKey,
    flag = "sa_hold2",
    callback = function() end,
    onChanged = function(k)
        -- "None" is Enum.KeyCode.Unknown, which is exactly what a mouse input
        -- reports as its KeyCode, so it is stored as unbound, not as a bind.
        if k == nil or typeof(k) ~= "EnumItem" or k == Enum.KeyCode.Unknown then
            Config.HoldKey = nil
        else
            Config.HoldKey = k
        end
    end,
})

Combat:CreateSlider({
    name = "FOV",
    description = "Radius in pixels, measured from the middle of the screen.",
    range = { 20, 600 },
    increment = 5,
    value = Config.FOV,
    suffix = "px",
    flag = "sa_fov",
    callback = function(v) Config.FOV = v end,
})

Combat:CreateSlider({
    name = "Max Distance",
    description = "Ignore anyone further away than this. Studs from your camera, the same measure the ESP readout uses.",
    range = { 100, 3000 },
    increment = 25,
    value = Config.MaxRange,
    suffix = "st",
    flag = "sa_maxrange",
    callback = function(v)
        if type(v) == "number" then Config.MaxRange = v end
    end,
})

Combat:CreateDropdown({
    name = "Aim Part",
    options = { "Head", "UpperTorso", "HumanoidRootPart" },
    value = Config.Part,
    flag = "sa_part",
    callback = function(v) Config.Part = type(v) == "table" and v[1] or v end,
})

Combat:CreateDivider({ text = "filters" })

Combat:CreateToggle({
    name = "Visible Only",
    description = "Skip anyone behind cover.",
    value = Config.VisibleOnly,
    flag = "sa_visible",
    callback = function(v) Config.VisibleOnly = v end,
})

Combat:CreateToggle({
    name = "Team Check",
    description = "Ignore Outlaws/Citizens on your own side.",
    value = Config.TeamCheck,
    flag = "sa_team",
    callback = function(v) Config.TeamCheck = v end,
})

Combat:CreateToggle({
    name = "Remove Spread",
    description = "Pins projectile accuracy to 1 so nothing pulls off the target.",
    value = Config.NoSpread,
    flag = "sa_spread",
    callback = function(v) Config.NoSpread = v end,
})

Combat:CreateDivider({ text = "display" })

Combat:CreateToggle({
    name = "Draw FOV Circle",
    value = Config.DrawFOV,
    flag = "sa_draw",
    callback = function(v) Config.DrawFOV = v end,
})

Combat:CreateToggle({
    name = "Show Status Text",
    description = "Tells you whether a target is locked and whether you are holding a gun.",
    value = Config.DrawHUD,
    flag = "sa_hud",
    callback = function(v) Config.DrawHUD = v end,
})

Combat:CreateDivider({ text = "camera" })

Combat:CreateToggle({
    name = "Keep Cursor Hidden",
    description = "Gun out = no cursor and the mouse turns the camera. Holster to click this menu.",
    value = Config.FixCursor,
    flag = "sa_cursor",
    callback = function(v) Config.FixCursor = v end,
})

Combat:CreateDivider({ text = "utility" })

Combat:CreateToggle({
    name = "2x Fast Reload",
    description = "Bullets go in twice as fast. Feeding the gun is quicker; the shot rate is unchanged.",
    value = Config.FastReload,
    flag = "cx_fastreload",
    callback = function(v) Config.FastReload = v end,
})

Combat:CreateToggle({
    name = "Infinite Horse Boost",
    description = "Pin the horse's boost charges full, so spurring never exhausts it or throws you off.",
    value = Config.HorseBoost,
    flag = "cx_horseboost",
    callback = function(v) Config.HorseBoost = v end,
})

Combat:CreateButton({
    name = "Unload",
    callback = function()
        teardown()
        Config.Enabled, Config.ESPEnabled = false, false
        deleteGuis()
    end,
})

local Visuals = Window:CreateTab({ name = "Visuals" })

Visuals:CreateToggle({
    name = "Player ESP",
    description = "Boxes and labels on every rig in WORKSPACE_Entities.Players.",
    value = Config.ESPEnabled,
    flag = "esp_enabled",
    callback = function(v) Config.ESPEnabled = v end,
})

Visuals:CreateDivider({ text = "elements" })

Visuals:CreateToggle({
    name = "Box",
    value = Config.ESPBox,
    flag = "esp_box",
    callback = function(v) Config.ESPBox = v end,
})

Visuals:CreateToggle({
    name = "Box Fill",
    description = "Dark fill behind the box. Off = outline only.",
    value = Config.ESPFill,
    flag = "esp_fill",
    callback = function(v) Config.ESPFill = v end,
})

Visuals:CreateToggle({
    name = "Player Name",
    value = Config.ESPName,
    flag = "esp_name",
    callback = function(v) Config.ESPName = v end,
})

Visuals:CreateToggle({
    name = "Distance",
    description = "Studs from your camera.",
    value = Config.ESPDistance,
    flag = "esp_dist",
    callback = function(v) Config.ESPDistance = v end,
})

Visuals:CreateToggle({
    name = "Health",
    description = "Current health, coloured by percentage.",
    value = Config.ESPHealth,
    flag = "esp_health",
    callback = function(v) Config.ESPHealth = v end,
})

Visuals:CreateToggle({
    name = "Health Bar",
    description = "Vertical bar on the left edge of the box.",
    value = Config.ESPHealthBar,
    flag = "esp_hpbar",
    callback = function(v) Config.ESPHealthBar = v end,
})

Visuals:CreateSlider({
    name = "Text Size",
    range = { 10, 22 },
    increment = 1,
    value = Config.ESPTextSize,
    suffix = "px",
    flag = "esp_size",
    callback = function(v) Config.ESPTextSize = v end,
})

Visuals:CreateDivider({ text = "filters" })

Visuals:CreateToggle({
    name = "Team Check",
    description = "Ignore Outlaws/Citizens on your own side.",
    value = Config.ESPTeam,
    flag = "esp_team",
    callback = function(v) Config.ESPTeam = v end,
})

Visuals:CreateSlider({
    name = "Max Distance",
    description = "Hide anyone further away. 0 = no limit.",
    range = { 0, 2000 },
    increment = 25,
    value = Config.ESPMaxDist,
    suffix = "st",
    flag = "esp_maxdist",
    callback = function(v) Config.ESPMaxDist = v end,
})

Visuals:CreateDivider({ text = "animals" })

Visuals:CreateToggle({
    name = "Legendary Animal ESP",
    description = "Box and label on a legendary spawn - the huge ones. Not limited by the range above.",
    value = Config.ESPLegendary,
    flag = "esp_legendary",
    callback = function(v) Config.ESPLegendary = v end,
})

Visuals:CreateToggle({
    name = "Legendary Box",
    description = "Outline around the animal. Off = just the label.",
    value = Config.ESPLegendaryBox,
    flag = "esp_legendarybox",
    callback = function(v) Config.ESPLegendaryBox = v end,
})

Visuals:CreateToggle({
    name = "Legendary Alert",
    description = "Name and distance of the nearest legendary, top left, even when it is off screen.",
    value = Config.ESPAnimalAlert,
    flag = "esp_animalalert",
    callback = function(v) Config.ESPAnimalAlert = v end,
})

--=========================== auto mine ===========================--
-- Record a run by hand, then replay it. Three kinds of step:
--
--   walk   get to a recorded position. The rigs are server-owned: a CFrame
--          write is snapped back within a frame and Humanoid:Move does nothing
--          (the game pins WalkSpeed near zero whenever its own movement input
--          is idle). What does work is a LinearVelocity on the rig's own root
--          attachment - measured in this client, the rig travels at exactly the
--          speed the constraint is set to.
--   mine   stand on the recorded spot, aim at the recorded ore, work it. The
--          hits go through the game's own mining calls (MiningHandler
--          :HitDeposit plus the pickaxe's MineDeposit activation), so no mouse
--          input is synthesised and a run works with the window unfocused.
--   click  stand on the recorded spot, aim where the player aimed, and press.
--          A proximity prompt is fired directly; anything else is a real click.
--
-- The store trip is part of the recording and replays like anything else.
-- "Sell Ores" also stands on its own: it empties the inventory of ore through
-- the game's own container sell - the same call the store UI makes when a sale
-- is confirmed - so a run can bank its ore without depending on input replay.
--
-- MinePath / the state table live in getgenv() (WW_AM_State) so a reload keeps
-- the recording and the controls stay pointed at the same table.
local function initAutoMine()
    local CollectionService = game:GetService("CollectionService")

    local MinePath = "ww_automine.json"
    local ORE_WORDS = { "Quartz", "Copper", "Iron", "Coal", "Gold", "Silver", "Zinc", "Limestone" }
    local PICKAXES = {
        "Tier7Pickaxe", "Tier6Pickaxe", "Tier5Pickaxe", "Tier4Pickaxe",
        "Tier3Pickaxe", "Tier2Pickaxe", "BasicPickaxe",
    }

    local Mine = {
        recording = false,
        playing = false,
        steps = {},
        dirty = false,
        status = "idle",
        shown = nil,
        speed = 26,      -- studs/s following the recorded path (the game flattens much above 30)
        travel = 30,     -- studs/s getting to the run's starting point
        loop = true,
        swings = 3,      -- most swings spent on one recorded stop (caps a stop's length)
        autosell = true,
        spawn = "Recorded start",
        respawnAt = "Don't respawn",   -- town to reset into before a run
        respawnStart = true,           -- reset the character when a run starts
        holdFrom = nil,                -- while recording: when F went down
        holdAt = nil,                  -- and where it was held from
    }
    genv.WW_AM_State = Mine

    local statusA, statusB
    local amSave

    local function setStatus(s)
        Mine.status = s
    end

    --=========================== rig ===========================--
    local function rig()
        local folder = entityRoot()
        if not (folder and lp) then return nil end
        return folder:FindFirstChild(lp.Name)
    end

    local function root()
        local r = rig()
        if not r then return nil end
        return r:FindFirstChild("HumanoidRootPart") or r.PrimaryPart
    end

    local function here()
        local part = root()
        return part and part.Position or nil
    end

    local function vec(v)
        if type(v) ~= "table" then return nil end
        return Vector3.new(v[1] or 0, v[2] or 0, v[3] or 0)
    end

    local function pack(p)
        return { p.X, p.Y, p.Z }
    end

    --=========================== walker ===========================--
    local Walker = { lv = nil, goal = nil, speed = 14 }

    local function walkerEnsure()
        local part = root()
        if not part then return nil end
        if Walker.lv and Walker.lv.Parent == part then return Walker.lv end
        if Walker.lv then pcall(function() Walker.lv:Destroy() end) end
        local att = part:FindFirstChild("RootRigAttachment") or part:FindFirstChildOfClass("Attachment")
        if not att then return nil end
        local lv = Instance.new("LinearVelocity")
        lv.Name = "WW_AM_Walker"
        lv.Attachment0 = att
        lv.RelativeTo = Enum.ActuatorRelativeTo.World
        lv.ForceLimitMode = Enum.ForceLimitMode.Magnitude
        lv.MaxForce = 1e6
        lv.Enabled = false
        lv.Parent = part
        Walker.lv = lv
        return lv
    end

    local function walkerStop()
        Walker.goal = nil
        if Walker.lv then Walker.lv.Enabled = false end
    end

    local function walkerGo(goal, speed)
        Walker.goal = goal
        Walker.speed = speed or Mine.speed
        local lv = walkerEnsure()
        if lv then lv.Enabled = true end
    end

    local function walkerArrived(radius)
        local p = here()
        if not (p and Walker.goal) then return true end
        local d = Walker.goal - p
        return Vector3.new(d.X, 0, d.Z).Magnitude <= (radius or 3.5)
    end

    --- Called every frame. Vertical motion is left to gravity plus a small nudge
    --- towards the goal's height, so the rig walks over a slope rather than being
    --- pushed through it.
    local function walkerStep()
        local lv = Walker.lv
        if not (lv and lv.Parent) then return end
        local goal = Walker.goal
        if not goal or not Mine.playing then
            if lv.Enabled then lv.Enabled = false end
            return
        end
        local p = here()
        if not p then return end
        local d = goal - p
        local flat = Vector3.new(d.X, 0, d.Z)
        if flat.Magnitude < 0.05 then
            lv.Enabled = false
            return
        end
        lv.VectorVelocity = (flat.Unit * Walker.speed) + Vector3.new(0, math.clamp(d.Y, -6, 6), 0)
        lv.Enabled = true
    end

    --- Anything can wedge a rig - a wall, a shopfront, a fence - and a rig pressed
    --- into one holds a commanded velocity while going nowhere. Each attempt backs
    --- it off and offsets it a little further to one side, which is usually enough
    --- to slide it along the obstacle instead of grinding into the same spot.
    local function escapeFrom(goal, attempt, speed)
        local p = here()
        if not p then return end
        local away = Vector3.new(p.X - goal.X, 0, p.Z - goal.Z)
        if away.Magnitude < 0.1 then
            away = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
        end
        local back = away.Unit
        local side = Vector3.new(-back.Z, 0, back.X) * ((attempt % 2 == 0) and 1 or -1)
        walkerGo(p + back * (3 + attempt) + side * (3 + attempt), speed or Mine.speed)
        local t = os.clock() + 0.3
        while os.clock() < t do task.wait(0.05) end
    end

    --- Walk to a point. Arriving is not the only way out: when the rig stops
    --- covering ground it gets two escape attempts and is then given up on, and the
    --- caller skips a few waypoints - a blocked step costs a second, not the run.
    --- Returns whether the point was reached.
    local function travelTo(goal, speed, timeout, radius)
        if not goal then return false end
        local limit = timeout or 25
        local t0 = os.clock()
        walkerGo(goal, speed)
        local lastPos, lastMove = here(), os.clock()
        local attempts = 0
        while Mine.playing and os.clock() - t0 < limit do
            if walkerArrived(radius) then break end
            task.wait()
            local p = here()
            if p then
                if lastPos and (p - lastPos).Magnitude > 0.6 then
                    lastPos, lastMove = p, os.clock()
                elseif os.clock() - lastMove > 1 then
                    if attempts >= 2 then break end
                    attempts += 1
                    escapeFrom(goal, attempts, speed)
                    walkerGo(goal, speed)
                    lastPos, lastMove = here(), os.clock()
                end
            end
        end
        local arrived = walkerArrived(radius)
        walkerStop()
        task.wait(0.05)
        return arrived
    end

    --- Following the path is a pursuit, not 1159 separate walks: the goal is only
    --- re-pointed and the walker is left running, so the rig carries its speed
    --- through the corners instead of stopping dead at every waypoint. Returns
    --- whether the waypoint was reached.
    local function walkAlong(point)
        local goal = vec(point)
        local p = here()
        if not (goal and p) then return false end
        local function speed()
            local cur = here()
            if not cur then return Mine.speed end
            local far = (Vector3.new(goal.X, 0, goal.Z) - Vector3.new(cur.X, 0, cur.Z)).Magnitude
            return far > 40 and Mine.travel or Mine.speed
        end
        walkerGo(goal, speed())
        local t0 = os.clock()
        local lastPos, lastMove = p, os.clock()
        local attempts = 0
        while Mine.playing and os.clock() - t0 < 8 do
            if walkerArrived(2.5) then return true end
            task.wait()
            local cur = here()
            if cur then
                if (cur - lastPos).Magnitude > 0.6 then
                    lastPos, lastMove = cur, os.clock()
                elseif os.clock() - lastMove > 1 then
                    if attempts >= 2 then return false end
                    attempts += 1
                    escapeFrom(goal, attempts, Mine.speed)
                    walkerGo(goal, speed())
                    lastPos, lastMove = here(), os.clock()
                end
            end
        end
        return walkerArrived(2.5)
    end

    --- Stop on a recorded standing spot before using it: a swing or a store click
    --- only works from roughly where it was recorded.
    local function settlePoint(point, timeout)
        local goal = vec(point)
        if not goal then return false end
        return travelTo(goal, Mine.speed, timeout or 12, 3.5)
    end

    --=========================== path drawing ===========================--
    local pathLines = {}

    local function clearPathLines()
        for _, l in ipairs(pathLines) do
            pcall(function() l:Remove() end)
        end
        table.clear(pathLines)
    end

    local function project(world)
        local camera = workspace.CurrentCamera
        if not camera then return nil end
        local v, onScreen = camera:WorldToViewportPoint(world)
        if not onScreen or v.Z <= 0 then return nil end
        return Vector2.new(v.X, v.Y)
    end

    local trail = newDraw("Line")
    trail.Thickness, trail.Color, trail.Transparency, trail.Visible = 3, P.accent, 0.2, false

    local function drawPath()
        clearPathLines()
        local pts = {}
        for _, step in ipairs(Mine.steps) do
            if step.k == "walk" then
                local p = vec(step.p)
                if p then pts[#pts + 1] = p end
            end
        end
        local stride = math.max(1, math.floor(#pts / 400))
        local sampled = {}
        for i = 1, #pts, stride do sampled[#sampled + 1] = pts[i] end
        for i = 2, #sampled do
            local a, b = project(sampled[i - 1]), project(sampled[i])
            if a and b then
                local l = newDraw("Line")
                l.From, l.To, l.Thickness, l.Color, l.Transparency = a, b, 2, P.accent, 0.45
                pathLines[#pathLines + 1] = l
            end
        end
    end

    --=========================== record trail ===========================--
    -- The route drawn where it is actually walked, so a recording can be watched
    -- as it is laid down instead of only when it is replayed: a ribbon at the
    -- rig's feet plus a flat marker every few studs.
    local recFolder, recTrail, recAttA, recAttB, recLast = nil, nil, nil, nil, nil

    local function recTrailStop()
        for _, inst in ipairs({ recTrail, recAttA, recAttB }) do
            if inst then pcall(function() inst:Destroy() end) end
        end
        if recFolder then pcall(function() recFolder:Destroy() end) end
        recFolder, recTrail, recAttA, recAttB, recLast = nil, nil, nil, nil, nil
    end

    local function recTrailStart()
        recTrailStop()
        local part = root()
        if not part then return end
        local folder = Instance.new("Folder")
        folder.Name = "WW_AM_Trail"
        folder.Parent = workspace
        recFolder = folder

        local a = Instance.new("Attachment")
        a.Position = Vector3.new(0, -2.4, 0.5)
        a.Parent = part
        local b = Instance.new("Attachment")
        b.Position = Vector3.new(0, -2.4, -0.5)
        b.Parent = part
        local t = Instance.new("Trail")
        t.Attachment0, t.Attachment1 = a, b
        t.Lifetime, t.MinLength, t.LightEmission = 3, 0.2, 0.5
        t.FaceCamera = false
        t.Color, t.Transparency = ColorSequence.new(P.accent), NumberSequence.new(0.25)
        t.Parent = part
        recAttA, recAttB, recTrail = a, b, t
    end

    --- A flat marker at the rig's feet, kept a few studs apart so a long route
    --- costs a few hundred parts rather than one per sampled point.
    local function recTrailMark(point)
        if not (recFolder and point) then return end
        if recLast and (point - recLast).Magnitude < 5 then return end
        recLast = point
        local at = Vector3.new(point.X, point.Y - 2.6, point.Z)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { workspace.WORKSPACE_Entities }
        local hit = workspace:Raycast(point, Vector3.new(0, -8, 0), params)
        if hit then at = hit.Position + Vector3.new(0, 0.06, 0) end
        local mark = Instance.new("Part")
        mark.Name = "WW_AM_Mark"
        mark.Size = Vector3.new(1.1, 0.12, 1.1)
        mark.CFrame = CFrame.new(at)
        mark.Anchored, mark.CanCollide, mark.CanQuery, mark.CanTouch = true, false, false, false
        mark.Material, mark.Color, mark.Transparency = Enum.Material.Neon, P.accent, 0.35
        mark.Parent = recFolder
    end

    --=========================== recording ===========================--
    local function pushStep(step)
        Mine.steps[#Mine.steps + 1] = step
        Mine.dirty = true
    end

    local function oreTagOf(model)
        if not model then return nil end
        local info = Global.SharedData and Global.SharedData.OreDepositInfo
        if type(info) == "table" then
            for tag in pairs(info) do
                if CollectionService:HasTag(model, tag) then return tag end
            end
        end
        for _, tag in ipairs(CollectionService:GetTags(model)) do
            if string.find(tag, "Ore", 1, true) or string.find(tag, "Vein", 1, true) then
                return tag
            end
        end
        return nil
    end

    local function recordWalk()
        local p = here()
        if not p then return end
        local last = Mine.steps[#Mine.steps]
        if last and last.k == "walk" then
            local was = vec(last.p)
            if was and (was - p).Magnitude < 1.5 then return end
        end
        pushStep({ k = "walk", p = pack(p) })
    end

    --- Consecutive hits on the same ore collapse into one stop, so a stop keeps
    --- how long it took and roughly how many swings it needed.
    local function recordMine(deposit, hitPos)
        local p = here()
        local aim = hitPos or (deposit and deposit:GetPivot().Position)
        if not (p and aim) then return end
        local last = Mine.steps[#Mine.steps]
        local now = os.clock()
        if last and last.k == "mine" and (now - (last.at or 0)) < 10 then
            local was = vec(last.aim)
            if was and (was - aim).Magnitude < 10 then
                last.swings = (last.swings or 1) + 1
                last.dur = (last.dur or 1) + 0.8
                last.at = now
                Mine.dirty = true
                return
            end
        end
        pushStep({
            k = "mine", p = pack(p), aim = pack(aim), tag = oreTagOf(deposit),
            swings = 1, dur = 1.2, at = now,
        })
    end

    --- What the player pressed, where they were aiming, and - if a prompt was in
    --- front of them - which prompt, so a replay can fire it without input.
    local function recordClick()
        local p = here()
        if not p then return end
        local aimPos, target
        pcall(function()
            local a, b = throughPrevious(originalGetMouseHit, 2000)
            if typeof(a) == "Vector3" then aimPos = a end
            if typeof(b) == "Instance" then target = b end
        end)
        local promptPath
        pcall(function()
            local prompt
            if target and target:IsA("ProximityPrompt") then
                prompt = target
            elseif target then
                prompt = target:FindFirstChildOfClass("ProximityPrompt")
                if not prompt and target.Parent then
                    prompt = target.Parent:FindFirstChildOfClass("ProximityPrompt")
                end
            end
            if prompt then promptPath = prompt:GetFullName() end
        end)
        pushStep({
            k = "click", p = pack(p),
            aim = aimPos and pack(aimPos) or nil,
            target = target and target:GetFullName() or nil,
            promptPath = promptPath,
        })
    end

    -- The pickaxe's own hit entry point. Hooked once; outside a recording it
    -- costs one boolean test per swing.
    local originalHitDeposit
    originalHitDeposit = swap(Global.MiningHandler, "HitDeposit", function(self, deposit, hitPos, hitNormal)
        if Mine.recording then pcall(recordMine, deposit, hitPos) end
        return throughPrevious(originalHitDeposit, self, deposit, hitPos, hitNormal)
    end)
    STATE.onCleanup(function()
        pcall(function() Global.MiningHandler.HitDeposit = originalHitDeposit end)
    end)

    local function recorderTick()
        if not Mine.recording then return end
        recordWalk()
        local p = here()
        if p then
            local from = Mine.tailFrom or p
            local a, b = project(from), project(p)
            if a and b then
                trail.From, trail.To = a, b
                trail.Visible = true
            end
            Mine.tailFrom = p
            recTrailMark(p)
        end
        -- F is the store's hold key - holding it is how loot is sold - so a hold is
        -- kept open until the key comes back up and then stored as a step of its own.
        if Mine.holdFrom and not UIS:IsKeyDown(Enum.KeyCode.F) then
            local at = Mine.holdAt or p
            pushStep({
                k = "hold", p = at and pack(at) or nil, key = "F",
                dur = math.max(0.5, os.clock() - Mine.holdFrom),
            })
            Mine.holdFrom, Mine.holdAt = nil, nil
        end
        setStatus(("recording - %d steps"):format(#Mine.steps))
    end

    local function startRecording()
        Mine.steps = {}
        Mine.dirty = false
        Mine.tailFrom = nil
        Mine.holdFrom, Mine.holdAt = nil, nil
        Mine.recording = true
        clearPathLines()
        recTrailStart()
        recordWalk()
        setStatus("recording")
        print("[auto_mine] recording started")
    end

    local function stopRecording()
        if not Mine.recording then return end
        if Mine.holdFrom then
            Mine.holdFrom, Mine.holdAt = nil, nil
        end
        Mine.recording = false
        trail.Visible = false
        recTrailStop()
        drawPath()
        amSave()
        setStatus(("stopped - %d steps"):format(#Mine.steps))
        print(("[auto_mine] recording stopped, %d steps"):format(#Mine.steps))
    end

    --=========================== mining ===========================--
    local function aimAt(pos, part)
        State.mine = { pos = pos, part = part }
    end

    local function clearAim()
        State.mine = nil
    end

    --- A swing's hitbox hangs off the rig's own facing, and the game only turns the
    --- rig the way the player is looking - so mining on aim alone still means
    --- holding the camera on the ore by hand. Turn the rig at the aim itself, on the
    --- frame and after the game has written its own transform for that frame, so a
    --- swing faces the ore with the camera left wherever it is.
    track(RunService.RenderStepped, function()
        local m = State.mine
        local part = root()
        if not (m and m.pos and part) then return end
        local flat = Vector3.new(m.pos.X - part.Position.X, 0, m.pos.Z - part.Position.Z)
        if flat.Magnitude < 0.25 then return end
        part.CFrame = CFrame.lookAt(part.Position, part.Position + flat.Unit)
    end)

    --- Ore is worked out and grows back, so the instance a hit was recorded on is
    --- a hint rather than a promise: the same ore nearest that spot is used.
    local function scanTag(tag, aim, radius, list)
        for _, model in ipairs(CollectionService:GetTagged(tag)) do
            if model:IsDescendantOf(workspace) then
                local d = (model:GetPivot().Position - aim).Magnitude
                if d <= (radius or 16) then
                    list[#list + 1] = { model = model, d = d }
                end
            end
        end
    end

    --- The tag the hit was recorded against first. The vein tags carry no parts
    --- until you are on top of them, so when that comes back empty any ore close
    --- enough to the recorded spot is taken instead - the spot is where the
    --- swing actually landed.
    local function depositsNear(tag, aim, radius)
        local list = {}
        if not aim then return list end
        if tag then scanTag(tag, aim, radius, list) end
        if #list == 0 then
            local info = Global.SharedData and Global.SharedData.OreDepositInfo
            if type(info) == "table" then
                for other in pairs(info) do
                    if other ~= tag then scanTag(other, aim, radius, list) end
                end
            end
        end
        table.sort(list, function(a, b) return a.d < b.d end)
        return list
    end

    --- OWNED items only. GetItemsRaw() is every item *definition* in the game -
    --- 229 of them - so picking from it equips a pickaxe nobody owns, and handing
    --- an item instance (rather than an {Id, Type} data record) to _DirectEquipItem
    --- leaves EquippedItemData with no Type, which breaks every equip until a
    --- rejoin. The owned items are the container's {Id, Type, StackSize} records.
    local function ownedPickaxe()
        local pd = Global.PlayerData
        local items = pd and pd.InventoryContainer and pd.InventoryContainer.Items
        if type(items) ~= "table" then return nil end
        for _, name in ipairs(PICKAXES) do
            for _, item in pairs(items) do
                if type(item) == "table" and tostring(item.Type) == name and type(item.Id) == "string" then
                    return item
                end
            end
        end
        return nil
    end

    --- Equipping is what puts the item in the server's hands, and the server only
    --- takes a MineDeposit from the pickaxe it believes is equipped. The animated
    --- EquipItem is tried first (that is what picking it from the hotbar does), but
    --- its switch is skipped while another switch runs or for half a second after
    --- one, so the immediate path is the fallback - and _DirectEquipItem wants the
    --- data record, never the item instance.
    --- Equipping is refused outright while the client still believes it is dead,
    --- and that flag outlives the death: after a respawn the rig is standing there
    --- with full health while IsDead is still true, so CanEquipItems says no, every
    --- equip quietly bounces, and the run swings a pickaxe nobody is holding - no
    --- ore, no error, nothing on screen. Clear it while the rig and health disagree.
    local function reviveState()
        local pc = Global.PlayerCharacter
        if not pc or not pc.IsDead then return false end
        local alive = false
        pcall(function()
            local rc = Global.RepCharHandler:GetRepChar(lp)
            alive = (rc and (rc.State.Health or 0) > 0) and true or false
        end)
        if alive and rig() then
            pcall(function() pc.IsDead = false end)
            return true
        end
        return false
    end

    --- The instance the game itself swings with: GetEquippedItem() is just
    --- GetItem(EquippedItemData.Type), and this is the object that carries
    --- NetworkActivate and, once equipped, Hitbox.
    local function bestPickaxe()
        local pc = Global.PlayerCharacter
        if not pc then return nil end
        local record = ownedPickaxe()
        if not record then
            setStatus("no pickaxe in your inventory")
            return nil
        end

        local function held()
            local t
            pcall(function() t = pc:GetEquippedItemType() end)
            return t
        end

        if held() ~= record.Type then
            reviveState()
            pcall(function() pc:EquipItem(record) end)
            local deadline = os.clock() + 3
            while held() ~= record.Type and os.clock() < deadline do
                task.wait(0.1)
            end
            if held() ~= record.Type then
                pcall(function() pc:_DirectEquipItem(record) end)
                task.wait(0.4)
            end
            if held() ~= record.Type then
                -- the dead flag is the usual reason an equip bounces: set it back
                -- only if the game did, then take the immediate path once more
                reviveState()
                pcall(function() pc:_DirectEquipItem(record) end)
                task.wait(0.4)
            end
            if held() ~= record.Type then
                setStatus("cannot equip " .. record.Type)
                return nil
            end
        end

        local item
        pcall(function() item = pc:GetItem(record.Type) end)
        return item
    end

    --- How close to the ore a swing has to be made from. The recorded standing
    --- spot is where the swing that was recorded landed from, so arriving there is
    --- most of it - but a swing that stops a few studs short of the ore is not a
    --- short hit, it is no hit at all, and the last stretch is walked deliberately
    --- rather than trusted to the arrival radius.
    local ENGAGE_RANGE = 3.5

    --- What the server has confirmed about a deposit. Progress and OreRemaining are
    --- replicated values the client never writes - HitDeposit only shows a tooltip -
    --- so a change here is the server agreeing that a hit landed.
    local function depositState(model)
        local info = model and model:FindFirstChild("DepositInfo")
        if not info then return nil end
        local okA, progress = pcall(function() return info.Progress.Value end)
        local okB, ore = pcall(function() return info.OreRemaining.Value end)
        if not (okA and okB) then return nil end
        return { progress = progress, ore = ore }
    end

    --- The game's own swing. PickaxeItemType.Swing plays a ready wind-up the first
    --- time and the module holds a swing lock while one is running, so this asks
    --- until a swing is actually in flight instead of assuming one call did it.
    --- Everything the server wants to see - the MeleeSwing activation and the
    --- hitbox Touched that fires the mining activation - happens inside this call.
    local function swingPickaxe(item)
        if not item then return false end
        local deadline = os.clock() + 0.5
        while os.clock() < deadline do
            if not pcall(function() item:Swing() end) then return false end
            if item.Swinging then return true end
            task.wait(0.05)
        end
        return item.Swinging == true
    end

    --- Close the last studs to the ore, keeping the side the rig is already on.
    local function engageOre(target)
        local p = here()
        if not (p and target) then return false end
        local centre = target.PrimaryPart and target.PrimaryPart.Position or target:GetPivot().Position
        local away = Vector3.new(p.X - centre.X, 0, p.Z - centre.Z)
        if away.Magnitude < 0.05 then away = Vector3.new(1, 0, 0) end
        local goal = centre + away.Unit * ENGAGE_RANGE
        local flat = Vector3.new(goal.X - p.X, 0, goal.Z - p.Z)
        if flat.Magnitude < 0.4 then return true end
        travelTo(Vector3.new(goal.X, p.Y, goal.Z), Mine.speed, 4, 1.5)
        task.wait(0.15)
        return true
    end

    --- The nearest ore in the recorded cluster that still has something in it. A
    --- worked-out deposit stays in the world and still reads as a target, and
    --- swinging at one earns nothing, so it is stepped over rather than hit.
    local function liveOre(list, skip)
        for _, entry in ipairs(list) do
            if entry.model ~= skip then
                local state = depositState(entry.model)
                if state and state.ore > 0 then return entry.model, state end
            end
        end
        return nil
    end

    --- A mining stop. The rig goes to the recorded standing spot, closes the last
    --- studs, and then swings the pickaxe the way a player does - the game's own
    --- Swing, aimed at the ore through the GetMouseHit hook - because the mining
    --- activation rides on that swing's hitbox Touched and not on anything the
    --- client can substitute for it. Each swing is judged by what the server
    --- confirms, not by what was sent.
    ---
    --- A stop is capped twice over: by Swings Per Ore, and by what the ore still
    --- holds. A deposit that is already worked out is worth nothing to swing at, so
    --- the stop steps to the next ore under the same tag or ends - either way in
    --- about a second rather than sitting out the rest of the budget on a dead rock.
    local function doMine(step)
        local aim = vec(step.aim)
        if not aim then return end
        local label = tostring(step.tag or "ore")
        local item = bestPickaxe()
        local list = depositsNear(step.tag, aim, 16)
        local target = liveOre(list) or (list[1] and list[1].model or nil)

        if not target then
            setStatus("no ore at this stop")
            return
        end

        local stand = vec(step.p)
        if stand and here() and (here() - stand).Magnitude > 6 then
            settlePoint(stand, 8)
        end
        aimAt(aim, target)
        task.wait(0.1)

        local swings = math.min(math.max(step.swings or 1, 1), math.max(Mine.swings or 1, 1))
        local hits, misses = 0, 0
        while Mine.playing and hits < swings do
            local before = depositState(target)
            if not before then
                setStatus("no ore at this stop")
                break
            end
            if before.ore <= 0 then
                local nextOre = liveOre(list, target)
                if not nextOre then break end
                target = nextOre
                aimAt(aim, target)
                task.wait(0.05)
                before = depositState(target)
            end
            -- the ore cannot give more than it holds, so a full deposit does not have
            -- to be swung at until the budget runs out
            if before and before.ore > 0 and hits + before.ore < swings then
                swings = hits + before.ore
            end

            swingPickaxe(item)
            -- The deposit may only move when the server says so, and it moves the
            -- moment the server agrees - so watch it closely and move on as soon as
            -- it does rather than sitting out a fixed wait after every swing.
            local after, landed = before, false
            local until_ = os.clock() + 0.6
            while os.clock() < until_ do
                if before then
                    after = depositState(target) or after
                    if after and (after.progress ~= before.progress or after.ore ~= before.ore) then
                        landed = true
                        break
                    end
                end
                task.wait(0.03)
            end
            if landed then
                hits, misses = hits + 1, 0
                setStatus(("mining %s %d/%d"):format(label, hits, swings))
                -- the game's own swing lock is the fastest legal rate: wait out
                -- exactly that and no longer
                local cd = tonumber(item and item.NextCanSwing)
                if cd then
                    local w = cd - os.clock()
                    if w > 0 and w < 1.2 then task.wait(w) end
                end
            else
                -- Nothing confirmed. Either the swing stopped short of the ore or that
                -- ore is worked out, and neither gets better by swinging again from
                -- where the rig is: one walk to close the gap, then the ore is given
                -- up on. Nothing is synthesised - an activation the swing did not earn
                -- is one the server has no reason to take.
                misses += 1
                if misses >= 2 then break end
                engageOre(target)
                local state = depositState(target)
                if not state or state.ore <= 0 then
                    local nextOre = liveOre(list, target)
                    if not nextOre then break end
                    target = nextOre
                end
                aimAt(aim, target)
                task.wait(0.05)
            end
        end
        setStatus(("mined %s %d/%d"):format(label, hits, swings))
        clearAim()
    end

    local function doClick(step)
        local aim = vec(step.aim)
        if aim then
            aimAt(aim)
            task.wait(0.3)
        end
        local fired = false
        if step.promptPath then
            pcall(function()
                local node = game
                for part in string.gmatch(step.promptPath, "[^%.]+") do
                    node = node and node:FindFirstChild(part)
                end
                if node and node:IsA("ProximityPrompt") then
                    fireproximityprompt(node)
                    fired = true
                end
            end)
        end
        if not fired then
            pcall(function()
                if mouse1click then
                    mouse1click()
                else
                    mouse1press()
                    task.wait(0.05)
                    mouse1release()
                end
            end)
        end
        clearAim()
        task.wait(0.35)
    end

    --=========================== selling ===========================--
    --- Ore is a stacked item in the inventory container. Selling goes through the
    --- container's own SellItem - the call the store UI makes when a sale is
    --- confirmed - so the server sees exactly what it sees from the UI.
    local function isOreItem(item)
        local low = string.lower(tostring(item.Type or ""))
        for _, word in ipairs(ORE_WORDS) do
            if string.find(low, string.lower(word), 1, true) then return true end
        end
        return string.find(low, "ore", 1, true) ~= nil or string.find(low, "vein", 1, true) ~= nil
    end

    --- Selling is not a call the client makes: the store listens for a held key and
    --- settles the sale on the server when the hold finishes, so the key is held the
    --- way a player holds it. The game's own action is driven directly here - the
    --- same handler the key itself lands in - so it works with the client unfocused;
    --- the executor's key send is only the fallback.
    local holdAction = { F = "InteractSecondary", E = "Interact", G = "InteractTertiary" }
    local VK = { F = 70, E = 69, G = 71 }

    local function holdKey(name, seconds)
        local key = string.upper(tostring(name or "F"))
        local hold = math.max(seconds or 1.5, 0.3)
        local action
        pcall(function()
            local handler = Global.InputHandler
            action = handler and handler:GetAction(holdAction[key] or key)
        end)
        if action and action.HandleInput then
            local function fire(state)
                pcall(function()
                    action:HandleInput(action.Name or holdAction[key] or key, state, nil, true)
                end)
            end
            fire(Enum.UserInputState.Begin)
            local t = os.clock() + hold
            while os.clock() < t do task.wait(0.1) end
            fire(Enum.UserInputState.End)
            return true
        end
        local vk = VK[key]
        if not vk or type(keypress) ~= "function" then return false end
        if not pcall(keypress, vk) then return false end
        local t = os.clock() + hold
        while os.clock() < t do task.wait(0.1) end
        pcall(function() if type(keyrelease) == "function" then keyrelease(vk) end end)
        return true
    end

    local function oreCount(container)
        local items = container and container.Items
        if type(items) ~= "table" then return 0 end
        local n = 0
        for _, item in pairs(items) do
            if type(item) == "table" and isOreItem(item) then n += 1 end
        end
        return n
    end

    --- Selling is the store's hold key and nothing else: one hold sells the whole bag
    --- in a single server pass. The per-item container call is not made any more - a
    --- remote per ore in the bag is exactly the burst that gets a sale put on
    --- cooldown - and a run whose sale did not land does not try again inside the
    --- cooldown window, so the next round is not starting into a locked store.
    local SELL_COOLDOWN = 45
    local sellAt = 0

    local function sellOres(force)
        local pd = Global.PlayerData
        local container = pd and pd.InventoryContainer
        if not container then return 0 end
        local before = oreCount(container)
        if before == 0 then return 0 end
        if not force and (os.clock() - sellAt) < SELL_COOLDOWN then
            setStatus("sell on cooldown - skipped")
            return 0
        end
        sellAt = os.clock()
        setStatus("holding F to sell")
        holdKey("F", 3)
        -- the server settles the sale as the hold ends, so watch the bag rather than
        -- assuming it landed
        local after = before
        local t = os.clock() + 1.5
        while os.clock() < t do
            task.wait(0.2)
            after = oreCount(container)
            if after < before then break end
        end
        return math.max(before - after, 0)
    end

    --=========================== spawn ===========================--
    local function townNames()
        local list = {}
        local folder = Global.SharedData and Global.SharedData.SpawnInfoFolder
        if folder then
            for _, child in ipairs(folder:GetChildren()) do
                list[#list + 1] = child.Name
            end
        end
        table.sort(list)
        return list
    end

    --- A named town resolves through the game's own spawn info first and the
    --- spawn region tag after it; anything unresolved simply skips the trip.
    local function spawnPoint(name)
        if name == "Current position" then return here() end
        if not name or name == "Recorded start" then
            for _, step in ipairs(Mine.steps) do
                if step.k == "walk" then return vec(step.p) end
            end
            return here()
        end
        local folder = Global.SharedData and Global.SharedData.SpawnInfoFolder
        local child = folder and folder:FindFirstChild(name)
        if child then
            if child:IsA("BasePart") then return child.Position end
            if child:IsA("Model") then
                local part = child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
                if part then return part.Position end
            end
            if child:IsA("ObjectValue") and child.Value and child.Value:IsA("BasePart") then
                return child.Value.Position
            end
        end
        for _, part in ipairs(CollectionService:GetTagged("SpawnRegion_" .. name)) do
            if part:IsA("BasePart") then return part.Position end
        end
        return nil
    end

    --=========================== respawn ===========================--
    --- Respawn is the reset button's own remote followed by the spawn menu the game
    --- opens for it. The menu is driven exactly as a player drives it - press the
    --- town's button, then press Accept - because the remote that Accept sends is
    --- not readable. Accept is ignored while the chosen region streams back in, and
    --- there is no flag to wait on for that, so it is simply pressed until the menu
    --- closes under it.
    local function respawnUi()
        local pg = lp and lp:FindFirstChild("PlayerGui")
        return pg and pg:FindFirstChild("NewSpawnUI") or nil
    end

    local function press(button)
        if not (button and firesignal) then return false end
        if pcall(firesignal, button.Activated) then return true end
        return pcall(firesignal, button.MouseButton1Click)
    end

    local function townButton(ui, town)
        local screen = ui:FindFirstChild("Screen")
        local body = screen and screen:FindFirstChild("SideBar")
        body = body and body:FindFirstChild("Body")
        if not body then return nil end
        for _, d in ipairs(body:GetDescendants()) do
            if d:IsA("GuiButton") and d.Name == town and d.Visible then return d end
        end
        return nil
    end

    local function respawnAt(town)
        local ui = respawnUi()
        if not ui then
            setStatus("no spawn menu")
            return false
        end
        if not ui.Enabled then
            setStatus("resetting character")
            pcall(function() Global.Network:FireServer("RespawnTriggered") end)
            local t = os.clock() + 20
            while os.clock() < t and not ui.Enabled do task.wait(0.2) end
        end
        if not ui.Enabled then
            setStatus("spawn menu did not open")
            return false
        end
        task.wait(0.8)

        local screen = ui:FindFirstChild("Screen")
        local accept = screen and screen:FindFirstChild("AcceptButton")
        if not accept then
            setStatus("no accept button")
            return false
        end

        if type(town) == "string" and town ~= "" and town ~= "Don't respawn" then
            local button = townButton(ui, town)
            if button then
                setStatus("spawning at " .. town)
                press(button)
            else
                setStatus(town .. " is not offered here")
            end
        end

        local deadline = os.clock() + 60
        while os.clock() < deadline and ui.Enabled do
            press(accept)
            local slice = os.clock() + 1.5
            while os.clock() < slice and ui.Enabled do task.wait(0.2) end
        end

        setStatus("waiting for character")
        local rigT = os.clock() + 20
        while os.clock() < rigT and not here() do task.wait(0.25) end
        if here() then
            walkerEnsure()
            task.wait(0.4)
        end
        return here() ~= nil
    end

    --=========================== playback ===========================--
    local function playRun()
        local goal = spawnPoint(Mine.spawn)
        if goal then
            setStatus("travelling to start")
            -- a leg over open ground; walking a straight line through a town is
            -- what the recorded path is for
            travelTo(goal, Mine.travel, 25, 4)
        end
        local i = 1
        while i <= #Mine.steps do
            if not Mine.playing then break end
            local step = Mine.steps[i]
            setStatus(("%s %d/%d"):format(step.k, i, #Mine.steps))
            if step.k == "walk" then
                -- a waypoint the rig cannot reach is skipped in a small jump, so a
                -- wall costs a short detour instead of a stall on every step
                i += walkAlong(step.p) and 1 or 6
            elseif step.k == "mine" then
                settlePoint(step.p, 12)
                doMine(step)
                i += 1
            elseif step.k == "click" then
                settlePoint(step.p, 12)
                doClick(step)
                i += 1
            elseif step.k == "hold" then
                settlePoint(step.p, 12)
                setStatus(("holding %s"):format(tostring(step.key or "F")))
                holdKey(step.key or "F", step.dur or 1.5)
                i += 1
            else
                i += 1
            end
        end
        walkerStop()
        clearAim()
        if Mine.playing and Mine.autosell then
            setStatus("selling ore")
            local n = sellOres()
            setStatus(n > 0 and ("run finished - sold %d ore"):format(n)
                or "run finished - sale did not land")
        end
        return Mine.playing
    end

    local function startRun()
        if Mine.recording then stopRecording() end
        if #Mine.steps == 0 then
            setStatus("nothing recorded yet")
            return
        end
        if Mine.playing then return end
        Mine.playing = true
        task.spawn(function()
            local town = Mine.respawnAt
            if Mine.respawnStart and type(town) == "string" and town ~= "" and town ~= "Don't respawn" then
                setStatus("respawning at " .. town)
                respawnAt(town)
            end
            while Mine.playing do
                reviveState()
                playRun()
                if not Mine.loop then break end
                task.wait(0.4)
            end
            Mine.playing = false
            walkerStop()
            clearAim()
            setStatus("idle")
            print("[auto_mine] run stopped")
        end)
    end

    local function stopRun()
        Mine.playing = false
        walkerStop()
        clearAim()
        setStatus("stopping")
    end

    --=========================== file ===========================--
    amSave = function()
        local out = { version = 1, spawn = Mine.spawn, respawnAt = Mine.respawnAt, steps = {} }
        for _, step in ipairs(Mine.steps) do
            out.steps[#out.steps + 1] = {
                k = step.k, p = step.p, aim = step.aim, tag = step.tag,
                swings = step.swings, dur = step.dur, promptPath = step.promptPath,
                key = step.key,
            }
        end
        pcall(writeJson, MinePath, out)
        Mine.dirty = false
    end

    local function amLoad()
        local data = readJson(MinePath)
        if type(data) ~= "table" or type(data.steps) ~= "table" then return false end
        Mine.steps = data.steps
        if type(data.spawn) == "string" then Mine.spawn = data.spawn end
        if type(data.respawnAt) == "string" then Mine.respawnAt = data.respawnAt end
        return true
    end

    --=========================== window ===========================--
    local AutoWindow = Sleek.newWindow({ title = "AUTO MINE", subtitle = "record + replay" })
    table.insert(genv.WW_SA_Guis, AutoWindow.screenGui)
    local autoShell = AutoWindow.screenGui:FindFirstChild("Window")
    if autoShell then
        -- beside the main window rather than straight over it; it drags as usual
        autoShell.Position = UDim2.new(0.5, 46, 0.5, -204)
    end
    AutoWindow:SetVisible(false)

    local function statusLine(tab)
        return text(tab.page, {
            Text = "idle",
            Size = UDim2.new(1, -24, 0, 16),
            Font = FONT_SEMI,
            TextSize = 11,
            TextColor3 = P.accent,
            LayoutOrder = 900,
        })
    end

    local RecordTab = AutoWindow:CreateTab({ name = "Record" })
    statusA = statusLine(RecordTab)

    RecordTab:CreateButton({
        name = "Start Recording Path",
        callback = function() startRecording() end,
    })
    RecordTab:CreateButton({
        name = "Stop Recording",
        callback = function() stopRecording() end,
    })
    RecordTab:CreateButton({
        name = "Clear Path",
        callback = function()
            Mine.steps = {}
            Mine.dirty = false
            clearPathLines()
            setStatus("path cleared")
        end,
    })
    RecordTab:CreateButton({
        name = "Show / Hide Recorded Path",
        callback = function()
            if #pathLines > 0 then clearPathLines() else drawPath() end
        end,
    })
    RecordTab:CreateDivider({ text = "walk, mine, click, and hold F at the store - a held F is recorded as its own step" })

    local RunTab = AutoWindow:CreateTab({ name = "Auto Mine" })
    statusB = statusLine(RunTab)

    local spawnOptions = { "Recorded start", "Current position" }
    for _, town in ipairs(townNames()) do
        spawnOptions[#spawnOptions + 1] = town
    end

    RunTab:CreateDropdown({
        name = "Spawn Location",
        description = "Where a run starts. The bot travels here first, then follows the recording.",
        options = spawnOptions,
        value = Mine.spawn,
        callback = function(v) Mine.spawn = v end,
    })

    local respawnOptions = { "Don't respawn" }
    for _, town in ipairs(townNames()) do
        respawnOptions[#respawnOptions + 1] = town
    end

    RunTab:CreateDropdown({
        name = "Respawn At",
        description = "A town from the game's own spawn menu. Pick one and a run resets the character into it first.",
        options = respawnOptions,
        value = Mine.respawnAt,
        callback = function(v) Mine.respawnAt = v end,
    })
    RunTab:CreateToggle({
        name = "Respawn On Start",
        description = "Reset the character and spawn at the town above when a run starts.",
        value = Mine.respawnStart,
        callback = function(v) Mine.respawnStart = v and true or false end,
    })
    RunTab:CreateButton({
        name = "Respawn Now",
        callback = function()
            local town = Mine.respawnAt
            task.spawn(function()
                if type(town) == "string" and town ~= "" and town ~= "Don't respawn" then
                    respawnAt(town)
                else
                    pcall(function() Global.Network:FireServer("RespawnTriggered") end)
                    setStatus("respawn requested")
                end
            end)
        end,
    })
    RunTab:CreateDivider({ text = "the game flattens anything much above 30 st/s, so ~26-30 is the fast setting" })

    RunTab:CreateSlider({
        name = "Path Speed",
        range = { 4, 30 },
        increment = 1,
        value = Mine.speed,
        suffix = " st/s",
        callback = function(v) Mine.speed = v end,
    })
    RunTab:CreateSlider({
        name = "Travel Speed",
        range = { 10, 40 },
        increment = 2,
        value = Mine.travel,
        suffix = " st/s",
        callback = function(v) Mine.travel = v end,
    })
    RunTab:CreateSlider({
        name = "Swings Per Ore",
        range = { 1, 12 },
        increment = 1,
        value = Mine.swings,
        suffix = "x",
        callback = function(v) Mine.swings = v end,
    })
    RunTab:CreateDivider({ text = "Swings Per Ore caps a stop: lower is a faster run, higher empties the ore" })
    RunTab:CreateToggle({
        name = "Loop Runs",
        value = Mine.loop,
        callback = function(v) Mine.loop = v and true or false end,
    })
    RunTab:CreateToggle({
        name = "Sell Ore After Each Run",
        description = "One hold of the store's sell key at the end of a run, with a cooldown so a failed sale is not retried into a lockout.",
        value = Mine.autosell,
        callback = function(v) Mine.autosell = v and true or false end,
    })
    RunTab:CreateButton({
        name = "Start Auto Mine",
        callback = function() startRun() end,
    })
    RunTab:CreateButton({
        name = "Stop",
        callback = function() stopRun() end,
    })
    RunTab:CreateButton({
        name = "Sell Ores Now",
        description = "One hold of the store's sell key. Sells in a single pass rather than a burst of requests.",
        callback = function()
            setStatus(("sold %d ore"):format(sellOres(true)))
        end,
    })
    RunTab:CreateButton({
        name = "Hold F (Sell Loot)",
        description = "Holds the store's own sell key for three seconds, wherever the character is standing.",
        callback = function()
            task.spawn(function()
                setStatus("holding F")
                holdKey("F", 3)
                setStatus("held F")
            end)
        end,
    })
    RunTab:CreateButton({
        name = "Save Path",
        callback = function()
            amSave()
            setStatus("saved")
        end,
    })

    -- the entry point on the main window
    Window:CreateTab({ name = "Mine" }):CreateButton({
        name = "Auto Mine",
        callback = function() AutoWindow:Toggle() end,
    })

    --=========================== wiring ===========================--
    if amLoad() then
        drawPath()
    end

    track(RunService.Heartbeat, function()
        walkerStep()
        recorderTick()
        if Mine.status ~= Mine.shown then
            Mine.shown = Mine.status
            if statusA and statusA.Parent then statusA.Text = Mine.status end
            if statusB and statusB.Parent then statusB.Text = Mine.status end
        end
    end)

    track(UIS.InputBegan, function(input, processed)
        if not Mine.recording then return end
        -- The store's hold key is recorded where it is held, whether or not the game
        -- consumed the press.
        if input.UserInputType == Enum.UserInputType.Keyboard
            and input.KeyCode == Enum.KeyCode.F then
            Mine.holdFrom, Mine.holdAt = os.clock(), here()
        end
        if processed then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            pcall(recordClick)
        end
    end)

    STATE.onCleanup(function()
        Mine.recording = false
        Mine.playing = false
        Walker.goal = nil
        if Walker.lv then pcall(function() Walker.lv:Destroy() end) end
        clearPathLines()
        recTrailStop()
        if Mine.dirty and #Mine.steps > 0 then pcall(amSave) end
        print("[auto_mine] cleaned")
    end)

    print(("[auto_mine] ready - %d steps loaded"):format(#Mine.steps))
end

initAutoMine()

-- Pull back whatever the Rayfield build had saved, so nothing tuned is lost.
-- It writes its own file from the next change onwards, but the flag names and
-- the file shape are the same, so the two are interchangeable.
Window:Load()

-- Hold the script open so the hooks and loop stay installed.
while STATE.alive() do
    task.wait(0.25)
end

teardown()
