-- follower
-- follow pitch, quantize, etc...

engine.name = 'PolySub'
polysub = require 'we/lib/polysub'

musicutil = require 'musicutil'
BeatClock = require 'beatclock'

Keyboard = include 'lib/grid_keyboard'
Select = include 'lib/grid_select'
MultiSelect = include 'lib/grid_multi_select'
ShiftRegister = include 'lib/shift_register'
ShiftRegisterVoice = include 'lib/shift_register_voice'
Scale = include 'lib/scale'

pitch_poll = nil
pitch_in_value = 0
pitch_in_detected = false
pitch_in_octave = 0
crow_in_values = { 0, 0 }

-- calculate pitch class values
et12 = {} -- 12TET
for p = 1, 12 do 
	et12[p] = (p - 1) / 12
end
-- et41 = {} -- 41TET -- TODO: use!
-- for p = 1, 41 do 
-- 	et41[p] = (p - 1) / 41
-- end
-- TODO: add uneven/JI scales
scale = Scale.new(et12)
saved_masks = {}
mask_dirty = false
mask_selector = Select.new(1, 3, 4, 4)

config_dirty = false
saved_configs = {}
config_selector = Select.new(1, 3, 4, 4)

saved_loops = {}
loop_selector = Select.new(1, 3, 4, 4)

memory_selector = Select.new(1, 2, 3, 1)
memory_loop = 1
memory_mask = 2
memory_config = 3

-- TODO: save/recall mask, loop, and config all at once

shift_register = ShiftRegister.new(32)

source = 1
source_names = {
	'grid',
	'pitch track',
	'crow input 2',
	'grid OR pitch',
	'grid OR crow'
	-- TODO: random, LFO
}
source_grid = 1
source_pitch = 2
source_crow = 3
source_grid_pitch = 4
source_grid_crow = 5

noop = function() end
events = {
	beat = noop,
	trigger1 = noop,
	trigger2 = noop,
	key = noop
}

beatclock = BeatClock.new()
beatclock.on_step = function()
	if beatclock.step == 0 or beatclock.step == 2 then
		events.beat()
	end
end

-- TODO: clock from MIDI notes
clock_mode = 1
clock_mode_names = {
	'crow input 1',
	'grid',
	'crow in OR grid',
	'beatclock'
}
clock_mode_trig = 1
clock_mode_grid = 2
clock_mode_trig_grid = 3
clock_mode_beatclock = 4

voices = {}
n_voices = 4
voice_draw_order = { 4, 3, 2, 1 }
top_voice_index = 1
top_voice = {}

grid_mode_play = 1
grid_mode_mask = 2
grid_mode_transpose = 3
grid_mode = grid_mode_play

voice_selector = MultiSelect.new(5, 3, 1, 4)

g = grid.connect()
m = midi.connect()

grid_shift = false
grid_ctrl = false
grid_octave_key_held = false
input_keyboard = Keyboard.new(6, 1, 11, 8, scale)
control_keyboard = Keyboard.new(6, 1, 11, 8, scale)
keyboard = input_keyboard

screen_note_width = 4
n_screen_notes = 128 / screen_note_width
screen_note_center = math.floor((n_screen_notes - 1) / 2 + 0.5)
screen_notes = { {}, {}, {}, {} }

recent_writes = { nil, nil, nil, nil, nil, nil, nil, nil }
n_recent_writes = 8
last_write = 0

key_shift = false
info_visible = false
blink_slow = false
blink_fast = false
dirty = false
info_metro = nil
redraw_metro = nil

-- LOOP/MASK/TRANSPOSE QUANTIZATION
-- for each of these, maintain an 'edit buffer' separate from the version that's actually currently
-- being used by SR/voices
-- edits/changes are applied to this edit buffer, which replaces the in-use version on each beat
-- save/recall uses edit buffer too: if you edit the current mask, save your edit to a new slot, and
-- recall the current slot in the space of one beat, you won't have to hear your changes; then you
-- can queue them up to hear several beats later
-- saving/recalling loops will be slightly more complicated, since beats affect loop state (loop is
-- shifted with each beat).
-- so when you save a loop, that should save the _next_ state of the loop -- the shifted loop that
-- would be heard on the next beat. (so you can save the current loop + recall it within one beat
-- and it won't sound like any change was made.)

function recall_mask()
	if saved_masks[mask_selector.selected] == nil then
		return
	end
	scale:set_edit_mask(saved_masks[mask_selector.selected])
	mask_dirty = false
end

function save_mask()
	saved_masks[mask_selector.selected] = scale:get_edit_mask()
	mask_dirty = false
end

function recall_loop()
	-- TODO: queue up the recalled loop to start on the NEXT clock tick, unless Ctrl held
	-- or, think of it as quantizing save/recall events, so they only happen on a tick, or every 4 ticks, or...
	if saved_loops[loop_selector.selected] == nil then
		return
	end
	shift_register:set_loop(0, saved_loops[loop_selector.selected])
	shift_register.dirty = false
end

function save_loop()
	saved_loops[loop_selector.selected] = shift_register:get_loop(0)
	shift_register.dirty = false
end

function recall_config()
	local c = config_selector.selected
	if saved_configs[c] == nil then
		return
	end
	for v = 1, n_voices do
		local config = saved_configs[c][v]
		params:set(string.format('voice_%d_transpose', v), config.transpose)
		params:set(string.format('voice_%d_scramble', v), config.scramble)
		voices[v].pos = shift_register.head + config.offset
		params:set(string.format('voice_%d_direction', v), config.direction == -1 and 2 or 1)
	end
	config_dirty = false
end

function save_config()
	local config = {}
	for v = 1, n_voices do
		config[v] = {
			offset = voices[v].tap:get_loop_offset(0),
			transpose = voices[v].transpose,
			scramble = voices[v].tap.scramble,
			direction = voices[v].tap.direction
		}
	end
	saved_configs[config_selector.selected] = config
	config_dirty = false
end

function update_voice(v)
	local voice = voices[v]
	voice:update_value()
	if voice.value ~= null then
		engine.start(v - 1, musicutil.note_num_to_freq(60 + voice.value * 12))
		crow.output[v].volts = voice.value
	end
end

function update_voices()
	for v = 1, n_voices do
		update_voice(v)
	end
end

function get_write_value()
	-- TODO: watch debug output using pitch + crow sources to make sure they're working
	if input_keyboard.gate and (source == source_grid or source == source_grid_pitch or source == source_grid_crow) then
		-- TODO: this is good for held keys, but maybe we should also _quantize_ key presses:
		-- when a key is pressed < 0.5 step after a clock tick, write to the current position and update outputs
		-- when a key is pressed > 0.5 step after a clock tick, write to the NEXT position
		-- ...that won't work with irregular clocks, though
		-- maybe you only perform the write/update on the next tick...?
		-- that might feel strange unless you can also update voice(s) immediately without writing
		print(string.format('writing grid pitch (source = %d)', source))
		return input_keyboard:get_last_value()
	elseif source == source_pitch or source == source_grid_pitch then
		print(string.format('writing audio pitch (source = %d)', source))
		return pitch_in_value
	elseif source == source_crow or source == source_grid_crow then
		print(string.format('writing crow pitch (source = %d)', source))
		return crow_in_values[2]
	end
	print(string.format('nothing to write (source = %d)', source))
	return false
end

function maybe_write()
	local prob = params:get('write_probability')
	if prob > math.random(1, 100) then
		local value = get_write_value()
		if not value then
			return
		end
		for v = 1, n_voices do
			-- TODO: this should probably happen whenever a key is pressed, NOT (just?) on clock ticks
			if voice_selector:is_selected(v) then
				local voice = voices[v]
				voice:set(0, value)
				-- TODO: is this useful?
				last_write = last_write % n_recent_writes + 1
				recent_writes[last_write] = {
					level = 15,
					pos = voice.tap:get_pos(0),
					value = value - voice.transpose
				}
			end
		end
	end
end

function shift(d)
	shift_register:shift(d)
	for v = 1, n_voices do
		voices[v]:shift(d)
	end
	maybe_write()
	scale:apply_edit_mask()
	update_voices()
	dirty = true
end

function advance()
	shift(1)
end

function rewind()
	shift(-1)
end

function update_active_heads(last_voice) -- TODO: rename this, wtf
	if last_voice then
		local new_draw_order = {}
		for i, o in ipairs(voice_draw_order) do
			if o ~= last_voice then
				table.insert(new_draw_order, o)
			end
		end
		table.insert(new_draw_order, last_voice)
		top_voice_index = new_draw_order[n_voices]
		top_voice = voices[top_voice_index]
		voice_draw_order = new_draw_order
	end
end

function grid_redraw()

	-- mode buttons
	g:led(1, 1, grid_mode == grid_mode_play and 7 or 2)
	g:led(2, 1, grid_mode == grid_mode_mask and 7 or 2)
	g:led(3, 1, grid_mode == grid_mode_transpose and 7 or 2)

	-- recall mode buttons
	memory_selector:draw(g, 7, 2)

	-- recall buttons
	if memory_selector:is_selected(memory_mask) then
		mask_selector:draw(g, mask_dirty and blink_slow and 8 or 7, 2)
	elseif memory_selector:is_selected(memory_config) then
		config_selector:draw(g, config_dirty and blink_slow and 8 or 7, 2)
	else
		loop_selector:draw(g, shift_register.dirty and blink_slow and 8 or 7, 2)
	end

	-- shift + ctrl
	g:led(1, 7, grid_shift and 15 or 2)
	g:led(1, 8, grid_ctrl and 15 or 2)

	-- voice buttons
	voice_selector:draw(g, 10, 5)

	-- keyboard octaves
	g:led(3, 8, 2 - math.min(keyboard.octave, 0))
	g:led(4, 8, 2 + math.max(keyboard.octave, 0))

	-- keyboard
	keyboard:draw(g)
	g:refresh()
end

key_level_callbacks = {}

key_level_callbacks[grid_mode_play] = function(self, x, y, n)
	local level = 0
	-- highlight mask
	if self.scale:mask_contains(n) then
		level = 4
	end
	-- highlight voice notes
	for v = 1, n_voices do
		local voice = voices[v]
		if n == voice.pitch_id then
			if voice_selector:is_selected(v) then
				level = 10
			else
				level = math.max(level, 7)
			end
		end
	end
	-- highlight current note
	if self.gate and self:is_key_last(x, y) then
		level = 15
	end
	return level
end

key_level_callbacks[grid_mode_mask] = function(self, x, y, n)
	local level = 0
	-- highlight white keys
	if self:is_white_key(n) then
		level = 2
	end
	-- highlight mask
	local in_mask = self.scale:mask_contains(n)
	local in_edit_mask = self.scale:edit_mask_contains(n)
	if in_mask and in_edit_mask then
		level = 5
	elseif in_edit_mask then
		level = 4
	elseif in_mask then
		level = 3
	end
	-- highlight voice notes
	for v = 1, n_voices do
		if n == voices[v].pitch_id then
			if voice_selector:is_selected(v) then
				level = 10
			else
				level = math.max(level, 7)
			end
		end
	end
	return level
end

key_level_callbacks[grid_mode_transpose] = function(self, x, y, n)
	local level = 0
	-- highlight octaves
	if (n - self.scale.center_pitch_id) % self.scale.length == 1 then
		level = 2
	end
	-- highlight transposition settings
	for v = 1, n_voices do
		if n == self.scale:get_nearest_pitch_id(voices[v].transpose) then
			if voice_selector:is_selected(v) then
				level = 10
			else
				level = math.max(level, 5)
			end
		end
	end
	return level
end

function grid_octave_key(z, d)
	if z == 1 then
		if grid_octave_key_held then
			keyboard.octave = 0
		else
			keyboard.octave = keyboard.octave + d
		end
	end
	grid_octave_key_held = z == 1
end

function grid_key(x, y, z)
	if keyboard:should_handle_key(x, y) then
		-- TODO: use events here too, maybe?
		if grid_mode == grid_mode_play and not grid_shift then
			local previous_note = keyboard:get_last_pitch_id()
			keyboard:note(x, y, z)
			if keyboard.gate and (previous_note ~= keyboard:get_last_pitch_id() or z == 1) then
				events.key()
			end
		elseif grid_mode == grid_mode_mask or (grid_mode == grid_mode_play and grid_shift) then
			if z == 1 then
				local n = keyboard:get_key_pitch_id(x, y)
				scale:toggle_class(n)
				mask_dirty = true
				-- TODO: when ctrl is not held, make it visually obvious that the change is pending, rather
				-- than reflecting change immediately in UI
				-- maybe in part by pushing a closure onto a queue of actions to take on the next clock tick
				if grid_ctrl then
					update_voices()
				end
			end
		elseif grid_mode == grid_mode_transpose then
			keyboard:note(x, y, z)
			if keyboard.gate then
				local transpose = keyboard:get_last_value() - top_voice.transpose
				for v = 1, n_voices do
					if voice_selector:is_selected(v) then
						params:set(string.format('voice_%d_transpose', v), voices[v].transpose + transpose)
					end
				end
			end
		end
	elseif voice_selector:should_handle_key(x, y) then
		local voice = voice_selector:get_key_option(x, y)
		voice_selector:key(x, y, z)
		update_active_heads(z == 1 and voice)
	elseif x == 3 and y == 8 then
		grid_octave_key(z, -1)
	elseif x == 4 and y == 8 then
		grid_octave_key(z, 1)
	elseif x < 5 and y == 1 and z == 1 then
		-- grid mode buttons
		if x == 1 then
			grid_mode = grid_mode_play
			keyboard = input_keyboard
		elseif x == 2 then
			grid_mode = grid_mode_mask
			keyboard = control_keyboard -- TODO: this still feels weird
		elseif x == 3 then
			grid_mode = grid_mode_transpose
			keyboard = control_keyboard
		end
		-- set the grid drawing routine based on new mode
		keyboard.get_key_level = key_level_callbacks[grid_mode]
		-- clear held note stack, in order to prevent held notes from getting stuck when switching to a
		-- mode that doesn't call `keyboard:note()`
		keyboard:reset()
	elseif memory_selector:should_handle_key(x, y) then
		memory_selector:key(x, y, z)
	elseif memory_selector:is_selected(memory_mask) and mask_selector:should_handle_key(x, y) then
		mask_selector:key(x, y, z)
		-- TODO: these should be callbacks/handlers, properties on the selector objects
		if z == 1 then
			if grid_shift then
				save_mask()
			else
				recall_mask()
				if grid_ctrl then
					update_voices()
				end
			end
		end
	elseif memory_selector:is_selected(memory_config) and config_selector:should_handle_key(x, y) then
		config_selector:key(x, y, z)
		if z == 1 then
			if grid_shift then
				save_config()
			else
				recall_config()
			end
		end
	elseif memory_selector:is_selected(memory_loop) and loop_selector:should_handle_key(x, y) then
		loop_selector:key(x, y, z)
		if z == 1 then
			if grid_shift then
				save_loop()
			else
				recall_loop()
				if grid_ctrl then
					update_voices()
				end
			end
		end
	elseif x == 1 and y == 7 then
		-- shift key
		grid_shift = z == 1
	elseif x == 1 and y == 8 then
		-- ctrl key
		if x == 1 then
			grid_ctrl = z == 1
		end
	end
	dirty = true
end

function midi_event(data)
	local msg = midi.to_msg(data)
	if msg.type == 'note_on' then
		for v = 1, n_voices do
			local voice = voices[v]
			if voice.clock_channel == msg.ch and voice.clock_note == msg.note then
				voice:shift(1)
			end
		end
	end
end

function update_freq(value)
	-- TODO: better check amplitude too -- this detects a 'pitch' when there's no audio input
	pitch_in_detected = value > 0
	if pitch_in_detected then
		pitch_in_value = math.log(value / 440.0) / math.log(2) + 3.75 + pitch_in_octave
		dirty = true
	end
end

function show_info()
	info_visible = true
	dirty = true
	if not key_shift then
		info_metro:stop()
		info_metro:start(0.75)
	end
end

function crow_setup()
	crow.clear()
	-- input modes will be set by params
	crow.input[1].change = function()
		events.trigger1()
	end
	crow.input[2].change = function()
		events.trigger2()
	end
	crow.input[1].stream = function(value) -- not used... yet!
		crow_in_values[1] = value
	end
	crow.input[2].stream = function(value)
		crow_in_values[2] = value
	end
	params:bang()
end

function add_params()
	-- TODO: read from crow input 2
	-- TODO: and/or add a grid control

	-- TODO: group params better
	params:add_group('clock', 4)
	params:add{
		type = 'option',
		id = 'shift_clock',
		name = 'sr/s+h clock',
		options = clock_mode_names,
		default = clock_mode_beatclock,
		action = function(value)
			clock_mode = value
			if clock_mode == clock_mode_grid or clock_mode == clock_mode_trig_grid then
				events.key = advance
			else
				events.key = noop
			end
			if clock_mode == clock_mode_trig or clock_mode == clock_mode_trig_grid then
				events.trigger1 = advance
				crow.input[1].mode('change', 2.0, 0.25, 'rising')
			else
				events.trigger1 = noop
				crow.input[1].mode('none')
			end
			if clock_mode == clock_mode_beatclock then
				events.beat = advance
				beatclock:start()
			else
				events.beat = noop
				beatclock:stop()
			end
		end
	}
	beatclock:add_clock_params()

	params:add{
		type = 'option',
		id = 'shift_source',
		name = 'sr source',
		options = source_names,
		default = source_grid,
		action = function(value)
			source = value
			if source == source_crow then
				crow.input[2].mode('stream', 1/32) -- TODO: is this too fast? not fast enough? what about querying?
			else
				crow.input[2].mode('none')
			end
		end
	}
	params:add{
		type = 'control',
		id = 'write_probability',
		name = 'write probability',
		controlspec = controlspec.new(1, 101, 'exp', 1, 1),
		formatter = function(param)
			return string.format('%1.f%%', param:get() - 1)
		end,
		action = function(value)
			show_info()
		end
	}
	params:add{
		type = 'number',
		id = 'pitch_in_octave',
		name = 'pitch in octave',
		min = -2,
		max = 2,
		default = 0,
		action = function(value)
			pitch_in_octave = value
		end
	}
	
	params:add_separator()
	
	params:add{
		type = 'number',
		id = 'loop_length',
		name = 'loop length',
		min = 2,
		max = 128,
		default = 16,
		-- TODO: make this adjust loop length with the top voice's current note as the loop end point,
		-- so one could easily lock in the last few notes heard; I don't really get what it's doing now
		action = function(value)
			shift_register:set_length(value)
			update_voices()
			dirty = true
			show_info()
		end
	}
	
	params:add_separator()
	
	for v = 1, n_voices do
		local voice = voices[v]
		-- TODO: maybe some of these things really shouldn't be params?
		params:add{
			type = 'control',
			id = string.format('voice_%d_transpose', v),
			name = string.format('voice %d transpose', v),
			controlspec = controlspec.new(-4, 4, 'lin', 1 / scale.length, 0, 'st'),
			action = function(value)
				voice.transpose = value
				update_voice(v)
				dirty = true
				config_dirty = true
			end
		}
		params:add{
			type = 'control',
			id = string.format('voice_%d_scramble', v),
			name = string.format('voice %d scramble', v),
			controlspec = controlspec.new(0, 16, 'lin', 0.2, 0),
			action = function(value)
				voice.tap.scramble = value
				dirty = true
				config_dirty = true
			end
		}
		params:add{
			type = 'option',
			id = string.format('voice_%d_direction', v),
			name = string.format('voice %d direction', v),
			options = {
				'forward',
				'retrograde'
			},
			action = function(value)
				voice.tap.direction = value == 2 and -1 or 1
				dirty = true
				config_dirty = true
			end
		}
		-- TODO: inversion too? value scaling?
		-- TODO: maybe even different loop lengths... which implies multiple independent SRs
	end

	params:add_separator()

	for v = 1, n_voices do
		local voice = voices[v]
		params:add{
			type = 'control',
			id = string.format('voice_%d_slew', v),
			name = string.format('voice %d slew', v),
			controlspec = controlspec.new(1, 1000, 'exp', 1, 4, 'ms'),
			action = function(value)
				crow.output[v].slew = value / 1000
			end
		}
	end

	params:add_separator()

	for v = 1, n_voices do
		local voice = voices[v]
		params:add{
			type = 'number',
			id = string.format('voice_%d_clock_note', v),
			name = string.format('voice %d clock note', v),
			min = 0,
			max = 127,
			default = 63 + v,
			action = function(value)
				voice.clock_note = value
			end
		}
		params:add{
			type = 'number',
			id = string.format('voice_%d_clock_channel', v),
			name = string.format('voice %d clock channel', v),
			min = 1,
			max = 16,
			default = 1,
			action = function(value)
				voice.clock_channel = value
			end
		}
	end

	params:add_separator()

	params:add{
		type = 'trigger',
		id = 'restore_memory',
		name = 'restore memory',
		action = function()
			-- TODO: allow multiple memory files, using a 'data file' param
			local data_file = norns.state.data .. 'memory.lua'
			if util.file_exists(data_file) then
				local data, errorMessage = tab.load(data_file)
				if errorMessage ~= nil then
					error(errorMessage)
				else
					if data.masks ~= nil then
						saved_masks = data.masks
						mask_dirty = true
					end
					if data.configs ~= nil then
						saved_configs = data.configs
						config_dirty = true
					end
					if data.loops ~= nil then
						saved_loops = data.loops
						shift_register.dirty = true
					end
				end
			end
		end
	}

	params:add{
		type = 'trigger',
		id = 'save_memory',
		name = 'save memory',
		action = function()
			local data_file = norns.state.data .. 'memory.lua'
			local data = {}
			-- TODO: convert saved masks to tables of continuum values:
			-- { 0, 0.13, 0.9 } not { pitch ID = true/false }
			-- this would make switching between microtonal scales less painful
			data.masks = saved_masks
			data.configs = saved_configs
			data.loops = saved_loops
			tab.save(data, data_file)
		end
	}
end

function init()

	-- initialize voices
	for v = 1, n_voices do
		voices[v] = ShiftRegisterVoice.new(v * -3, shift_register, scale)
	end
	top_voice = voices[top_voice_index]

	add_params()
	params:add_separator()
	params:add_group('ENGINE', 19)
	polysub.params()
	-- params:set('detune', 0.17)
	params:set('hzlag', 0.02)
	params:set('cut', 8.32)
	params:set('fgain', 1.26)
	params:set('output_level', -36)

	info_metro = metro.init()
	info_metro.event = function()
		info_visible = false
		dirty = true
	end
	info_metro.count = 1
	
	crow.add = crow_setup -- when crow is connected
	crow_setup() -- calls params:bang()
	
	-- initialize grid controls
	grid_mode = grid_mode_play
	keyboard.get_key_level = key_level_callbacks[grid_mode]
	voice_selector:reset(true)
	update_active_heads()

	redraw_metro = metro.init()
	redraw_metro.event = function(tick)
		-- TODO: stop blinking after n seconds of inactivity?
		if not blink_slow and tick % 8 > 3 then
			blink_slow = true
			dirty = true
		elseif blink_slow and tick % 8 <= 3 then
			blink_slow = false
			dirty = true
		end
		if not blink_fast and tick % 4 > 1 then
			blink_fast = true
			dirty = true
		elseif blink_fast and tick % 4 <= 1 then
			blink_fast = false
			dirty = true
		end
		if dirty then
			grid_redraw()
			redraw()
			dirty = false
		end
	end

	redraw_metro:start(1 / 15)

	pitch_poll = poll.set('pitch_in_l', update_freq)
	pitch_poll.time = 1 / 10 -- was 8, is 10 OK?
	
	for m = 1, 16 do
		saved_masks[m] = {}
		for i = 1, 12 do
			saved_masks[m][i] = false
		end
	end
	for pitch = 1, 12 do
		-- C maj pentatonic
		scale:set_class(pitch, pitch == 2 or pitch == 4 or pitch == 7 or pitch == 9 or pitch == 12)
	end
	mask_selector.selected = 1
	save_mask()

	for t = 1, 16 do
		saved_configs[t] = {}
		for v = 1, n_voices do
			saved_configs[t][v] = 0
		end
	end
	config_selector.selected = 1
	save_config() -- read & save defaults from params

	for l = 1, 16 do
		saved_loops[l] = {}
		for i = 1, 16 do
			saved_loops[l][i] = 24
		end
	end
	for i = 1, 16 do
		saved_loops[1][i] = 24 + i * 3
	end
	loop_selector.selected = 1
	recall_loop()

	params:set('restore_memory')
	recall_mask()
	recall_config()
	recall_loop()

	memory_selector.selected = memory_loop

	pitch_poll:start()
	g.key = grid_key
	m.event = midi_event
	
	update_voices()

	dirty = true
end

function key_shift_clock(n)
	if n == 2 then
		rewind()
	elseif n == 3 then
		advance()
	end
end

function key(n, z)
	if n == 1 then
		key_shift = z == 1
		show_info()
	elseif z == 1 then
		key_shift_clock(n)
	end
	dirty = true
end

function params_multi_delta(param_format, selected, d)
	-- note: this assumes number params with identical range!
	local min = 0
	local max = 0
	local min_value = math.huge
	local max_value = -math.huge
	local selected_params = {}
	for n, is_selected in ipairs(selected) do
		if is_selected then
			local param_name = string.format(param_format, n)
			local param = params:lookup_param(param_name)
			local value = 0
			if param.value ~= nil then
				-- number param
				value = param.value
				min = param.min
				max = param.max
			else
				-- control param
				value = param:get()
				min = param.controlspec.minval
				max = param.controlspec.maxval
			end
			table.insert(selected_params, param)
			min_value = math.min(min_value, value)
			max_value = math.max(max_value, value)
		end
	end
	-- TODO: getting errors that seem to suggest this is happening -- why??
	if selected_params[1] == nil then
		print('params_multi_delta fail: %s (selected follows)', param_format)
		tab.print(selected)
		return
	end
	if d > 0 then
		d = math.min(d,	max - max_value)
	elseif d < 0 then
		d = math.max(d, min - min_value)
	end
	for i, param in ipairs(selected_params) do
		param:delta(d)
	end
end

function enc(n, d)
	if n == 1 then
		if key_shift then
			params:delta('loop_length', d)
		else
			params:delta('write_probability', d)
		end
	elseif n == 2 then
		-- shift voices
		-- TODO: somehow do this more slowly / make it less sensitive?
		for v = 1, n_voices do
			if voice_selector:is_selected(v) then
				voices[v]:shift(-d)
				update_voice(v)
			end
		end
		config_dirty = true
		dirty = true
	elseif n == 3 then
		if key_shift then
			-- change voice randomness
			params_multi_delta('voice_%d_scramble', voice_selector.selected, d)
		else
			-- transpose voice(s)
			params_multi_delta('voice_%d_transpose', voice_selector.selected, d);
		end
	end
	dirty = true
end

function get_screen_offset_x(offset)
	return screen_note_width * (screen_note_center + offset)
end

function get_screen_note_y(value)
	if value == null then
		return -1
	end
	return util.round(32 + (keyboard.octave - value) * scale.length)
end

-- calculate coordinates for each visible note
function calculate_voice_path(v)
	local voice = voices[v]
	local path = voice:get_path(-screen_note_center, n_screen_notes - screen_note_center)
	screen_notes[v] = {}
	for n = 1, n_screen_notes do
		local note = {}
		note.x = (n - 1) * screen_note_width
		note.y = get_screen_note_y(scale:snap(path[n].value))
		note.offset = path[n].offset
		note.pos = path[n].pos
		screen_notes[v][n] = note
	end
end

function draw_voice_path(v, level)
	local voice = voices[v]

	calculate_voice_path(v) -- TODO: don't do this every time, only when it changes

	screen.line_cap('square')

	-- draw background/outline
	screen.line_width(3)
	screen.level(0)
	for n = 1, n_screen_notes do
		local note = screen_notes[v][n]
		local x = note.x + 0.5
		local y = note.y + 0.5
		-- TODO: account for 'z' (gate): when current or prev z is low, don't draw connecting line
		-- move or connect from previous note
		if n == 1 then
			screen.move(x, y)
		else
			screen.line(x, y)
		end
		-- draw this note
		screen.line(x + screen_note_width, y)
	end
	screen.stroke()

	-- draw foreground/path
	local note_level = level
	screen.line_width(1)
	for n = 1, n_screen_notes do
		local note = screen_notes[v][n]
		local x = note.x + 0.5
		local y = note.y + 0.5
		-- if this note was just written, brighten it and the connecting line from the previous note
		local previous_note_level = note_level
		local connector_level = level
		note_level = level
		for w = 1, n_recent_writes do
			local write = recent_writes[w]
			if write ~= nil and write.level > 0 then
				if shift_register:clamp_loop_pos(note.pos) == shift_register:clamp_loop_pos(write.pos) then
					note_level = math.max(note_level, write.level)
				end
			end
		end
		if note_level > previous_note_level then
			connector_level = util.round((note_level + previous_note_level) / 2)
		end
		-- TODO: account for 'z' (gate): when current or prev z is low, don't draw connecting line; and when current z is low, draw current note as dots
		-- move or connect from previous note
		if n == 1 then
			screen.move(x, y)
		else
			screen.line(x, y)
		end
		screen.level(connector_level)
		screen.stroke()
		-- draw this note
		screen.move(x, y)
		screen.line(x + screen_note_width, y)
		screen.level(note_level)
		screen.stroke()
		screen.move(x + screen_note_width, y)
	end
	screen.stroke()

	screen.line_cap('butt')
end

function redraw()
	screen.clear()
	screen.stroke()
	screen.line_width(1)
	screen.font_face(2)
	screen.font_size(8)

	-- draw vertical output indicator
	local output_x = get_screen_offset_x(-1) + 3
	screen.move(output_x, 0)
	screen.line(output_x, 64)
	screen.level(1)
	screen.stroke()

	-- draw paths
	for i, v in ipairs(voice_draw_order) do
		local level = 1
		if v == top_voice_index then
			level = 15
		elseif voice_selector:is_selected(v) then
			level = 4
		end
		draw_voice_path(v, level)
	end

	-- highlight current notes after drawing all snakes, lest some be covered by outlines
	-- TODO: draw these based on voice.value in case that somehow ends up being different from what's shown on the screen??
	-- (but it shouldn't, ever)
	for i, v in ipairs(voice_draw_order) do
		local note = screen_notes[v][screen_note_center]
		screen.pixel(note.x + 2, note.y)
		screen.level(15)
		screen.fill()
	end

	-- draw input indicators
	-- TODO: when top voice is retrograde, this looks odd. not sure how to make it easier to follow.
	for w = 1, n_recent_writes do
		local write = recent_writes[w]
		if write ~= nil and write.level > 0 then
			write.level = math.floor(write.level * 0.7)
		end
	end

	if info_visible then
		screen.rect(0, 0, 26, 64)
		screen.level(0)
		screen.fill()
		screen.move(24.5, 0)
		screen.line(24.5, 64)
		screen.level(4)
		screen.stroke()

		screen.level(15)

		screen.move(0, 7)
		screen.text(string.format('P: %d%%', util.round(params:get('write_probability') - 1)))

		screen.move(0, 16)
		screen.text(string.format('L: %d', shift_register.length))

		screen.move(0, 25)
		screen.text(string.format('O: %d', top_voice.pos))

		screen.move(0, 34)
		screen.text(string.format('T: %.2f', top_voice.transpose))

		screen.move(0, 43)
		screen.text(string.format('S: %.1f', top_voice.tap.scramble))

		screen.level(top_voice.tap.direction == -1 and 15 or 2)
		screen.move(0, 52)
		screen.text('Ret.')
	end

	-- DEBUG: draw minibuffer, loop region, head
	--[[
	screen.move(0, 1)
	screen.line_rel(shift_register.buffer_size, 0)
	screen.level(1)
	screen.stroke()
	for offset = 1, shift_register.length do
		local pos = shift_register:get_loop_pos(offset)
		screen.pixel(pos - 1, 0)
		screen.level(7)
		if pos == shift_register.head then
			screen.level(15)
		end
		for v = 1, n_voices do
			-- TODO: make it so that these _never_ move when you change loop length. no, not sure how.
			-- currently they _sometimes_ stay in place. probably has something to do with modulo'ing to LCM
			if voice_selector:is_selected(v) and pos == shift_register:get_loop_pos(voices[v]:get_pos(0)) then
				screen.level(15)
			end
		end
		screen.fill()
	end
	--]]

	screen.update()
end

function cleanup()
	if pitch_poll ~= nil then
		pitch_poll:stop()
	end
	if redraw_metro ~= nil then
		redraw_metro:stop()
	end
end
