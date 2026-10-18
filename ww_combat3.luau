--[[
    Silent Aim + Player ESP + Extras - The Wild West
    =====================================================================
    BUILD 13

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

    INFINITE AMMO (build 9).
      There are two ammo models in this game and they are not the same shape,
      which is why handling only the first one leaves the other guns running
      dry. A chambered gun (LancasterPistol, MaxAmmo 4) keeps the cylinder
      itself in State.ChamberData.bullets, one word per barrel - "unused" while
      a round sits in it, "used" once it has been fired, "eject" for the
      instant a reload is swapping it out - and Ammo is only how many of those
      say "unused". There the cylinder is the gate, so raising the tally alone
      does not fill the gun, it breaks it: the readout reads full, every
      chamber reads spent, the fire path finds nothing to shoot and the load
      path sees no room to fill, and from then on the gun neither fires nor
      reloads. The chamber and the tally therefore move together or not at all.
      A plain gun (MusketJezail MaxAmmo 1, Cattleman MaxAmmo 6) has no chamber
      table anywhere on it: a shot simply takes Ammo down by one and the reload
      puts it back, so Ammo is the whole state and holding it at MaxAmmo is the
      entire job. Both arms only ever raise what has already been spent, so a
      gun nobody has fired is never written to, and nothing is hooked and
      nothing is stored - an unload or a crash leaves every gun exactly as its
      own reload would have.

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

    FPS BOOST (build 9).
      A "Perf" tab. This map is heavy - a live count found 889 ParticleEmitters,
      620 PointLights, 96 Beams, 90 Decals, 79 Textures, 73 SurfaceAppearances
      and ~18 post effects under Lighting - and none of it is server-
      authoritative, so switching the expensive half off locally cannot desync
      anything the server cares about. Nothing is DESTROYED: each effect is
      disabled where it stands and its previous value kept, so the toggle is
      exactly reversible. One pass over the 78k Workspace instances costs ~100ms
      in a single go, so the sweep is spread across frames in 1000-instance
      slices and aborts the instant the toggle goes off or the profile changes.
      Effects that stream in afterwards - a campfire, a spawned burst - are
      caught by a DescendantAdded hook rather than by a second sweep.
      A second, independent control raises or removes Roblox's 60 fps ceiling
      (setfpscap); the cap that was in force at load is restored on unload.

    WALKING DOWN A DROP (build 10).
      Off a ledge the rig is LOWERED onto the next waypoint instead of let go
      of. The walker drives the rig with a LinearVelocity, which is a velocity
      constraint rather than a push - so while it is on the vector it is given
      is the rig's actual velocity, gravity included, and a bounded downward Y
      sets the RATE of the descent rather than shoving it through the floor.
      Left to gravity the drop accelerates the whole way down, the landing is an
      impact, and an impact ragdolls the rig, which stops the run dead until it
      has been stood back up. The rate ramps in rather than snapping, is capped
      by the Descent Speed slider, and eases out across the last studs so the
      touchdown is a placement; horizontal travel is unchanged the whole way, so
      the rig still arrives over the waypoint it was walking to.

    TOUCH (build 11, superseded in 13).
      The window used to be drawn by this script, so touch had to be taught to it
      by hand: a finger reports Touch where a mouse reports MouseButton1 (the top
      bar dragged from either, sliders pressed, dragged and released from either),
      the keybind picker cleared its bind on a tap instead of waiting forever for
      a key a phone does not have, and rows, pills and knobs were sized for a
      thumb on a device with no keyboard. Rayfield handles its own input now, so
      all of that went with the window. What is left of the idea is one rule:
      `PHONE` means touch WITHOUT a keyboard, and on a phone the aim simply
      follows the Silent Aim switch.

    WHERE THE WINDOW ACTUALLY IS (build 12, superseded in 13).
      Geometry this script used to own: a drag clamp in absolute space, a first
      placement centred by the screen rather than by scale (the window sat in a
      container the engine had already pushed down by the Roblox bar), and an
      outside-tap test against each window's own rectangle. Rayfield owns its
      frame and its own clamp now, so the saved file and the flags are all that
      is still ours to place.

    RAYFIELD GEN2 (build 13).
      The interface is Rayfield Gen2, fetched once per run. The script's own
      window - shell, rail, cards, rows, dock and all - is gone. What replaces it
      is a thin adapter (the "rayfield ui" section) that hands the same calls to
      Rayfield, so no feature wiring changed: the tabs, the toggles, the sliders,
      the dropdowns, the keybind and the buttons are the same code they were.

        * ONE WINDOW. Gen2 builds a single window, so the recorder's Record and
          Auto Mine tabs are folded in beside Combat, Visuals, Perf, Interface
          and Mine. "Auto Mine" on the Mine tab opens the window on the Record
          tab, which is what the second window used to do.

        * THE WAY BACK IN. Hidden, Gen2 folds into a small bar at the top of the
          screen reading "WILD WEST" / "Tap to show" - tapping that bar brings
          the menu back, and RightShift is bound as the show/hide key. On a phone
          the bar is the only way in, which is why it is left on. The script
          binds no key of its own: a second listener on the same key would
          toggle the window twice per press and look like it did nothing.

        * THE AIM IS ONE SWITCH. There is no latch and no floating AIM button any
          more. The Silent Aim switch is the whole gate, on a phone as much as on
          a desktop: on a phone the "Hold to Aim" row is not built at all (there
          is no key to bind) and `bindHeld` answers true, so the aim follows the
          switch exactly as it does on a desktop with nothing bound, and a bind
          saved on a desktop is dropped on the way in. The game's own aim button
          is what aims; silent aim only redirects where that shot goes while the
          switch is on.

        * THE SAVED FILE IS STILL OURS. The window is created without Gen2's
          `configuration` table and the elements without flags, so Gen2 saves
          nothing of its own; the flags still feed ww_combat.json and the old
          Rayfield/Configurations file is still read once, so nothing tuned is
          lost across either swap.

        * WHAT WENT WITH THE WINDOW. The round badge, the AIM button and its
          grip, tap-outside-to-hide, double-tap-header-to-minimise, the drag
          clamp, the phone-sized chrome and the wrapped dividers - all of them
          were properties of a window this script drew itself. Gen2's own top
          bar, its own collapsed bar and its own touch handling replace them.

        * THE ONE THING TO KNOW ABOUT GEN2. It frees the mouse and re-asserts
          that on every cursor property change, which is what made aiming with
          the menu open feel wrong in the old Rayfield build; `mouseOverride` is
          switched off when the window is created, so the game's own cursor lock
          stands. Its toggle key is set to RightShift at the same moment.
]]

--=========================== services ===========================--
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local RS         = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer

--=========================== input shape ===========================--
-- Two flags rather than one. TOUCH says a finger can be used; PHONE says a
-- finger is all there is. A Windows tablet with a keyboard reports both touch
-- and a keyboard, and it should keep the desktop behaviour - it can still press
-- RightShift and hold a key. A phone cannot, which is why the "Hold to Aim" row
-- is not built there and the aim follows the Silent Aim switch alone.
--
-- Nothing here has to measure the screen or the topbar's inset any more: the
-- window is Rayfield's, so it is Rayfield that is dragged, clamped and kept on
-- screen.
local TOUCH = UIS.TouchEnabled
local PHONE = TOUCH and not UIS.KeyboardEnabled

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
    InfiniteAmmo    = false,
    -- performance
    FPSBoost        = false,
    FPSProfile      = "Balanced",  -- Light | Balanced | Aggressive
    FPSCap          = 60,          -- 0 = uncapped
}

local BUILD = 13

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

-- A key cannot be held on a phone, so a bind saved on a desktop is dropped here
-- rather than left in the config to gate an aim nothing on the device could arm.
-- With no bind, `bindHeld` answers true and the Silent Aim switch is the whole
-- gate - the same reading a desktop with nothing bound has.
if PHONE then Config.HoldKey = nil end

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
    -- One rule everywhere: the Silent Aim switch is the whole gate and the bind is
    -- the only thing that can narrow it. A phone has no key to hold, so there
    -- `bindHeld` answers true and the aim follows the switch exactly as it does on
    -- a desktop with nothing bound - which is what "turn it on and silent aim is
    -- on" means on either.
    if not Config.Enabled then return false end
    return State.holding
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
    -- A phone has no keys at all: nothing can be held, so nothing gates the aim
    -- there and the Silent Aim switch is the whole story.
    if PHONE then return true end
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

--=========================== infinite ammo ===========================--
-- See the note at the top of the file. There are two ammo models and this
-- handles both, because they are not the same shape:
--
--   chambered - State.ChamberData.bullets holds one word per barrel,
--     "unused" / "used" / "eject", and Ammo is nothing but the number of
--     "unused" ones. The cylinder is the gate here, so raising the tally on
--     its own deadlocks the gun: it reads full, has nothing to shoot and no
--     room to load. The chamber and the tally are written together.
--
--   plain - no chamber table exists on the item at all (a shot just takes Ammo
--     down one, the reload puts it back), so Ammo is the whole state and
--     holding it at MaxAmmo is the entire job.
--
-- Both arms only ever raise what has already been spent, so a gun nobody has
-- fired is never written to and a reload in flight is not fought with. The
-- loop is one walk of the chambers per frame - four comparisons for a
-- revolver, a single number check for everything else. Nothing is hooked and
-- nothing is stored: the state held is the state the gun's own reload would
-- have left, so there is nothing to put back in teardown().

local AMMO_SPENT, AMMO_READY = "used", "unused"

local function holdAmmo()
    local pc = Global and Global.PlayerCharacter
    if not pc then return end

    local ok, item = pcall(function() return pc:GetEquippedItem() end)
    if not ok or type(item) ~= "table" then return end

    local max = tonumber(item.MaxAmmo)
    if not max then return end

    local chambers = item.State and item.State.ChamberData
    local bullets = chambers and chambers.bullets

    if type(bullets) == "table" then
        local spent, ready = false, 0
        for i, round in next, bullets do
            if round == AMMO_SPENT then
                bullets[i] = AMMO_READY
                spent, round = true, AMMO_READY
            end
            if round == AMMO_READY then ready = ready + 1 end
        end
        if spent and type(item.Ammo) == "number" and item.Ammo ~= ready then
            item.Ammo = ready
        end
        return
    end

    if type(item.Ammo) == "number" and item.Ammo < max then
        item.Ammo = max
    end
end

track(RunService.Heartbeat, function()
    if Config.InfiniteAmmo == true then holdAmmo() end
end)

--=========================== fps boost ===========================--
-- Client-side rendering cuts only. Nothing here is destroyed and nothing is
-- sent: every effect the game owns is switched off where it stands and its
-- previous value kept, so turning the boost off puts the scene back exactly as
-- it was. This map is heavy - measured on a live client:
--
--   889 ParticleEmitter   620 PointLight   96 Beam   90 Decal   79 Texture
--    73 SurfaceAppearance   38 SpotLight   ~18 post effects under Lighting
--
-- Walking the 78k Workspace instances costs ~100ms in one go, which is a
-- visible hitch, so the sweep is spread across frames and stops the moment the
-- toggle goes off.
local Lighting = game:GetService("Lighting")

local BOOST_CLASSES = {
    -- post effects: the cheapest win, and nothing the game's own code reads
    post      = { BloomEffect = "Enabled", BlurEffect = "Enabled",
                  SunRaysEffect = "Enabled", DepthOfFieldEffect = "Enabled",
                  -- Atmosphere has no Enabled: Density 0 is the switch it has
                  Atmosphere = "Density" },
    lights    = { PointLight = "Enabled", SpotLight = "Enabled", SurfaceLight = "Enabled" },
    particles = { ParticleEmitter = "Enabled", Smoke = "Enabled", Fire = "Enabled",
                  Sparkles = "Enabled" },
    fx        = { Beam = "Enabled", Trail = "Enabled" },
    textures  = { Decal = "Transparency", Texture = "Transparency" },
}

-- the "off" value where `false` is not it: transparency for the textures, and
-- Density 0 for the Atmosphere, the one post effect with no Enabled at all
local BOOST_OFF = { Decal = 1, Texture = 1, Atmosphere = 0 }

local BOOST_PROFILES = {
    Light      = { post = true },
    Balanced   = { post = true, particles = true, fx = true, ambience = true },
    Aggressive = { post = true, particles = true, fx = true, ambience = true,
                   lights = true, textures = true },
}

local Boost = {
    cats       = nil,   -- live profile while on, nil while off
    gen        = 0,     -- bumped on every on/off, so a stale sweep stops
    changed    = {},    -- { {inst, prop, was}, ... } for an exact restore
    seen       = {},    -- instance -> true, so nothing is recorded twice
    lightProps = nil,   -- saved Lighting numbers, for the ambience cut
    conns      = {},    -- late-arrival hooks, live only while the boost is
}

local originalFpsCap = (getfpscap and getfpscap()) or 60

--- Switch one instance off, remembering what it was. Instances that are
--- already off are skipped: the game parks its own dead effects in
--- Lighting.InactiveEffects, and "restoring" those would switch them ON.
local function boostTake(inst, prop)
    if Boost.seen[inst] then return end
    Boost.seen[inst] = true

    -- Deliberately no pcall around the property itself: this is only ever
    -- called for a class whose property is in the table, and 78k instances x 2
    -- pcalls was a lot of avoidable work on this client. An instance destroyed
    -- mid-walk instead kills the sweep task, which boostOn catches and reports
    -- rather than letting the client stutter.
    local off = BOOST_OFF[inst.ClassName] or false
    local was = inst[prop]
    if was == off then return end

    inst[prop] = off
    Boost.changed[#Boost.changed + 1] = { inst, prop, was }
end

local function boostConsider(inst)
    local flat = Boost.flat
    if not flat then return end
    local prop = flat[inst.ClassName]
    if prop then boostTake(inst, prop) end
end

--- One pass over Lighting, then the Workspace in yielded slices. `gen` is
--- checked on every yield so a profile change or an off cannot leave a second
--- sweep running behind the first.
local function boostSweep(gen)
    if Boost.gen ~= gen or not Boost.cats then return end

    if Boost.cats.post then
        for _, fx in ipairs(Lighting:GetChildren()) do
            local prop = BOOST_CLASSES.post[fx.ClassName]
            if prop then boostTake(fx, prop) end
        end
    end

    if Boost.cats.ambience then
        Boost.lightProps = {
            EnvironmentDiffuseScale  = Lighting.EnvironmentDiffuseScale,
            EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
            GlobalShadows            = Lighting.GlobalShadows,
            ShadowSoftness           = Lighting.ShadowSoftness,
        }
        pcall(function()
            Lighting.EnvironmentDiffuseScale, Lighting.EnvironmentSpecularScale = 0, 0
            Lighting.GlobalShadows, Lighting.ShadowSoftness = false, 0
        end)
    end

    -- Depth-first, a slice at a time: a single GetDescendants over 78k
    -- instances is a visible hitch, 1000 at a time is not.
    local stack, n = { workspace }, 0
    while #stack > 0 do
        if Boost.gen ~= gen or not Boost.cats then return end
        local inst = table.remove(stack)
        for _, child in ipairs(inst:GetChildren()) do
            stack[#stack + 1] = child
        end
        boostConsider(inst)
        n = n + 1
        if n % 1000 == 0 then task.wait() end
    end

    print(("[perf] fps boost on (%s) - %d effects off")
        :format(Config.FPSProfile, #Boost.changed))
end

local function boostOn()
    if Boost.cats then return end

    local name = Config.FPSProfile
    if type(name) ~= "string" or BOOST_PROFILES[name] == nil then name = "Balanced" end

    Boost.gen   = Boost.gen + 1
    Boost.cats  = BOOST_PROFILES[name]
    Boost.changed, Boost.seen = {}, {}

    -- class -> property for this profile, flattened once, so the late-arrival
    -- hook below is a single lookup per new instance rather than five
    local flat = {}
    for cat, classProp in pairs(BOOST_CLASSES) do
        if Boost.cats[cat] then
            for cls, prop in pairs(classProp) do flat[cls] = prop end
        end
    end
    Boost.flat = flat

    -- Anything that streams in after the sweep, e.g. a campfire that spawns
    -- into view, is caught on arrival rather than by a second full pass.
    Boost.conns[#Boost.conns + 1] = track(workspace.DescendantAdded, boostConsider)
    Boost.conns[#Boost.conns + 1] = track(Lighting.ChildAdded, boostConsider)

    local gen = Boost.gen
    task.spawn(function()
        local ok, err = pcall(boostSweep, gen)
        if not ok then
            print("[perf] fps boost sweep stopped: " .. tostring(err))
        end
    end)
end

local function boostOff()
    if not Boost.cats then return end
    Boost.cats = nil
    Boost.gen  = Boost.gen + 1
    Boost.flat = nil

    for _, c in ipairs(Boost.conns) do
        pcall(function() c:Disconnect() end)
    end
    Boost.conns = {}

    for _, rec in ipairs(Boost.changed) do
        local inst, prop, was = rec[1], rec[2], rec[3]
        pcall(function() inst[prop] = was end)
    end
    Boost.changed, Boost.seen = {}, {}

    if Boost.lightProps then
        for prop, was in pairs(Boost.lightProps) do
            pcall(function() Lighting[prop] = was end)
        end
        Boost.lightProps = nil
    end
end

local function syncBoost()
    if Config.FPSBoost == true then
        boostOn()
    else
        boostOff()
    end
end

--- FPS cap. "Uncapped" removes the ceiling; setfpscap floors anything above
--- 2000 at 2000, which is as good as unlimited. The cap the client started
--- with is put back by teardown, so unloading leaves no trace.
local function applyFpsCap(v)
    if type(v) == "table" then v = v[1] end
    local n = (v == "Uncapped") and 0 or tonumber(v)
    if n == nil then return end
    Config.FPSCap = n
    if setfpscap then pcall(setfpscap, n == 0 and 10000 or n) end
end

--- Rayfield's dropdown hands back either the option or a one-item table.
local function firstOption(v)
    if type(v) == "table" then v = v[1] end
    return tostring(v)
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
            "silent aim: %s    target: %s    in hand: %s%s    esp: %s",
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
    -- Rayfield's window goes first and by its own route: destroying its ScreenGui
    -- alone would leave its render loop and its key listeners running, so a reload
    -- or a rejoin would stack a second menu over the first.
    pcall(function()
        local prev = genv.WW_SA_Rayfield
        if type(prev) == "table" and not prev.unloaded then prev:Unload() end
    end)
    genv.WW_SA_Rayfield = nil

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

    pcall(boostOff)
    if setfpscap then pcall(setfpscap, originalFpsCap) end

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

--=========================== rayfield ui ===========================--
-- The interface is Rayfield Gen2 now, fetched once per run. Everything below
-- talks to it through the same handful of calls the old window exposed
-- (CreateTab / CreateToggle / CreateSlider / CreateDropdown / CreateKeybind /
-- CreateButton / CreateDivider), so the feature list, the flags and every
-- callback are unchanged - only the drawing is Rayfield's.
--
-- Three things about the swap are worth knowing up front:
--
--   * ONE WINDOW, NOT TWO. Gen2 builds a single window, so the recorder's Record
--     and Auto Mine tabs are folded into it beside Combat, Visuals, Perf,
--     Interface and Mine. "Auto Mine" on the Mine tab opens the window on the
--     Record tab, which is what the second window used to be for.
--
--   * THE SAVED FILE IS STILL OURS. The window is created without Gen2's
--     `configuration` table and every element without a flag, so Gen2 writes
--     nothing anywhere. The flags below still feed ww_combat.json, which stays
--     the one source of truth - and an older build's file is still read once.
--
--   * IT HAS TO BE FETCHED. The old window was built from Instances and could
--     not fail; this one needs one HTTP request at load. If that request fails
--     the script still runs - the aim, the ESP and the auto-mine all work from
--     the config in memory - but every control becomes a no-op, so there is no
--     menu to change anything with, and the console says why.
local RAYFIELD_URL = "https://sirius.menu/gen2"

local Rayfield
do
    local ok, lib = pcall(function()
        return loadstring(game:HttpGet(RAYFIELD_URL))()
    end)
    if ok and type(lib) == "table" then
        Rayfield = lib
    else
        warn("[ww] Rayfield Gen2 did not load (" .. tostring(lib) .. ") - running without a menu")
    end
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

--=========================== window ===========================--
local UI = {}
local flags = {}          -- flag -> { get = fn, set = fn(value, fire) }
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

local MENU_TITLE    = "WILD WEST"
local MENU_SUBTITLE = "silent aim + esp"

--- "None" is what Rayfield reports for a cleared bind, and it is Enum.KeyCode
--- value 0 - the same value Enum.KeyCode.Unknown has. Compared by value, so
--- neither name has to exist for this to be right.
local function keyOrNil(v)
    if typeof(v) ~= "EnumItem" then return nil end
    if v.EnumType ~= Enum.KeyCode then return nil end
    if v.Value == 0 then return nil end
    return v
end

local win     -- the one Rayfield window
local tried   -- the build is attempted once, not once per call

local function buildWindow()
    if Rayfield == nil then return nil end
    local ok, w = pcall(function()
        return Rayfield:CreateWindow({
            name = MENU_TITLE,
            subtitle = MENU_SUBTITLE,
            sidebarLayout = true,
            -- The bar the window folds into while it is hidden reads
            -- "<showName>" / "Tap to show". Tapping that bar is the only way
            -- back into the menu on a phone, so it stays on.
            showName = MENU_TITLE,
            showIconOnly = false,
        })
    end)
    if not ok or type(w) ~= "table" then
        warn("[ww] Rayfield window could not be created (" .. tostring(w) .. ") - running without a menu")
        return nil
    end

    -- Right shift, as it always was. Rayfield binds the toggle key itself and is
    -- the only listener allowed to move the window: a second one on the same key
    -- would toggle it twice per press and look like nothing happened at all.
    pcall(function() w.settings.toggleKeybind = Enum.KeyCode.RightShift end)

    -- Gen2 frees the mouse and re-asserts that on every cursor property change,
    -- which is exactly what made aiming with the menu open feel wrong in the old
    -- Rayfield build. The game's own cursor lock stands instead.
    pcall(function() w.settings.mouseOverride = false end)

    genv.WW_SA_Rayfield = w
    return w
end

local function ensureWindow()
    if win == nil and not tried then
        tried = true
        win = buildWindow()
    end
    return win
end

--- A control that exists even when Rayfield does not: the aim, the ESP and the
--- auto-mine must not care whether there is a menu to change them with.
local function deadHandle()
    return { set = function() end, Set = function() end, main = nil }
end

local function stubTab(name)
    local tab = { name = name }
    tab.CreateToggle   = deadHandle
    tab.CreateSlider   = deadHandle
    tab.CreateDropdown = deadHandle
    tab.CreateKeybind  = deadHandle
    tab.CreateButton   = deadHandle
    tab.CreateDivider  = deadHandle
    tab.CreateText     = deadHandle
    return tab
end

local function wrapTab(rayTab)
    local tab = { name = rayTab.name, ray = rayTab }

    -- Every element is created with forgetState, and that is not tidiness: Gen2
    -- otherwise derives a config flag from each control's NAME and keeps its own
    -- registry of them - two rows called "TeamCheck" collide and it warns about
    -- it, and its save file would start collecting values this script already
    -- owns. With it set there is one flag registry (this one) and one file
    -- (ww_combat.json), which is the whole point of the flags below.
    local function register(flag, get, set)
        if flag then flags[flag] = { get = get, set = set } end
    end

    function tab:CreateToggle(o)
        local el = rayTab:CreateToggle({
            name = o.name,
            description = o.description,
            forgetState = true,
            value = o.value == true,
            callback = function(v)
                if o.callback then pcall(o.callback, v) end
                markDirty()
            end,
        })
        --- fire == false moves the control without firing anything, which is what
        --- loading a saved value into it needs.
        local function set(value, fire)
            value = value == true
            if fire == false then el:Set(value, true) else el:Set(value) end
        end
        register(o.flag, function() return el.value == true end, set)
        return { set = set }
    end

    function tab:CreateSlider(o)
        local lo, hi = o.range[1], o.range[2]
        local el = rayTab:CreateSlider({
            name = o.name,
            description = o.description,
            forgetState = true,
            range = { lo, hi },
            increment = o.increment or 1,
            value = math.clamp(tonumber(o.value) or lo, lo, hi),
            suffix = o.suffix,
            callback = function(v)
                if o.callback then pcall(o.callback, v) end
                markDirty()
            end,
        })
        local function set(value, fire)
            local n = math.clamp(tonumber(value) or lo, lo, hi)
            if fire == false then el:Set(n, true) else el:Set(n) end
        end
        register(o.flag, function() return el.value end, set)
        return { set = set }
    end

    function tab:CreateDropdown(o)
        local first = type(o.value) == "table" and o.value[1] or o.value
        local el = rayTab:CreateDropdown({
            name = o.name,
            description = o.description,
            forgetState = true,
            options = o.options,
            value = first,
            callback = function(choice)
                local v = type(choice) == "table" and choice[1] or choice
                if o.callback then pcall(o.callback, v) end
                markDirty()
            end,
        })
        local function set(value, fire)
            if type(value) == "table" then value = value[1] end
            if value == nil then return end
            if fire == false then el:Set(value, true) else el:Set(value) end
        end
        register(o.flag, function()
            local v = el.value
            if type(v) == "table" then v = v[1] end
            return v
        end, set)
        return { set = set }
    end

    function tab:CreateKeybind(o)
        local el = rayTab:CreateKeybind({
            name = o.name,
            description = o.description,
            forgetState = true,
            value = keyOrNil(o.value) or Enum.KeyCode.Unknown,
            -- Fired when the bind itself changes: the picker, a clear, a load.
            onChanged = function(k)
                if o.onChanged then pcall(o.onChanged, keyOrNil(k)) end
                -- A new bind is a setting like any other: the debounced save
                -- below picks it up 0.6s later, which is late enough for the
                -- element to have settled on its new value.
                markDirty()
            end,
            -- Fired when the bound key is pressed. This build polls the bind
            -- every frame instead (see bindHeld), so nothing is wired to it.
            callback = function(k)
                if o.callback then pcall(o.callback, keyOrNil(k)) end
            end,
        })
        local function set(value, fire)
            local k = keyOrNil(value) or Enum.KeyCode.Unknown
            pcall(function() el:Set(k) end)
            -- Told again by hand: the element reports its own change, but the
            -- switch we are bound to is ours, and it has to be told even if the
            -- element decided to ignore the write.
            if o.onChanged then pcall(o.onChanged, keyOrNil(k)) end
            markDirty()
        end
        register(o.flag, function() return encodeEnum(keyOrNil(el.value)) end, set)
        return { set = set }
    end

    function tab:CreateButton(o)
        rayTab:CreateButton({
            name = o.name,
            description = o.description,
            callback = function()
                if o.callback then pcall(o.callback) end
            end,
        })
    end

    --- A heading: Gen2 closes the run of rows above it and starts the next under
    --- it, which is what the old divider did with its own cards.
    function tab:CreateDivider(o)
        rayTab:CreateDivider({ text = (o and o.text) or "" })
    end

    --- A read-only status line (the recorder's). `main` is the frame it draws in,
    --- which is how the heartbeat below tells whether it is still on screen.
    function tab:CreateText(o)
        return rayTab:CreateText({ name = o.name, text = o.text })
    end

    return tab
end

function UI.newWindow(opts)
    opts = opts or {}
    local window = { name = opts.title, opts = opts, flags = flags, tabs = {} }
    local tabs = window.tabs
    local count = 0
    ensureWindow()

    --- Show it AND unfold it: coming back from the bar at the top of the screen
    --- should never leave the player looking at a title bar they have to click
    --- again.
    function window:Show()
        local w = ensureWindow()
        if w == nil then return end
        if w.hidden then pcall(function() w:Show() end) end
        if w.minimised then pcall(function() w:ToggleMinimise() end) end
    end

    function window:SetVisible(visible)
        local w = ensureWindow()
        if w == nil then return end
        if visible then
            window:Show()
        else
            pcall(function() w:Hide() end)
        end
    end

    function window:Toggle()
        local w = ensureWindow()
        if w == nil then return end
        if opts.recorder then
            -- The recorder is two tabs of this window now, so opening it means
            -- showing the window and landing on the first of them.
            window:Show()
            window:SelectTab(1)
            return
        end
        if w.hidden then pcall(function() w:Show() end) else pcall(function() w:Hide() end) end
    end

    function window:Minimize()
        local w = ensureWindow()
        if w == nil then return end
        if not w.hidden then pcall(function() w:ToggleMinimise() end) end
    end

    --- Back to the middle. Gen2 keeps its own position and does not save it, and
    --- the window starts centred, so this is where a reload puts it too.
    function window:ResetPosition()
        local w = ensureWindow()
        if w ~= nil and w.main ~= nil then
            pcall(function() w.main.Position = UDim2.fromScale(0.5, 0.5) end)
        end
    end

    function window:SelectTab(index)
        local tab = tabs[index]
        local w = ensureWindow()
        if tab == nil or w == nil or tab.ray == nil then return end
        pcall(function() w:Navigate(tab.ray) end)
    end

    --- Nothing left to repaint (the dock this used to drive is gone). The call
    --- site that used it is gone too; this is here so an older build's edit
    --- cannot error on it.
    function window:Refresh() end

    --- Read ww_combat.json - falling back to the file the old Rayfield build
    --- wrote - and push every stored value back through the control that owns it.
    --- That moves the control and fires its own callback, so Config ends up
    --- correct, and a fresh install and an upgraded one agree.
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
        local w = ensureWindow()
        if w ~= nil then pcall(function() w:Unload() end) end
    end

    function window:CreateTab(o)
        o = o or {}
        count = count + 1
        local w = ensureWindow()
        local tab
        if w == nil then
            tab = stubTab(o.name)
        else
            tab = wrapTab(w:CreateTab({ name = o.name }))
        end
        tabs[count] = tab
        return tab
    end

    return window
end
--=========================== build the window ===========================--
-- One window, built by the ui section above. The recorder's tabs are part of it
-- too (see the auto-mine section), and its "Auto Mine" button opens the window
-- on the Record tab.
local Window = UI.newWindow({
    title = "WILD WEST",
    subtitle = "silent aim + esp",
})

genv.WW_SA_Window = Window

-- Right shift is bound by Rayfield itself (settings.toggleKeybind, set when the
-- window was built). A listener of our own on the same key would toggle the
-- window twice per press, which looks exactly like it doing nothing at all.

local Combat = Window:CreateTab({ name = "Combat" })

Combat:CreateToggle({
    name = "Silent Aim",
    description = "Shots go to whoever is inside the circle. The crosshair never moves.",
    value = Config.Enabled,
    flag = "sa_enabled",
    callback = function(v) Config.Enabled = v end,
})

-- The "Hold to Aim" row is not built on a phone: there is no key to press, and
-- a picker waiting for one would sit there for the rest of the session. With no
-- row there is no bind, `bindHeld` answers true, and the Silent Aim switch at the
-- top of this tab is the whole gate - which is exactly how a phone aims.
if not PHONE then
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
end

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
    name = "Infinite Ammo",
    description = "The gun never runs dry and you never reload. Chambered guns get the spent chamber back; plain ones keep their count.",
    value = Config.InfiniteAmmo,
    flag = "cx_infiniteammo",
    callback = function(v) Config.InfiniteAmmo = v end,
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

local Perf = Window:CreateTab({ name = "Perf" })

Perf:CreateToggle({
    name = "FPS Boost",
    description = "Switch off the scenery this machine pays the most for: post effects, the 889 particle emitters and - on Aggressive - the 620 dynamic lights. Client-side only, nothing is destroyed, and turning it off puts every one of them back exactly as it was.",
    value = Config.FPSBoost,
    flag = "pf_boost",
    callback = function(v)
        Config.FPSBoost = v and true or false
        syncBoost()
    end,
})

Perf:CreateDropdown({
    name = "Boost Profile",
    description = "Light = post effects only. Balanced = also particles, beams, trails and the ambient reflection scales. Aggressive = also the world's lamps and every decal/texture - the biggest win, and the most visible.",
    options = { "Light", "Balanced", "Aggressive" },
    value = Config.FPSProfile,
    flag = "pf_profile",
    callback = function(v)
        local name = firstOption(v)
        if BOOST_PROFILES[name] == nil then return end
        Config.FPSProfile = name
        -- re-sweep under the new profile rather than leaving the old one's
        -- effects off and the new one's on
        if Boost.cats then
            boostOff()
            syncBoost()
        end
    end,
})

Perf:CreateDivider({ text = "the client renders at 60 frames a second unless this is raised" })

Perf:CreateDropdown({
    name = "FPS Cap",
    description = "Uncapped removes Roblox's 60 fps ceiling. On a machine that can keep up, this is the largest single gain; on one that cannot, it only burns GPU time. Lower it back if the client feels hot.",
    options = { "60", "120", "144", "240", "Uncapped" },
    value = tostring(Config.FPSCap == 0 and "Uncapped" or Config.FPSCap),
    flag = "pf_cap",
    callback = function(v) applyFpsCap(firstOption(v)) end,
})

--=========================== interface ===========================--
-- There is far less to configure here than there was: the window, its chrome and
-- every gesture around it belong to Rayfield now. What is left is the window's
-- three own actions and a note about how it folds away - which is the part worth
-- knowing on a phone, where the folded bar is the only way back in.
local Interface = Window:CreateTab({ name = "Interface" })

Interface:CreateDivider({
    text = "RightShift shows and hides the menu. While it is hidden it folds into a small bar at the top of the screen - tap that bar to bring it back, which is the way in on a phone.",
})

Interface:CreateButton({
    name = "Minimise to the Bar",
    description = "Folds the window down to just its title bar. Everything stays one tap away and nothing floats over the game.",
    callback = function() Window:Minimize() end,
})

Interface:CreateButton({
    name = "Hide (tap the bar to reopen)",
    description = "The same thing the × does: the window goes and the small bar at the top of the screen stays.",
    callback = function() Window:SetVisible(false) end,
})

Interface:CreateButton({
    name = "Reset Position",
    description = "Put the window back in the middle of the screen. Rayfield does not save where it was dragged to, so this is what a reload gives you anyway.",
    callback = function() Window:ResetPosition() end,
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
        descent = 14,    -- studs/s ceiling on a drop, so the rig is lowered down rather than falling
        loop = true,
        swings = 3,      -- most swings spent on one recorded stop (caps a stop's length)
        getup = true,    -- get back on the feet after a fall puts the rig on the floor
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
    local Walker = { lv = nil, goal = nil, speed = 14, descentV = 0 }

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

    --- Off the ground: no floor under the rig, for longer than the single frame the
    --- floor probe flickers for while a rig crosses a ledge. Switching the walker off
    --- on those flickers would stop it dead mid-cadence, so the air has to persist.
    ---
    --- It is deliberately NOT "is the rig moving downwards". An enabled
    --- LinearVelocity cancels gravity - measured on this client, the rig cannot be
    --- lifted off the ground by any impulse while the walker's constraint is on - so
    --- a rig held over a drop sits at a vertical velocity of roughly zero. A velocity
    --- test would never recognise that drop, and the constraint would hold the rig up
    --- there and glide it across the gap until it reached the goal's XZ, then let go:
    --- the same float, just triggered by a level waypoint instead of a lower one.
    --- "Is there floor under me" stays true no matter what the constraint is doing, so
    --- it cannot be defeated that way. The jump/freefall/falling-velocity checks only
    --- short-circuit the first floorless frame, to save the debounce delay.
    local airFrames = 0
    local function airborne()
        local r = rig()
        if not r then airFrames = 0 return false end
        local hum = r:FindFirstChildOfClass("Humanoid")
        if not hum then airFrames = 0 return false end
        local ok, mat = pcall(function() return hum.FloorMaterial end)
        if not (ok and typeof(mat) == "EnumItem" and mat == Enum.Material.Air) then
            airFrames = 0
            return false
        end
        airFrames += 1
        if airFrames > 1 then return true end
        local okS, st = pcall(function() return hum:GetState() end)
        if okS and (st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping) then
            return true
        end
        local root = r:FindFirstChild("HumanoidRootPart") or r.PrimaryPart
        if not root then return false end
        local vy = 0
        pcall(function() vy = root.AssemblyLinearVelocity.Y end)
        return vy < -1
    end

    --- Called every frame. Vertical motion while there is floor under the rig is a
    --- small nudge towards the goal's height, so it walks over a slope rather than
    --- being pushed through it.
    ---
    --- THE DROP IS DRIVEN, and that is the whole point of it. A LinearVelocity is a
    --- velocity constraint, not a push: while it is on, the vector it is given IS the
    --- rig's velocity, gravity included. So a commanded Y does not shove the rig down
    --- through the floor - it sets the rate the rig comes down at, which is exactly a
    --- tween. Left to gravity the drop accelerates the whole way and arrives as an
    --- impact, and an impact is what puts the rig on the floor; a rig on the floor
    --- cannot walk, cannot swing, and the run can do nothing at all until it has been
    --- stood back up. Delivered like this the landing is a placement, not a collision.
    ---
    --- The rate is RAMPED rather than snapped, and bounded twice so nothing about it
    --- is abrupt: once by the ceiling (the Descent Speed slider), and once by the
    --- drop still outstanding, which makes the last studs slower than the first and
    --- the touchdown gentle rather than a second impact. The ramp is steep - close
    --- to gravity, so the rig still visibly FALLS for the first tenth of a second
    --- and only then stops accelerating. A soft ramp would read as a hover.
    --- Horizontal travel is untouched the whole way down - the rig arrives over the
    --- waypoint it was walking to rather than dropping wherever it stepped off.
    ---
    --- Only a descent is driven. Airborne with the goal level with the rig or above
    --- it there is nothing to bring it down to, so the constraint goes off and the
    --- jump or the fall is left alone.
    local DESCEND_ACCEL = 120   -- studs/s^2 the rate is allowed to build up by
    local DESCEND_FLOOR = 2     -- ...and never slower than this, so the last studs still end

    local function walkerStep(dt)
        local lv = Walker.lv
        if not (lv and lv.Parent) then return end
        local goal = Walker.goal
        if not goal or not Mine.playing then
            if lv.Enabled then lv.Enabled = false end
            Walker.descentV = 0
            return
        end
        local p = here()
        if not p then return end
        local d = goal - p
        local flat = Vector3.new(d.X, 0, d.Z)

        if airborne() then
            local drop = -d.Y
            if drop <= 0 then
                -- nothing to bring the rig down to: let the fall be a fall
                if lv.Enabled then lv.Enabled = false end
                Walker.descentV = 0
                return
            end
            local ceiling = math.max(DESCEND_FLOOR, Mine.descent or 14)
            local cap = math.min(ceiling, math.max(drop, DESCEND_FLOOR))
            Walker.descentV = math.min(Walker.descentV + DESCEND_ACCEL * (dt or 0.016), cap)
            local v = Vector3.new(0, -Walker.descentV, 0)
            if flat.Magnitude > 0.05 then v += flat.Unit * Walker.speed end
            lv.VectorVelocity = v
            lv.Enabled = true
            return
        end

        Walker.descentV = 0
        if flat.Magnitude < 0.05 then
            lv.Enabled = false
            return
        end
        lv.VectorVelocity = (flat.Unit * Walker.speed) + Vector3.new(0, math.clamp(d.Y, -6, 6), 0)
        lv.Enabled = true
    end

    --=========================== ragdoll ===========================--
    -- The other half of a descent: a long enough drop puts the rig on the floor,
    -- and then nothing in the run works. The walker is pushing a body that cannot
    -- take a step, every swing misses (the rig is not standing where the swing was
    -- recorded from), and the run spends the rest of itself skipping waypoints it is
    -- lying on top of. The game's own answer is the get-up routine - the same one
    -- the ragdoll is meant to be left through - so that is what is called, and the
    -- server is asked for it rather than the pose being faked, because a rig put
    -- upright without the server agreeing is put back down.
    local function ragdolled()
        local pc = Global.PlayerCharacter
        if not pc then return false end
        local v = false
        -- the client's own ragdoll flag is the one that matters: it is what the
        -- game's CanGetUp reads and what decides whether the rig can be walked
        pcall(function() v = pc:IsRagdolledSelf() == true end)
        return v == true
    end

    local function getUpOnce()
        local pc = Global.PlayerCharacter
        if not pc then return false end
        return pcall(function() pc:GetUp() end)
    end

    --- The key a player would press, and the reason this build can get a rig up at
    --- all: on this game E IS the way off the floor, while the game's own Interact
    --- action driven through InputHandler leaves the ragdoll exactly as it found
    --- it. The old version sent the real key only when the Interact call had
    --- FAILED - and that call reports success without moving anything at all, so E
    --- was never actually pressed and the run sat on the floor retrying for ever.
    --- The real key now goes first, on every attempt; the Interact nudge follows it
    --- afterwards, which costs nothing and covers the other case.
    local function pressE()
        local sent = false
        if type(keypress) == "function" then
            pcall(keypress, 69)
            task.wait(0.12)
            pcall(function()
                if type(keyrelease) == "function" then keyrelease(69) end
            end)
            sent = true
        end
        pcall(function()
            local handler = Global.InputHandler
            local action = handler and handler:GetAction("Interact")
            if action and action.HandleInput then
                action:HandleInput(action.Name or "Interact", Enum.UserInputState.Begin, nil, true)
                task.wait(0.08)
                action:HandleInput(action.Name or "Interact", Enum.UserInputState.End, nil, true)
            end
        end)
        return sent
    end

    local gettingUp = false

    --- Up off the floor, waiting for it rather than assuming it. The walker goes off
    --- first: a constraint held on a ragdolled rig makes the recovery a tug of war.
    --- Each ask is watched for the flag to clear, and a refusal is retried - the
    --- server can be busy, or the ragdoll can be one it did not hand out. Only after
    --- that fails does the client-side stand-up get used, because a rig left lying
    --- there ends the run.
    local function recoverRagdoll(limit)
        local pc = Global.PlayerCharacter
        if not pc or gettingUp or not Mine.getup or not Mine.playing then return false end
        if not ragdolled() then return false end
        gettingUp = true
        walkerStop()
        setStatus("ragdolled - getting up")
        local deadline = os.clock() + (limit or 20)
        local attempts = 0
        while Mine.playing and ragdolled() and os.clock() < deadline do
            attempts += 1
            -- the real key first, on every attempt: E is what gets a rig off the
            -- floor here, and waiting for the routine below to fail before trying
            -- it just burned the run's time on the floor
            pressE()
            getUpOnce()
            local until_ = os.clock() + 2.4
            while os.clock() < until_ and Mine.playing and ragdolled() do task.wait(0.1) end
            if not ragdolled() then break end
            if attempts >= 2 then
                pcall(function() pc:ForceServerGetUp() end)
                local settle = os.clock() + 1.5
                while os.clock() < settle and Mine.playing and ragdolled() do task.wait(0.1) end
            end
            task.wait(0.2)
        end
        gettingUp = false
        local up = not ragdolled()
        setStatus(up and "back on the feet" or "still ragdolled")
        if not up then
            -- leave behind which of the three states the rig was really in, so the
            -- next session does not have to guess again
            local rep = "?"
            pcall(function()
                local rc = Global.RepCharHandler and Global.RepCharHandler:GetRepChar(lp)
                rep = tostring(rc and rc.State and rc.State.Ragdolled)
            end)
            warn(("[auto_mine] get-up failed after %d tries: pc=%s RepChar.Ragdolled=%s")
                :format(attempts, tostring(pc ~= nil), rep))
        end
        return up
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
        local nextCheck = 0
        while Mine.playing and os.clock() - t0 < limit do
            if walkerArrived(radius) then break end
            task.wait()
            local p = here()
            if os.clock() >= nextCheck then
                nextCheck = os.clock() + 0.4
                if ragdolled() then
                    -- a ragdoll stops the rig where it is, so the walk gets its time
                    -- back: being on the floor is not the leg taking too long
                    local r0 = os.clock()
                    recoverRagdoll()
                    t0 = t0 + (os.clock() - r0)
                    walkerGo(goal, speed)
                    lastPos, lastMove = here(), os.clock()
                elseif airborne() then
                    -- mid-drop the rig covers ground with gravity, and the walker is
                    -- deliberately not driving it; that is not a stall either
                    lastPos, lastMove = p, os.clock()
                end
            end
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
        local nextCheck = 0
        while Mine.playing and os.clock() - t0 < 8 do
            if walkerArrived(2.5) then return true end
            task.wait()
            local cur = here()
            if os.clock() >= nextCheck then
                nextCheck = os.clock() + 0.4
                if ragdolled() then
                    -- a fall that ends on the floor is recovered here, and the leg's
                    -- clock is pushed out by however long standing up took, so a
                    -- drop mid-waypoint does not read as a waypoint that was missed
                    local r0 = os.clock()
                    recoverRagdoll()
                    t0 = t0 + (os.clock() - r0)
                    walkerGo(goal, speed())
                    lastPos, lastMove = here(), os.clock()
                elseif airborne() then
                    lastPos, lastMove = cur, os.clock()
                end
            end
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

    --- The one colour of the old window's palette the recorder ever painted with,
    --- kept here rather than fetched from a module that is gone.
    local ACCENT = Color3.fromRGB(255, 138, 32)

    local trail = newDraw("Line")
    trail.Thickness, trail.Color, trail.Transparency, trail.Visible = 3, ACCENT, 0.2, false

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
                l.From, l.To, l.Thickness, l.Color, l.Transparency = a, b, 2, ACCENT, 0.45
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
        t.Color, t.Transparency = ColorSequence.new(ACCENT), NumberSequence.new(0.25)
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
        mark.Material, mark.Color, mark.Transparency = Enum.Material.Neon, ACCENT, 0.35
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
            -- a rig on the floor cannot swing from where the stop was recorded
            if ragdolled() then
                recoverRagdoll()
                if not Mine.playing then break end
                item = item or bestPickaxe()
            end
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
            -- a step that starts with the rig on the floor is a step that cannot
            -- work, so the floor comes first
            if ragdolled() then
                recoverRagdoll()
                if not Mine.playing then break end
            end
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
    -- The recorder is two tabs of the one Rayfield window now (see the ui
    -- section), so there is no second window to build, place or hide: the
    -- "Auto Mine" button on the Mine tab shows the window on the Record tab.
    local AutoWindow = UI.newWindow({
        title = "AUTO MINE",
        recorder = true,
    })

    --- A Rayfield text row. `:Set` replaces its body, and `.main` is the frame it
    --- draws in - which is what the heartbeat below tests to tell whether the row
    --- is still on screen.
    local function statusLine(tab)
        return tab:CreateText({ name = "Status", text = "idle" })
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
        name = "Descent Speed",
        description = "The rate the rig is lowered at when the route goes down instead of walking. It is brought down onto the waypoint at this speed rather than dropped - a fall arrives as an impact, and an impact puts the rig on the floor. Lower is softer; too low and a long drop takes a while.",
        range = { 4, 30 },
        increment = 1,
        value = Mine.descent,
        suffix = " st/s",
        callback = function(v) Mine.descent = v end,
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
        name = "Get Up When Ragdolled",
        description = "A long drop puts the rig on the floor. The run presses the game's own get-up key (E) and waits, instead of skipping the waypoint it is lying on.",
        value = Mine.getup,
        callback = function(v) Mine.getup = v and true or false end,
    })
    RunTab:CreateButton({
        name = "Get Up Now",
        description = "Gets the rig off the floor wherever it is standing - the real E key first, then the game's own get-up. Also works outside a run.",
        callback = function()
            task.spawn(function()
                local pc = Global.PlayerCharacter
                if not (pc and ragdolled()) then
                    setStatus("not ragdolled")
                    return
                end
                setStatus("getting up")
                local deadline = os.clock() + 8
                while os.clock() < deadline and ragdolled() do
                    pressE()
                    getUpOnce()
                    local slice = os.clock() + 2
                    while os.clock() < slice and ragdolled() do task.wait(0.1) end
                    if not ragdolled() then break end
                    pcall(function() pc:ForceServerGetUp() end)
                    task.wait(0.2)
                end
                setStatus(ragdolled() and "still ragdolled" or "back on the feet")
            end)
        end,
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

    track(RunService.Heartbeat, function(dt)
        walkerStep(dt)
        recorderTick()
        if Mine.status ~= Mine.shown then
            Mine.shown = Mine.status
            if statusA and statusA.main ~= nil then pcall(statusA.Set, statusA, Mine.status) end
            if statusB and statusB.main ~= nil then pcall(statusB.Set, statusB, Mine.status) end
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

-- Load() replays the stored values through the controls, which fires their
-- callbacks - but only for flags the file actually carried (no file, or a file
-- from build 8, fires nothing). Run both once more from Config so a fresh
-- install and an upgraded one end up in the same state.
syncBoost()
applyFpsCap(Config.FPSCap)

-- Hold the script open so the hooks and loop stay installed.
while STATE.alive() do
    task.wait(0.25)
end

teardown()
