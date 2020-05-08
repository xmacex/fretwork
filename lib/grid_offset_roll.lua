local Roll = include 'lib/grid_roll'

local OffsetRoll = setmetatable({}, Roll)
OffsetRoll.__index = OffsetRoll

function OffsetRoll.new(x, y, width, height, n_voices, voices, type)
	local roll = setmetatable(Roll.new(x, y, width, height, n_voices, voices), OffsetRoll)
	roll.tap_key = type .. '_tap'
	return roll
end

-- TODO: any way to make this not so twitchy when rates differ?
function OffsetRoll:get_key_level(x, y, v, step)
	local voice = self.voices[v]
	local tap = voice[self.tap_key]
	local top_tap = top_voice[self.tap_key] -- TODO: avoid global state
	-- TODO: this assumes all taps' SRs are the same; is it useless if they aren't?
	local head = tap:check_step_pos(-step, top_tap:get_step_pos(0))
	local active = voice.active
	if not active then
		if head then
			return 2
		end
	elseif v == top_voice_index then
		if head then
			return 14
		end
	elseif voice_selector:is_selected(v) then
		if head then
			return 12
		end
	elseif head then
		return 6
	end
	return 0
end

return OffsetRoll
