-- check if a specified point on the terrain is in shadow at a given moment in time
-- note that this only checks against the terrain heightfield, 
-- i.e. large rocks or other buildings aren't taken into account

local GetHeight = terrain.GetHeight
local IsPointInBounds = terrain.IsPointInBounds

-- length of a single step when tracing the terrain heightfield;
-- smaller steps resolve narrow ridges better, at a proportionally higher cost
local trace_step_len = 10 * const.HeightTileSize

-- inverse of the engine's ComputeSunDirection - the sun direction points from the sun down to the ground,
-- hence the negated z; the azimuth is measured from North, which is -Y on the map
-- 'time' is an absolute game time; a negative value means the current moment
local function GetSunAzimuthElevation(time)
	local sunDir = GetSunDirection(time)
	local horiz_len = math.sqrt(sunDir[1] * sunDir[1] + sunDir[2] * sunDir[2])
	local azimuth = round(math.atan(sunDir[2], sunDir[1]) * 60 * const.inv_pi_over_180) - 90 * 60
	local elevation = round(math.atan(-sunDir[3], horiz_len) * 60 * const.inv_pi_over_180)
	return azimuth, elevation
end

local function IsPointInShadow(solar_panel, pt_panel, time)
	local azimuth, elevation = GetSunAzimuthElevation(time)
	if elevation <= 0 then return true end -- sun below the horizon, no need to trace

	local elevation_s, elevation_c = sincos(elevation)
	local elevation_tg = 1.0 * elevation_s / elevation_c -- force floating-point
	local height_panel = GetHeight(solar_panel, pt_panel)
	local height_max = const.MaxTerrainHeight - height_panel

	-- trace a ray from the starting point in the direction (azimuth) of the sun
	local s, c = sincos(azimuth) -- this returns fixed point base-4096
	local step = SetLen(point(s, -c), trace_step_len) -- azimuth 0 points at -Y, 90 degrees at +X
	local pt = pt_panel + step
	local dist = trace_step_len -- distance along the ray, kept in step with pt

	while IsPointInBounds(solar_panel, pt) do -- exit condition - when ray exits map
		local height_pt = GetHeight(solar_panel, pt)
		local height_thres = dist * elevation_tg
		if height_pt - height_panel > height_thres then
			-- if current point along ray is at a higher angle over the starting point than the sun elevation, point is in shadow
			return true
		elseif height_max < height_thres then
			-- if even maximum height at this point wouldn't result in a shadow, abort tracing
			return false
		end
		-- step along ray
		pt = pt + step
		dist = dist + trace_step_len
	end
	return false
end

-- track shadow state of solar panels with no more than 4 values per hour
local time_precision = const.HourDuration / 4

GameVar("g_SolarPanelInShadowMemorize", false)

-- cache the expensive shadowing calculation per panel, per "time precision" unit
function IsInShadow(solar_panel)
	local mem = g_SolarPanelInShadowMemorize
	if not mem then
		mem = setmetatable({}, weak_keys_meta)
		g_SolarPanelInShadowMemorize = mem
	end
	local panel_mem = mem[solar_panel] or {}
	mem[solar_panel] = panel_mem
	local now = GameTime()
	local day_time = now % const.DayDuration
	local slot = day_time / time_precision
	if panel_mem[slot] == nil then
		-- evaluate the sun at the middle of the slot, so the cached value matches the time of day it is stored under
		local slot_time = now - day_time + slot * time_precision + time_precision / 2
		panel_mem[slot] = IsPointInShadow(solar_panel, solar_panel:GetPos(), slot_time)
	end
	return panel_mem[slot]
end


AppendClass.SolarPanelBase = {
	shadow_penalty_modifier = false,
}

local OldUpdateProduction = SolarPanelBase.UpdateProduction
function SolarPanelBase:UpdateProduction(...)
	OldUpdateProduction(self, ...)

	if not self.shadow_penalty_modifier then
		self.shadow_penalty_modifier = ObjectModifier:new{
			target = self, 
			prop = "electricity_production",
			percent = -75,
		}
	end

	if IsInShadow(self) then
		self.shadow_penalty_modifier:TurnOn()
	else
		self.shadow_penalty_modifier:TurnOff()
	end
end
