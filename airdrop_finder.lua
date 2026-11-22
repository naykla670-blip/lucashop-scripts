-- Lua 5.1 / Luau | File: airdrop_finder.lua | Runtime: Roblox Client Executor | Target: Urban Reload (PlaceId: 84448037861644)
-- ============================================================================
-- 📦 UKC x LUCASHOP | Pure Airdrop Server Finder & Live Cloud Radar (v2.0)
-- ระบบหาเซิร์ฟแอร์ดรอปโดยเฉพาะ:
--   1. Cloud Live Verified Airdrop Radar (ดึงและแชร์ JobId เซิร์ฟที่มีแอร์ดรอปจริงแบบเรียลไทม์)
--   2. Deep ReplicatedStorage Attribute Telemetry (อ่านค่า AirdropBlockAt / AirdropLandAt ทันทีตั้งแต่เริ่มเข้าเซิร์ฟ)
--   3. Server Cooldown Cycle Analyzer (คำนวณเวลาตกครั้งก่อน + รอบคูลดาวน์ 40 นาทีของเซิร์ฟ ไม่ใช่แค่เดาจากจำนวนคน)
--   4. 3D ESP Beacon + เดินทางไปจุดแอร์ดรอป + Auto Claim เก็บกล่องอัตโนมัติ
-- ============================================================================

-- Anti-Detection Protection for Urban Reload (Selective ClientLog Filter - preserves all weapon/game remotes)
pcall(function()
    local oldFireServer
    if typeof(hookfunction) == "function" then
        local dummy = Instance.new("RemoteEvent")
        oldFireServer = hookfunction(dummy.FireServer, newcclosure(function(self, ...)
            if self and (self.Name == "ClientLog" or tostring(self) == "ClientLog") then
                return
            end
            return oldFireServer(self, ...)
        end))
    end
    local rs = game:GetService("ReplicatedStorage")
    local remotes = rs:WaitForChild("Remotes", 5)
    local clientLog = remotes and remotes:FindFirstChild("ClientLog")
    if clientLog and not oldFireServer then
        pcall(function() clientLog:Destroy() end)
    end
end)

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local VehicleSystem = ReplicatedStorage:FindFirstChild("VehicleSystem")
local VehicleAction = VehicleSystem and VehicleSystem:FindFirstChild("VehicleAction")

-- Cloud Live Radar Endpoint (Google Apps Script Cache Registry)
local CLOUD_RADAR_URL = "https://script.google.com/macros/s/AKfycbwPt-PUPEMgbJvojjtaciAnhB0AXYE9-NYFc0Y-AG5ozVAmDOBgdqjeSmapDx0MBh9LDg/exec"

-- Urban Reload AirdropConfig Constants (derived directly from ReplicatedStorage.AirdropConfig)
local AIRDROP_MIN_PLAYERS  = 14
local AIRDROP_FALL_TIME    = 420   -- 7 minutes parachute descent
local AIRDROP_COOLDOWN_MIN = 2400  -- 40 minutes minimum server cooldown between drops
local AIRDROP_COOLDOWN_MAX = 4800  -- 80 minutes maximum server cooldown between drops

pcall(function()
    local cfgMod = ReplicatedStorage:FindFirstChild("AirdropConfig")
    if cfgMod then
        local cfg = require(cfgMod)
        if type(cfg) == "table" then
            AIRDROP_MIN_PLAYERS  = tonumber(cfg.MIN_PLAYERS) or AIRDROP_MIN_PLAYERS
            AIRDROP_FALL_TIME    = tonumber(cfg.FALL_TIME) or AIRDROP_FALL_TIME
            AIRDROP_COOLDOWN_MIN = tonumber(cfg.COOLDOWN_MIN) or AIRDROP_COOLDOWN_MIN
            AIRDROP_COOLDOWN_MAX = tonumber(cfg.COOLDOWN_MAX) or AIRDROP_COOLDOWN_MAX
        end
    end
end)

local STATE_FILE         = "UKC_Airdrop_HopState_v2.json"
local VERIFIED_FILE      = "UKC_Verified_Airdrops_v2.json"
local SCRIPT_AUTORUN_FILE = "UKC_Airdrop_Finder_Autorun.lua"

local state = {
    autoHop = false,
    stopOnHotWindow = false, -- หยุดรอถ้าเจอเซิร์ฟที่ครบคูลดาวน์ 40 นาทีแล้วและคน >= 14
    espEnabled = true,
    autoClaim = true,
    autoTravelOnFind = false,
    fastScanDelay = 1.2,     -- ดีเลย์สแกนไว (วินาที) ก่อนดีดไปเซิร์ฟถัดไปถ้าไม่มีแอร์ดรอป
    minPlayers = AIRDROP_MIN_PLAYERS,
    visitedServers = {},
}

local verifiedServers = {} -- [jobId] = { jobId, phase, remaining, players, pos, updatedAt }

-- ==================== PERSISTENCE & SELF-QUEUE ====================
local function loadState()
    if type(isfile) == "function" and type(readfile) == "function" then
        if pcall(isfile, STATE_FILE) and isfile(STATE_FILE) then
            local ok, raw = pcall(readfile, STATE_FILE)
            if ok and raw then
                local decOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
                if decOk and type(data) == "table" then
                    if type(data.autoHop) == "boolean" then state.autoHop = data.autoHop end
                    if type(data.stopOnHotWindow) == "boolean" then state.stopOnHotWindow = data.stopOnHotWindow end
                    if type(data.espEnabled) == "boolean" then state.espEnabled = data.espEnabled end
                    if type(data.autoClaim) == "boolean" then state.autoClaim = data.autoClaim end
                    if type(data.autoTravelOnFind) == "boolean" then state.autoTravelOnFind = data.autoTravelOnFind end
                    if type(data.visitedServers) == "table" then state.visitedServers = data.visitedServers end
                end
            end
        end

        if pcall(isfile, VERIFIED_FILE) and isfile(VERIFIED_FILE) then
            local ok, raw = pcall(readfile, VERIFIED_FILE)
            if ok and raw then
                local decOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
                if decOk and type(data) == "table" then
                    verifiedServers = data
                end
            end
        end
    end
end

local function saveState()
    if type(writefile) == "function" then
        pcall(function()
            local now = os.time()
            local cleanedVisited = {}
            for jid, ts in pairs(state.visitedServers) do
                if type(ts) == "number" and (now - ts) < 900 then
                    cleanedVisited[jid] = ts
                end
            end
            state.visitedServers = cleanedVisited
            writefile(STATE_FILE, HttpService:JSONEncode(state))
        end)
    end
end

local function saveVerifiedServers()
    if type(writefile) == "function" then
        pcall(function()
            local now = os.time()
            local cleaned = {}
            for jid, info in pairs(verifiedServers) do
                if type(info) == "table" and (now - (tonumber(info.updatedAt) or 0)) < 240 then
                    cleaned[jid] = info
                end
            end
            verifiedServers = cleaned
            writefile(VERIFIED_FILE, HttpService:JSONEncode(verifiedServers))
        end)
    end
end

loadState()
saveState()
saveVerifiedServers()

-- Auto-cache self into executor workspace if local file server or existing file is available
local LOADER_SHORT_URL = "https://lucashop-loader.naykla670.workers.dev/lucashop_airdrop"

task.spawn(function()
    if type(writefile) == "function" then
        pcall(function()
            local ok, src = pcall(function() return game:HttpGet(LOADER_SHORT_URL) end)
            if ok and src and #src > 500 then
                writefile(SCRIPT_AUTORUN_FILE, src)
            elseif type(isfile) == "function" and type(readfile) == "function" then
                if isfile("airdrop_finder.lua") then
                    local s = readfile("airdrop_finder.lua")
                    if s and #s > 500 then writefile(SCRIPT_AUTORUN_FILE, s) end
                elseif isfile("Airdrop_Finder_Hop.lua") then
                    local s = readfile("Airdrop_Finder_Hop.lua")
                    if s and #s > 500 then writefile(SCRIPT_AUTORUN_FILE, s) end
                end
            end
        end)
    end
end)

-- ==================== DEEP AIRDROP TELEMETRY ENGINE ====================
-- ตรวจสอบแอร์ดรอปจาก Attribute จริงของเซิร์ฟเวอร์ใน ReplicatedStorage และโมเดลใน Workspace
local function getAirdropStatus()
    local now = Workspace:GetServerTimeNow()
    local crateModel = Workspace:FindFirstChild("Airdrop")
    local fallingCrate = Workspace:FindFirstChild("CrateFalling")

    local blockAt      = ReplicatedStorage:GetAttribute("AirdropBlockAt")
    local landAt       = tonumber(ReplicatedStorage:GetAttribute("AirdropLandAt")) or 0
    local fallT1       = tonumber(ReplicatedStorage:GetAttribute("AirdropFallT1")) or 0
    local planeT0      = tonumber(ReplicatedStorage:GetAttribute("AirdropPlaneT0")) or 0
    local planeDrop    = tonumber(ReplicatedStorage:GetAttribute("AirdropPlaneDrop")) or 0
    local landedAttr   = ReplicatedStorage:GetAttribute("AirdropLanded") == true
    local fallLandCF   = ReplicatedStorage:GetAttribute("AirdropFallLand")
    local planeDropPos = ReplicatedStorage:GetAttribute("AirdropPlaneDropPos")

    local effectiveLandAt = math.max(landAt, fallT1)

    -- คำนวณพิกัดจุดตกจริง
    local dropPos = nil
    if crateModel and crateModel.Parent then
        dropPos = crateModel:GetPivot().Position
    elseif fallingCrate and fallingCrate.Parent then
        dropPos = fallingCrate:GetPivot().Position
    elseif typeof(blockAt) == "Vector3" then
        dropPos = blockAt
    elseif typeof(fallLandCF) == "CFrame" then
        dropPos = fallLandCF.Position
    elseif typeof(planeDropPos) == "Vector3" then
        dropPos = Vector3.new(planeDropPos.X, 17.5, planeDropPos.Z)
    end

    local dist = 0
    local char = player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local refPos = (hrp and hrp.Position) or (camera and camera.CFrame.Position)
    if refPos and dropPos then
        dist = (refPos - dropPos).Magnitude
    end

    local playerCount = #Players:GetPlayers()

    -- กรณีที่ 1: มีโมเดลกล่อง Airdrop อยู่ใน Workspace (ตกถึงพื้นแล้ว หรือกำลังร่วง)
    if crateModel and crateModel.Parent then
        local isLanded = (crateModel:GetAttribute("Landed") == true) or landedAttr or (effectiveLandAt > 0 and now >= effectiveLandAt)
        local prompt = crateModel:FindFirstChild("Claim", true) or crateModel:FindFirstChildOfClass("ProximityPrompt", true)
        local rem = math.max(0, effectiveLandAt - now)
        return {
            active = true,
            verified = true,
            phase = isLanded and "LANDED" or "FALLING",
            pos = dropPos,
            dist = dist,
            remaining = rem,
            lastLandAt = effectiveLandAt,
            crate = crateModel,
            prompt = prompt,
            statusText = isLanded
                and string.format("🟢 พบแอร์ดรอปจริง! ตกถึงพื้นแล้ว (ห่าง %.0f ม.) - พร้อมเก็บ!", dist)
                or string.format("🟡 พบแอร์ดรอปจริง! กำลังร่วงลงพื้น (อีก %.0f วิ | ห่าง %.0f ม.)", rem, dist),
            cycleText = "สถานะเซิร์ฟ: ยืนยันมีกล่องแอร์ดรอปในแมพ 100%"
        }
    end

    -- กรณีที่ 2: เครื่องบินกำลังบินปล่อยร่ม หรือร่มกำลังลอยลงมา (ตรวจจาก AirdropBlockAt / CrateFalling / AirdropLandAt > now)
    local isPlaneOrParachuteActive = (typeof(blockAt) == "Vector3")
        or (fallingCrate ~= nil)
        or (effectiveLandAt > now and not landedAttr)
        or (planeT0 > 0 and (now - planeT0) < (AIRDROP_FALL_TIME + 25) and not landedAttr)

    if isPlaneOrParachuteActive then
        local rem = effectiveLandAt > now and (effectiveLandAt - now) or math.max(0, (planeT0 + AIRDROP_FALL_TIME) - now)
        local mins = math.floor(rem / 60)
        local secs = math.floor(rem % 60)
        return {
            active = true,
            verified = true,
            phase = "FALLING",
            pos = dropPos,
            dist = dist,
            remaining = rem,
            lastLandAt = effectiveLandAt,
            crate = fallingCrate,
            prompt = nil,
            statusText = string.format("🟡 พบแอร์ดรอปจริง! ร่มกำลังร่วง (ถึงพื้นใน %d:%02d นาที | ห่าง %.0f ม.)", mins, secs, dist),
            cycleText = "สถานะเซิร์ฟ: ยืนยันร่มแอร์ดรอปกำลังลงจอด 100%"
        }
    end

    -- กรณีที่ 3: เซิร์ฟนี้ไม่มีแอร์ดรอปอยู่ตอนนี้ -> วิเคราะห์เวลาคูลดาวน์จาก AirdropLandAt ของเซิร์ฟเวอร์
    if effectiveLandAt > 0 and now > effectiveLandAt then
        local elapsedSec = now - effectiveLandAt
        local agoMin = math.floor(elapsedSec / 60)
        local agoSec = math.floor(elapsedSec % 60)
        local minWaitLeftSec = math.max(0, AIRDROP_COOLDOWN_MIN - elapsedSec)
        local waitLeftMin = math.ceil(minWaitLeftSec / 60)

        -- ถ้าตกไปนานเกิน 38 นาทีแล้ว และในเซิร์ฟมีคน >= 14 คน แปลว่าเซิร์ฟนี้อยู่ในช่วง Hot Window พร้อมเกิดลูกใหม่ทุกวินาที!
        local isHotWindow = (elapsedSec >= (AIRDROP_COOLDOWN_MIN - 120)) and (playerCount >= AIRDROP_MIN_PLAYERS)

        if isHotWindow then
            return {
                active = false,
                verified = false,
                isHotWindow = true,
                phase = "HOT_WINDOW",
                pos = nil,
                dist = 0,
                remaining = 0,
                lastLandAt = effectiveLandAt,
                elapsedSinceLast = elapsedSec,
                statusText = string.format("🟠 เซิร์ฟนี้ครบกำหนดปล่อยแอร์ดรอปลูกใหม่แล้ว! (ลูกก่อนตกเมื่อ %d นาทีที่แล้ว)", agoMin),
                cycleText = string.format("🔥 Hot Window: ครบรอบ 40 นาที + คนครบ (%d/%d) พร้อมเกิดลูกใหม่เร็วๆ นี้", playerCount, AIRDROP_MIN_PLAYERS)
            }
        else
            return {
                active = false,
                verified = false,
                isHotWindow = false,
                phase = "COOLDOWN",
                pos = nil,
                dist = 0,
                remaining = 0,
                lastLandAt = effectiveLandAt,
                elapsedSinceLast = elapsedSec,
                statusText = string.format("🔴 ไม่มีแอร์ดรอป (ลูกก่อนถูกเก็บไปเมื่อ %d นาที %d วิที่แล้ว)", agoMin, agoSec),
                cycleText = string.format("⏳ ติดคูลดาวน์เซิร์ฟ: ต้องรออีกอย่างน้อย ~%d นาที ถึงจะมีโอกาสเกิดลูกใหม่", waitLeftMin)
            }
        end
    end

    -- กรณีที่ 4: เซิร์ฟเพิ่งเปิดใหม่ยังไม่เคยมีแอร์ดรอปตกเลย (AirdropLandAt == 0)
    return {
        active = false,
        verified = false,
        isHotWindow = false,
        phase = "NONE",
        pos = nil,
        dist = 0,
        remaining = 0,
        lastLandAt = 0,
        statusText = "🔴 เซิร์ฟนี้ไม่มีแอร์ดรอป (ยังไม่เคยตกในเซิร์ฟนี้)",
        cycleText = playerCount >= AIRDROP_MIN_PLAYERS
            and string.format("ผู้เล่น %d คน (ครบเกณฑ์ขั้นต่ำ %d คน แต่ยังไม่มีสัญญาณเครื่องบิน)", playerCount, AIRDROP_MIN_PLAYERS)
            or string.format("ผู้เล่นไม่พอ (%d/%d คน - แอร์ดรอปไม่มีทางเกิดในเซิร์ฟนี้)", playerCount, AIRDROP_MIN_PLAYERS)
    }
end

-- ==================== CLOUD LIVE RADAR SYNC ====================
local lastCloudReport = 0
local lastCloudFetch = 0
local lastReportedPhase = "NONE"

local function reportCurrentServerToCloud(info)
    if not info then return end
    local jobId = game.JobId
    if not jobId or jobId == "" then return end

    if info.active then
        local posStr = info.pos and string.format("%.0f,%.0f,%.0f", info.pos.X, info.pos.Y, info.pos.Z) or ""
        verifiedServers[jobId] = {
            jobId = jobId,
            phase = info.phase,
            remaining = math.floor(info.remaining or 0),
            players = #Players:GetPlayers(),
            pos = posStr,
            updatedAt = os.time()
        }
        saveVerifiedServers()

        if os.clock() - lastCloudReport >= 10 or lastReportedPhase ~= info.phase then
            lastCloudReport = os.clock()
            lastReportedPhase = info.phase
            task.spawn(function()
                pcall(function()
                    local url = string.format("%s?action=airdrop_report&job=%s&phase=%s&rem=%d&players=%d&pos=%s",
                        CLOUD_RADAR_URL,
                        HttpService:UrlEncode(jobId),
                        HttpService:UrlEncode(info.phase),
                        math.floor(info.remaining or 0),
                        #Players:GetPlayers(),
                        HttpService:UrlEncode(posStr)
                    )
                    game:HttpGet(url)
                end)
            end)
        end
    else
        if verifiedServers[jobId] then
            verifiedServers[jobId] = nil
            saveVerifiedServers()
        end
        if lastReportedPhase ~= "NONE" then
            lastReportedPhase = "NONE"
            task.spawn(function()
                pcall(function()
                    local url = string.format("%s?action=airdrop_clear&job=%s",
                        CLOUD_RADAR_URL,
                        HttpService:UrlEncode(jobId)
                    )
                    game:HttpGet(url)
                end)
            end)
        end
    end
end

local function fetchVerifiedServersFromCloud(onComplete)
    task.spawn(function()
        pcall(function()
            local resp = game:HttpGet(CLOUD_RADAR_URL .. "?action=airdrop_list")
            if resp and #resp > 2 then
                local ok, data = pcall(function() return HttpService:JSONDecode(resp) end)
                if ok and type(data) == "table" and type(data.servers) == "table" then
                    local now = os.time()
                    for _, srv in ipairs(data.servers) do
                        if type(srv) == "table" and srv.jobId and #tostring(srv.jobId) >= 10 then
                            verifiedServers[srv.jobId] = {
                                jobId = srv.jobId,
                                phase = srv.phase or "FALLING",
                                remaining = tonumber(srv.remaining) or 0,
                                players = tonumber(srv.players) or 0,
                                pos = srv.pos or "",
                                updatedAt = now - (tonumber(srv.age) or 0)
                            }
                        end
                    end
                    saveVerifiedServers()
                end
            end
        end)
        if onComplete then pcall(onComplete) end
    end)
end

-- ==================== AUTO CLAIM AIRDROP CRATE ====================
local lastClaimTry = 0
local isClaiming = false

local function tryAutoClaim(info)
    if not state.autoClaim or not info.active or info.phase ~= "LANDED" then return end
    if not info.pos or info.dist > 18 then return end
    if os.clock() - lastClaimTry < 1.2 or isClaiming then return end

    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return end

    if hum.SeatPart then
        if VehicleAction then
            pcall(function() VehicleAction:FireServer("exit") end)
            pcall(function() VehicleAction:FireServer("Exit") end)
        end
        hum.Jump = true
        task.wait(0.25)
    end

    local prompt = info.prompt or (info.crate and info.crate:FindFirstChildOfClass("ProximityPrompt", true))
    if prompt and prompt.Enabled then
        lastClaimTry = os.clock()
        if type(fireproximityprompt) == "function" then
            pcall(function()
                fireproximityprompt(prompt)
            end)
        else
            isClaiming = true
            task.spawn(function()
                pcall(function()
                    prompt:InputHoldBegin()
                    task.wait((prompt.HoldDuration or 5) + 0.15)
                    prompt:InputHoldEnd()
                end)
                isClaiming = false
            end)
        end
    end
end

-- ==================== TRAVEL TO AIRDROP (CAR / WALK) ====================
local isTravelingToDrop = false
local hopStatusLabel = nil

local function travelToAirdropPos(targetPos)
    if isTravelingToDrop or not targetPos then return end
    isTravelingToDrop = true

    task.spawn(function()
        local char = player.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then
            isTravelingToDrop = false
            return
        end

        if hopStatusLabel then
            hopStatusLabel.Text = "🚗 กำลังเดินทางไปจุดแอร์ดรอป..."
            hopStatusLabel.TextColor3 = Color3.fromRGB(80, 215, 255)
        end

        local seat = hum.SeatPart
        local carModel = seat and seat:FindFirstAncestorOfClass("Model")
        local rootPart = (carModel and (carModel:FindFirstChild("Chassis") or carModel.PrimaryPart)) or seat

        if carModel and rootPart then
            local origCollide = {}
            for _, d in ipairs(carModel:GetDescendants()) do
                if d:IsA("BasePart") then
                    origCollide[d] = d.CanCollide
                    d.CanCollide = false
                end
            end

            while isTravelingToDrop and hum.Health > 0 and hum.SeatPart == seat do
                local dt = RunService.Heartbeat:Wait()
                local curPos = rootPart.Position
                local goal = Vector3.new(targetPos.X, math.max(targetPos.Y + 2, curPos.Y), targetPos.Z)
                local diff = goal - curPos
                local flatDist = Vector2.new(diff.X, diff.Z).Magnitude

                if hopStatusLabel and (os.clock() % 0.2 < 0.05) then
                    hopStatusLabel.Text = string.format("🚗 ขับไปหาแอร์ดรอป... (ห่าง %.0f เมตร)", flatDist)
                end

                if flatDist <= 12 then
                    rootPart.AssemblyLinearVelocity = Vector3.zero
                    rootPart.AssemblyAngularVelocity = Vector3.zero
                    break
                end

                local speed = 135
                local step = diff.Unit * math.min(speed * dt, diff.Magnitude)
                local nextPos = curPos + step
                local lookVec = Vector3.new(diff.X, 0, diff.Z)
                if lookVec.Magnitude < 0.01 then lookVec = Vector3.new(0, 0, -1) end
                carModel:PivotTo(CFrame.lookAt(nextPos, nextPos + lookVec.Unit))
                rootPart.AssemblyLinearVelocity = diff.Unit * 80
                rootPart.AssemblyAngularVelocity = Vector3.zero
            end

            pcall(function()
                for p, canCol in pairs(origCollide) do
                    if p and p.Parent then p.CanCollide = canCol end
                end
            end)

            if VehicleAction then
                pcall(function() VehicleAction:FireServer("exit") end)
                pcall(function() VehicleAction:FireServer("Exit") end)
                task.wait(0.3)
            end
        else
            while isTravelingToDrop and hum.Health > 0 and (hrp.Position - targetPos).Magnitude > 12 do
                local path = PathfindingService:CreatePath({ AgentRadius = 2.4, AgentHeight = 5.0, AgentCanJump = true, WaypointSpacing = 4.0 })
                local pOk = pcall(function() path:ComputeAsync(hrp.Position, targetPos) end)
                if pOk and path.Status == Enum.PathStatus.Success then
                    local wps = path:GetWaypoints()
                    for i = 2, #wps do
                        if not isTravelingToDrop or hum.Health <= 0 then break end
                        if (hrp.Position - targetPos).Magnitude <= 12 then break end
                        local wp = wps[i]
                        if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
                        hum:MoveTo(wp.Position)
                        local t0 = os.clock()
                        while (hrp.Position - wp.Position).Magnitude > 4.5 and (os.clock() - t0) < 1.8 do
                            task.wait(0.04)
                        end
                    end
                else
                    hum:MoveTo(targetPos)
                    task.wait(0.5)
                end
            end
        end

        if hopStatusLabel then
            hopStatusLabel.Text = "✓ ถึงจุดแอร์ดรอปแล้ว!"
            hopStatusLabel.TextColor3 = Color3.fromRGB(46, 213, 115)
        end
        isTravelingToDrop = false
    end)
end

-- ==================== SMART SERVER HOP ENGINE ====================
local isHopping = false

local function queueSelfOnTeleport()
    local qFunc = (syn and syn.queue_on_teleport) or queue_on_teleport or (fluxus and fluxus.queue_on_teleport)
    if type(qFunc) == "function" then
        pcall(function()
            if type(isfile) == "function" and isfile(SCRIPT_AUTORUN_FILE) then
                qFunc(string.format('if isfile and isfile(%q) then loadstring(readfile(%q))() else pcall(function() loadstring(game:HttpGet(%q))() end) end', SCRIPT_AUTORUN_FILE, SCRIPT_AUTORUN_FILE, LOADER_SHORT_URL))
            else
                qFunc(string.format('pcall(function() loadstring(game:HttpGet(%q))() end)', LOADER_SHORT_URL))
            end
        end)
    end
end

local function teleportToJobId(targetJobId, reasonText)
    if isHopping or not targetJobId or targetJobId == game.JobId then return end
    isHopping = true
    state.visitedServers[targetJobId] = os.time()
    saveState()
    queueSelfOnTeleport()

    if hopStatusLabel then
        hopStatusLabel.Text = reasonText or string.format("🚀 กำลังวาร์ปเข้าเซิร์ฟแอร์ดรอป [%s...]", string.sub(targetJobId, 1, 8))
        hopStatusLabel.TextColor3 = Color3.fromRGB(46, 213, 115)
    end

    task.spawn(function()
        local tpOk, tpErr = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, targetJobId, player)
        end)
        if not tpOk then
            if hopStatusLabel then
                hopStatusLabel.Text = "⚠️ วาร์ปไม่สำเร็จ: " .. tostring(tpErr):sub(1, 38)
                hopStatusLabel.TextColor3 = Color3.fromRGB(255, 110, 110)
            end
            task.wait(1.5)
            isHopping = false
        else
            task.wait(8)
            isHopping = false
        end
    end)
end

local function hopToNextServer()
    if isHopping then return end
    isHopping = true
    saveState()

    if hopStatusLabel then
        hopStatusLabel.Text = "📡 กำลังเช็คเรดาร์เซิร์ฟที่มีแอร์ดรอปยืนยันแล้ว (Cloud Radar)..."
        hopStatusLabel.TextColor3 = Color3.fromRGB(110, 220, 255)
    end

    task.spawn(function()
        local placeId = game.PlaceId

        -- ลำดับที่ 1: เช็คจาก Cloud Verified Airdrop Radar ก่อนเลย (รู้ทันทีว่าเซิร์ฟไหนมีแอร์ดรอปโดยไม่ต้องสุ่ม!)
        pcall(function()
            local resp = game:HttpGet(CLOUD_RADAR_URL .. "?action=airdrop_list")
            if resp and #resp > 2 then
                local ok, data = pcall(function() return HttpService:JSONDecode(resp) end)
                if ok and type(data) == "table" and type(data.servers) == "table" then
                    local now = os.time()
                    for _, srv in ipairs(data.servers) do
                        if type(srv) == "table" and srv.jobId and srv.jobId ~= game.JobId then
                            verifiedServers[srv.jobId] = {
                                jobId = srv.jobId,
                                phase = srv.phase or "FALLING",
                                remaining = tonumber(srv.remaining) or 0,
                                players = tonumber(srv.players) or 0,
                                pos = srv.pos or "",
                                updatedAt = now - (tonumber(srv.age) or 0)
                            }
                        end
                    end
                    saveVerifiedServers()
                end
            end
        end)

        -- หาเซิร์ฟจากรายการที่ยืนยันแล้วว่ามีแอร์ดรอป (Verified 100%)
        local now = os.time()
        for jid, vInfo in pairs(verifiedServers) do
            if jid ~= game.JobId and not state.visitedServers[jid] and (now - (tonumber(vInfo.updatedAt) or 0)) < 210 then
                state.visitedServers[jid] = now
                saveState()
                queueSelfOnTeleport()
                if hopStatusLabel then
                    hopStatusLabel.Text = string.format("🎯 พบเซิร์ฟที่มีแอร์ดรอปในเรดาร์! [%s...] (%s)", string.sub(jid, 1, 8), tostring(vInfo.phase))
                    hopStatusLabel.TextColor3 = Color3.fromRGB(46, 213, 115)
                end
                local tpOk = pcall(function()
                    TeleportService:TeleportToPlaceInstance(placeId, jid, player)
                end)
                if tpOk then
                    task.wait(8)
                    isHopping = false
                    return
                end
            end
        end

        -- ลำดับที่ 2: หากในเรดาร์ยังไม่มีเซิร์ฟที่รายงานเข้ามา ให้ดึงเซิร์ฟที่เข้าเกณฑ์เกิดแอร์ดรอปเพื่อเข้าไปสแกนค่า AirdropBlockAt/AirdropLandAt แบบความเร็วสูง
        if hopStatusLabel then
            hopStatusLabel.Text = "🔍 กำลังดึงเซิร์ฟเพื่อเจาะเช็คค่า AirdropLandAt / AirdropBlockAt..."
            hopStatusLabel.TextColor3 = Color3.fromRGB(255, 215, 80)
        end

        local candidates = {}
        local cursor = ""

        for page = 1, 3 do
            local url = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100%s",
                placeId,
                (cursor ~= "" and ("&cursor=" .. HttpService:UrlEncode(cursor)) or "")
            )
            local ok, resp = pcall(function() return game:HttpGet(url) end)
            if ok and resp then
                local decOk, data = pcall(function() return HttpService:JSONDecode(resp) end)
                if decOk and type(data) == "table" and type(data.data) == "table" then
                    for _, srv in ipairs(data.data) do
                        local jid = srv.id
                        local playing = tonumber(srv.playing) or 0
                        local maxP = tonumber(srv.maxPlayers) or 40
                        if jid and jid ~= game.JobId and not state.visitedServers[jid] then
                            if playing >= state.minPlayers and playing <= (maxP - 2) then
                                table.insert(candidates, { id = jid, playing = playing })
                            end
                        end
                    end
                    if data.nextPageCursor and data.nextPageCursor ~= "" and #candidates < 20 then
                        cursor = data.nextPageCursor
                    else
                        break
                    end
                else
                    break
                end
            else
                break
            end
        end

        if #candidates == 0 then
            state.visitedServers = { [game.JobId] = os.time() }
            saveState()
            if hopStatusLabel then
                hopStatusLabel.Text = "⚠️ สแกนครบทุกเซิร์ฟแล้ว กำลังรีเซ็ตประวัติเพื่อสแกนรอบใหม่..."
            end
            isHopping = false
            task.wait(1.2)
            hopToNextServer()
            return
        end

        local chosen = candidates[math.random(1, math.min(#candidates, 10))]
        state.visitedServers[chosen.id] = os.time()
        saveState()
        queueSelfOnTeleport()

        if hopStatusLabel then
            hopStatusLabel.Text = string.format("🚀 กำลังย้ายไปสแกนเซิร์ฟ [%s...] (คนเล่น %d คน)", string.sub(chosen.id, 1, 8), chosen.playing)
            hopStatusLabel.TextColor3 = Color3.fromRGB(80, 225, 130)
        end

        local tpOk, tpErr = pcall(function()
            TeleportService:TeleportToPlaceInstance(placeId, chosen.id, player)
        end)

        if not tpOk then
            if hopStatusLabel then
                hopStatusLabel.Text = "⚠️ ย้ายไม่สำเร็จ กำลังข้ามไปเซิร์ฟถัดไป... (" .. tostring(tpErr):sub(1, 28) .. ")"
            end
            task.wait(1.5)
            isHopping = false
            hopToNextServer()
            return
        end

        task.wait(8)
        isHopping = false
    end)
end

-- ==================== UI & 3D ESP BEACON ====================
for _, g in ipairs(playerGui:GetChildren()) do
    if g.Name == "UKC_AirdropFinderGUI" then
        pcall(function() g:Destroy() end)
    end
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "UKC_AirdropFinderGUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 85
screenGui.Parent = playerGui

-- 3D Screen Space ESP Marker for Airdrop
local espMarker = Instance.new("Frame")
espMarker.Name = "AirdropBeaconESP"
espMarker.Size = UDim2.new(0, 230, 0, 56)
espMarker.AnchorPoint = Vector2.new(0.5, 0.5)
espMarker.BackgroundColor3 = Color3.fromRGB(20, 12, 16)
espMarker.BackgroundTransparency = 0.12
espMarker.Visible = false
espMarker.Parent = screenGui
Instance.new("UICorner", espMarker).CornerRadius = UDim.new(0, 8)
local espStroke = Instance.new("UIStroke", espMarker)
espStroke.Color = Color3.fromRGB(255, 65, 85)
espStroke.Thickness = 2

local espTitle = Instance.new("TextLabel")
espTitle.Size = UDim2.new(1, -12, 0, 24)
espTitle.Position = UDim2.new(0, 6, 0, 4)
espTitle.BackgroundTransparency = 1
espTitle.Text = "📦 AIRDROP"
espTitle.TextColor3 = Color3.fromRGB(255, 85, 100)
espTitle.Font = Enum.Font.GothamBlack
espTitle.TextSize = 14
espTitle.Parent = espMarker

local espSub = Instance.new("TextLabel")
espSub.Size = UDim2.new(1, -12, 0, 20)
espSub.Position = UDim2.new(0, 6, 0, 28)
espSub.BackgroundTransparency = 1
espSub.Text = "Distance: 0m"
espSub.TextColor3 = Color3.fromRGB(255, 235, 140)
espSub.Font = Enum.Font.GothamBold
espSub.TextSize = 12
espSub.Parent = espMarker

-- Floating Toggle Button
local floatBtn = Instance.new("TextButton")
floatBtn.Size = UDim2.new(0, 140, 0, 32)
floatBtn.Position = UDim2.new(0, 16, 0.5, -60)
floatBtn.BackgroundColor3 = Color3.fromRGB(24, 14, 18)
floatBtn.Text = "📦 AIRDROP RADAR"
floatBtn.TextColor3 = Color3.fromRGB(255, 75, 95)
floatBtn.Font = Enum.Font.GothamBlack
floatBtn.TextSize = 12
floatBtn.Active = true
floatBtn.Draggable = true
floatBtn.Parent = screenGui
Instance.new("UICorner", floatBtn).CornerRadius = UDim.new(0, 8)
local floatStroke = Instance.new("UIStroke", floatBtn)
floatStroke.Color = Color3.fromRGB(255, 65, 85)
floatStroke.Thickness = 1.5

-- Main Window (Dedicated Airdrop Finder Only)
local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 420, 0, 495)
mainFrame.Position = UDim2.new(1, -435, 0.5, -247)
mainFrame.BackgroundColor3 = Color3.fromRGB(14, 13, 18)
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.Draggable = true
mainFrame.Parent = screenGui
Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 10)

local mainStroke = Instance.new("UIStroke", mainFrame)
mainStroke.Color = Color3.fromRGB(225, 55, 75)
mainStroke.Thickness = 1.5

-- Header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 40)
header.BackgroundColor3 = Color3.fromRGB(22, 16, 22)
header.BorderSizePixel = 0
header.Parent = mainFrame
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 14, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "📦 UKC | เรดาร์ค้นหาเซิร์ฟแอร์ดรอป (Deep Telemetry)"
titleLbl.TextColor3 = Color3.fromRGB(255, 80, 100)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 13
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = header

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 28, 0, 26)
minBtn.Position = UDim2.new(1, -34, 0, 7)
minBtn.BackgroundColor3 = Color3.fromRGB(35, 25, 32)
minBtn.Text = "—"
minBtn.TextColor3 = Color3.fromRGB(240, 240, 245)
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 12
minBtn.Parent = header
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

-- Current Server Deep Telemetry Card
local radarCard = Instance.new("Frame")
radarCard.Name = "RadarCard"
radarCard.Size = UDim2.new(1, -24, 0, 88)
radarCard.Position = UDim2.new(0, 12, 0, 48)
radarCard.BackgroundColor3 = Color3.fromRGB(20, 19, 26)
radarCard.BorderSizePixel = 0
radarCard.Parent = mainFrame
Instance.new("UICorner", radarCard).CornerRadius = UDim.new(0, 8)
local radarStroke = Instance.new("UIStroke", radarCard)
radarStroke.Color = Color3.fromRGB(45, 42, 58)
radarStroke.Thickness = 1

local radarStatusLbl = Instance.new("TextLabel")
radarStatusLbl.Size = UDim2.new(1, -16, 0, 22)
radarStatusLbl.Position = UDim2.new(0, 8, 0, 5)
radarStatusLbl.BackgroundTransparency = 1
radarStatusLbl.Text = "กำลังเจาะอ่านค่า Attribute แอร์ดรอปของเซิร์ฟนี้..."
radarStatusLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
radarStatusLbl.Font = Enum.Font.GothamBold
radarStatusLbl.TextSize = 11
radarStatusLbl.TextXAlignment = Enum.TextXAlignment.Left
radarStatusLbl.Parent = radarCard

local radarCycleLbl = Instance.new("TextLabel")
radarCycleLbl.Size = UDim2.new(1, -16, 0, 18)
radarCycleLbl.Position = UDim2.new(0, 8, 0, 27)
radarCycleLbl.BackgroundTransparency = 1
radarCycleLbl.Text = "วงจรเวลาแอร์ดรอป: กำลังคำนวณจาก AirdropLandAt..."
radarCycleLbl.TextColor3 = Color3.fromRGB(255, 210, 95)
radarCycleLbl.Font = Enum.Font.GothamMedium
radarCycleLbl.TextSize = 11
radarCycleLbl.TextXAlignment = Enum.TextXAlignment.Left
radarCycleLbl.Parent = radarCard

local radarPosLbl = Instance.new("TextLabel")
radarPosLbl.Size = UDim2.new(1, -16, 0, 18)
radarPosLbl.Position = UDim2.new(0, 8, 0, 46)
radarPosLbl.BackgroundTransparency = 1
radarPosLbl.Text = "พิกัดจุดตก: -"
radarPosLbl.TextColor3 = Color3.fromRGB(175, 175, 195)
radarPosLbl.Font = Enum.Font.GothamMedium
radarPosLbl.TextSize = 11
radarPosLbl.TextXAlignment = Enum.TextXAlignment.Left
radarPosLbl.Parent = radarCard

hopStatusLabel = Instance.new("TextLabel")
hopStatusLabel.Size = UDim2.new(1, -16, 0, 18)
hopStatusLabel.Position = UDim2.new(0, 8, 0, 65)
hopStatusLabel.BackgroundTransparency = 1
hopStatusLabel.Text = string.format("JobId: %s... | ผู้เล่น: %d คน", string.sub(game.JobId ~= "" and game.JobId or "Local", 1, 8), #Players:GetPlayers())
hopStatusLabel.TextColor3 = Color3.fromRGB(140, 200, 255)
hopStatusLabel.Font = Enum.Font.GothamMedium
hopStatusLabel.TextSize = 11
hopStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
hopStatusLabel.Parent = radarCard

-- Action Buttons
local hopNowBtn = Instance.new("TextButton")
hopNowBtn.Size = UDim2.new(0.5, -16, 0, 34)
hopNowBtn.Position = UDim2.new(0, 12, 0, 144)
hopNowBtn.BackgroundColor3 = Color3.fromRGB(195, 42, 62)
hopNowBtn.Text = "🌐 หาเซิร์ฟแอร์ดรอปทันที"
hopNowBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
hopNowBtn.Font = Enum.Font.GothamBold
hopNowBtn.TextSize = 12
hopNowBtn.Parent = mainFrame
Instance.new("UICorner", hopNowBtn).CornerRadius = UDim.new(0, 7)

local goDropBtn = Instance.new("TextButton")
goDropBtn.Size = UDim2.new(0.5, -16, 0, 34)
goDropBtn.Position = UDim2.new(0.5, 4, 0, 144)
goDropBtn.BackgroundColor3 = Color3.fromRGB(32, 95, 155)
goDropBtn.Text = "🚗 ไปจุดแอร์ดรอปทันที"
goDropBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
goDropBtn.Font = Enum.Font.GothamBold
goDropBtn.TextSize = 12
goDropBtn.Parent = mainFrame
Instance.new("UICorner", goDropBtn).CornerRadius = UDim.new(0, 7)

-- Helper to create Toggle Rows
local function createToggle(yPos, labelText, keyName, onChange)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -24, 0, 32)
    row.Position = UDim2.new(0, 12, 0, yPos)
    row.BackgroundColor3 = Color3.fromRGB(22, 20, 28)
    row.Text = ""
    row.AutoButtonColor = false
    row.Parent = mainFrame
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 7)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -65, 1, 0)
    lbl.Position = UDim2.new(0, 10, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelText
    lbl.TextColor3 = Color3.fromRGB(235, 235, 245)
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local badge = Instance.new("Frame")
    badge.Size = UDim2.new(0, 42, 0, 20)
    badge.Position = UDim2.new(1, -50, 0.5, -10)
    badge.BackgroundColor3 = state[keyName] and Color3.fromRGB(46, 213, 115) or Color3.fromRGB(55, 50, 65)
    badge.Parent = row
    Instance.new("UICorner", badge).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = state[keyName] and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.Parent = badge
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local function refresh()
        badge.BackgroundColor3 = state[keyName] and Color3.fromRGB(46, 213, 115) or Color3.fromRGB(55, 50, 65)
        knob.Position = state[keyName] and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    end

    row.MouseButton1Click:Connect(function()
        state[keyName] = not state[keyName]
        refresh()
        saveState()
        if onChange then onChange(state[keyName]) end
    end)

    return refresh
end

local refreshAutoHop = createToggle(186, "🔄 Auto Hop สแกนย้ายเซิร์ฟอัตโนมัติจนกว่าจะเจอแอร์ดรอปจริง", "autoHop")
createToggle(222, "🔥 หยุดรอถ้าเจอเซิร์ฟที่ครบคูลดาวน์ 40 นาที (กำลังจะปล่อยลูกใหม่)", "stopOnHotWindow")
createToggle(258, "👁️ แสดง ESP ชี้ตำแหน่งแอร์ดรอปทะลุแมพ + เวลานับถอยหลัง", "espEnabled")
createToggle(294, "⚡ เก็บแอร์ดรอปอัตโนมัติเมื่อเข้าใกล้ (Auto Claim)", "autoClaim")

-- ==================== LIVE VERIFIED AIRDROP SERVERS LIST ====================
local listHeader = Instance.new("TextLabel")
listHeader.Size = UDim2.new(1, -110, 0, 20)
listHeader.Position = UDim2.new(0, 12, 0, 334)
listHeader.BackgroundTransparency = 1
listHeader.Text = "📡 เรดาร์เซิร์ฟที่ตรวจพบแอร์ดรอปจริง (Cloud Verified)"
listHeader.TextColor3 = Color3.fromRGB(80, 225, 145)
listHeader.Font = Enum.Font.GothamBlack
listHeader.TextSize = 11
listHeader.TextXAlignment = Enum.TextXAlignment.Left
listHeader.Parent = mainFrame

local refreshRadarBtn = Instance.new("TextButton")
refreshRadarBtn.Size = UDim2.new(0, 88, 0, 22)
refreshRadarBtn.Position = UDim2.new(1, -100, 0, 333)
refreshRadarBtn.BackgroundColor3 = Color3.fromRGB(28, 45, 36)
refreshRadarBtn.Text = "🔄 รีเฟรชเรดาร์"
refreshRadarBtn.TextColor3 = Color3.fromRGB(140, 255, 180)
refreshRadarBtn.Font = Enum.Font.GothamBold
refreshRadarBtn.TextSize = 10
refreshRadarBtn.Parent = mainFrame
Instance.new("UICorner", refreshRadarBtn).CornerRadius = UDim.new(0, 5)

local serverScroll = Instance.new("ScrollingFrame")
serverScroll.Name = "VerifiedServerList"
serverScroll.Size = UDim2.new(1, -24, 0, 124)
serverScroll.Position = UDim2.new(0, 12, 0, 358)
serverScroll.BackgroundColor3 = Color3.fromRGB(18, 17, 23)
serverScroll.BorderSizePixel = 0
serverScroll.ScrollBarThickness = 4
serverScroll.ScrollBarImageColor3 = Color3.fromRGB(225, 55, 75)
serverScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
serverScroll.Parent = mainFrame
Instance.new("UICorner", serverScroll).CornerRadius = UDim.new(0, 8)
local listStroke = Instance.new("UIStroke", serverScroll)
listStroke.Color = Color3.fromRGB(42, 38, 54)
listStroke.Thickness = 1

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = serverScroll

local listPadding = Instance.new("UIPadding")
listPadding.PaddingTop = UDim.new(0, 6)
listPadding.PaddingBottom = UDim.new(0, 6)
listPadding.PaddingLeft = UDim.new(0, 6)
listPadding.PaddingRight = UDim.new(0, 6)
listPadding.Parent = serverScroll

local function rebuildVerifiedServerUI()
    for _, ch in ipairs(serverScroll:GetChildren()) do
        if ch:IsA("Frame") or ch:IsA("TextLabel") then
            ch:Destroy()
        end
    end

    local now = os.time()
    local items = {}
    for jid, info in pairs(verifiedServers) do
        local age = now - (tonumber(info.updatedAt) or 0)
        if age < 210 then
            table.insert(items, { jid = jid, info = info, age = age })
        end
    end

    if #items == 0 then
        local emptyLbl = Instance.new("TextLabel")
        emptyLbl.Size = UDim2.new(1, -8, 0, 44)
        emptyLbl.BackgroundTransparency = 1
        emptyLbl.Text = "ยังไม่มีเซิร์ฟที่รายงานแอร์ดรอปเข้ามาในเรดาร์ขณะนี้\n(กด '🔄 Auto Hop' เพื่อให้ระบบสแกนเจาะเช็คค่า AirdropBlockAt อัตโนมัติ)"
        emptyLbl.TextColor3 = Color3.fromRGB(145, 145, 165)
        emptyLbl.Font = Enum.Font.GothamMedium
        emptyLbl.TextSize = 10
        emptyLbl.TextWrapped = true
        emptyLbl.Parent = serverScroll
        serverScroll.CanvasSize = UDim2.new(0, 0, 0, 54)
        return
    end

    for idx, entry in ipairs(items) do
        local jid = entry.jid
        local v = entry.info
        local liveRem = math.max(0, (tonumber(v.remaining) or 0) - entry.age)
        local phase = (v.phase == "FALLING" and liveRem <= 0) and "LANDED" or (v.phase or "FALLING")
        local isCurrent = (jid == game.JobId)

        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -4, 0, 34)
        row.BackgroundColor3 = isCurrent and Color3.fromRGB(24, 42, 30) or Color3.fromRGB(25, 23, 33)
        row.BorderSizePixel = 0
        row.LayoutOrder = idx
        row.Parent = serverScroll
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

        local statusTxt = phase == "LANDED"
            and "🟢 ตกถึงพื้นแล้ว!"
            or string.format("🟡 กำลังร่วง (%d:%02d)", math.floor(liveRem / 60), math.floor(liveRem % 60))

        local infoLbl = Instance.new("TextLabel")
        infoLbl.Size = UDim2.new(1, -105, 1, 0)
        infoLbl.Position = UDim2.new(0, 8, 0, 0)
        infoLbl.BackgroundTransparency = 1
        infoLbl.Text = string.format("[%s] %s | คน: %s", string.sub(jid, 1, 8), statusTxt, tostring(v.players or "?"))
        infoLbl.TextColor3 = phase == "LANDED" and Color3.fromRGB(80, 245, 140) or Color3.fromRGB(255, 220, 90)
        infoLbl.Font = Enum.Font.GothamBold
        infoLbl.TextSize = 10
        infoLbl.TextXAlignment = Enum.TextXAlignment.Left
        infoLbl.Parent = row

        local joinBtn = Instance.new("TextButton")
        joinBtn.Size = UDim2.new(0, 86, 0, 24)
        joinBtn.Position = UDim2.new(1, -92, 0.5, -12)
        joinBtn.BackgroundColor3 = isCurrent and Color3.fromRGB(45, 75, 55) or Color3.fromRGB(46, 175, 95)
        joinBtn.Text = isCurrent and "✓ เซิร์ฟปัจจุบัน" or "⚡ วาร์ปเข้า"
        joinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        joinBtn.Font = Enum.Font.GothamBold
        joinBtn.TextSize = 10
        joinBtn.Parent = row
        Instance.new("UICorner", joinBtn).CornerRadius = UDim.new(0, 5)

        if not isCurrent then
            joinBtn.MouseButton1Click:Connect(function()
                teleportToJobId(jid, string.format("🚀 กำลังวาร์ปเข้าเซิร์ฟแอร์ดรอป [%s...]", string.sub(jid, 1, 8)))
            end)
        end
    end

    serverScroll.CanvasSize = UDim2.new(0, 0, 0, (#items * 38) + 12)
end

rebuildVerifiedServerUI()

refreshRadarBtn.MouseButton1Click:Connect(function()
    refreshRadarBtn.Text = "⏳ กำลังดึง..."
    fetchVerifiedServersFromCloud(function()
        rebuildVerifiedServerUI()
        refreshRadarBtn.Text = "🔄 รีเฟรชเรดาร์"
    end)
end)

hopNowBtn.MouseButton1Click:Connect(function()
    hopToNextServer()
end)

goDropBtn.MouseButton1Click:Connect(function()
    local info = getAirdropStatus()
    if info.active and info.pos then
        travelToAirdropPos(info.pos)
    else
        hopStatusLabel.Text = "❌ เซิร์ฟนี้ยังไม่มีแอร์ดรอปให้เดินทางไปหา!"
        hopStatusLabel.TextColor3 = Color3.fromRGB(255, 95, 95)
    end
end)

local function toggleMenu()
    mainFrame.Visible = not mainFrame.Visible
end
minBtn.MouseButton1Click:Connect(toggleMenu)
floatBtn.MouseButton1Click:Connect(toggleMenu)

-- ==================== MAIN RENDER & FAST SCANNER LOOP ====================
local autoHopCountdownStart = nil

local renderConn
renderConn = RunService.RenderStepped:Connect(function()
    if not screenGui.Parent then
        if renderConn then renderConn:Disconnect() end
        return
    end

    local info = getAirdropStatus()
    if info.active and state.espEnabled and info.pos then
        local screenPos, onScreen = camera:WorldToViewportPoint(info.pos + Vector3.new(0, 5, 0))
        if onScreen then
            espMarker.Position = UDim2.new(0, screenPos.X, 0, screenPos.Y)
            espMarker.Visible = true
            if info.phase == "LANDED" then
                espTitle.Text = "🟢 📦 AIRDROP (พร้อมเก็บ!)"
                espTitle.TextColor3 = Color3.fromRGB(46, 213, 115)
                espStroke.Color = Color3.fromRGB(46, 213, 115)
                espSub.Text = string.format("ระยะห่าง: %.0f เมตร", info.dist)
            else
                espTitle.Text = "🟡 🪂 AIRDROP (กำลังร่วง)"
                espTitle.TextColor3 = Color3.fromRGB(255, 200, 60)
                espStroke.Color = Color3.fromRGB(255, 200, 60)
                espSub.Text = string.format("อีก %.0f วินาทีถึงพื้น | ห่าง %.0f เมตร", info.remaining, info.dist)
            end
        else
            espMarker.Visible = false
        end
    else
        espMarker.Visible = false
    end
end)

-- ดึงข้อมูลเรดาร์กลางทันทีที่รัน
fetchVerifiedServersFromCloud(function()
    rebuildVerifiedServerUI()
end)

task.spawn(function()
    -- รอเพียง 0.8 วินาทีให้ ReplicatedStorage Attributes ซิงค์เสร็จ (ไม่ต้องรอโหลดแมพ 15 วินาที!)
    task.wait(0.8)
    while screenGui.Parent do
        local info = getAirdropStatus()
        radarStatusLbl.Text = info.statusText
        radarCycleLbl.Text = info.cycleText or ""

        -- รายงานสถานะเซิร์ฟนี้ขึ้น Cloud Radar อัตโนมัติ
        reportCurrentServerToCloud(info)

        if os.clock() - lastCloudFetch >= 15 then
            lastCloudFetch = os.clock()
            fetchVerifiedServersFromCloud(function()
                rebuildVerifiedServerUI()
            end)
        end

        if info.active then
            if info.pos then
                radarPosLbl.Text = string.format("พิกัดจุดตกจริง: X: %.0f | Y: %.0f | Z: %.0f (ห่าง %.0f ม.)", info.pos.X, info.pos.Y, info.pos.Z, info.dist)
            else
                radarPosLbl.Text = "พิกัดจุดตกจริง: กำลังคำนวณจากวิถีเครื่องบิน..."
            end

            if info.phase == "LANDED" then
                radarStatusLbl.TextColor3 = Color3.fromRGB(46, 213, 115)
                radarStroke.Color = Color3.fromRGB(46, 213, 115)
                tryAutoClaim(info)
            else
                radarStatusLbl.TextColor3 = Color3.fromRGB(255, 210, 70)
                radarStroke.Color = Color3.fromRGB(255, 210, 70)
            end

            if state.autoHop then
                state.autoHop = false
                refreshAutoHop()
                saveState()
                autoHopCountdownStart = nil
                hopStatusLabel.Text = "🎉 ยืนยันเจอเซิร์ฟที่มีแอร์ดรอปจริงแล้ว! (หยุดย้ายเซิร์ฟอัตโนมัติ)"
                hopStatusLabel.TextColor3 = Color3.fromRGB(46, 213, 115)
                rebuildVerifiedServerUI()
            end
        elseif info.isHotWindow and state.stopOnHotWindow then
            radarStatusLbl.TextColor3 = Color3.fromRGB(255, 165, 50)
            radarStroke.Color = Color3.fromRGB(255, 165, 50)
            radarPosLbl.Text = string.format("ผู้เล่นในเซิร์ฟ: %d คน (พร้อมเกิดแอร์ดรอปลูกใหม่)", #Players:GetPlayers())

            if state.autoHop then
                state.autoHop = false
                refreshAutoHop()
                saveState()
                autoHopCountdownStart = nil
                hopStatusLabel.Text = "🔥 เจอเซิร์ฟ Hot Window (ครบคูลดาวน์ 40 นาทีแล้ว) หยุดรอแอร์ดรอปเกิด!"
                hopStatusLabel.TextColor3 = Color3.fromRGB(255, 175, 60)
            end
        else
            radarStatusLbl.TextColor3 = Color3.fromRGB(255, 95, 95)
            radarStroke.Color = Color3.fromRGB(65, 35, 42)
            radarPosLbl.Text = string.format("พิกัดแอร์ดรอป: ไม่มี | ผู้เล่นในเซิร์ฟ: %d คน", #Players:GetPlayers())

            if state.autoHop and not isHopping then
                if not autoHopCountdownStart then
                    autoHopCountdownStart = os.clock()
                end
                local elapsed = os.clock() - autoHopCountdownStart
                local left = math.max(0, state.fastScanDelay - elapsed)
                if left > 0 then
                    hopStatusLabel.Text = string.format("⚡ สแกนแล้วไม่มีแอร์ดรอป! กำลังดีดไปเซิร์ฟถัดไปใน %.1f วิ...", left)
                    hopStatusLabel.TextColor3 = Color3.fromRGB(255, 195, 70)
                else
                    autoHopCountdownStart = nil
                    hopToNextServer()
                end
            else
                autoHopCountdownStart = nil
            end
        end

        task.wait(0.25)
    end
end)
