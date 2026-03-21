-- bass.lua
-- scale-locked, clock-locked grid bass instrument
--
-- grid layout:
--   rows 1-6  : note pads (columns = scale degrees, rows = octaves)
--   row 7     : root note selector (cols 1-12)
--   row 8     : scale selector (cols 1-8) + octave offset (cols 9-10) + clear (col 16)
--
-- encoders:
--   E1 : tempo (BPM)
--   E2 : note length (subdivision)
--   E3 : volume
--
-- keys:
--   K2 : toggle play/stop
--   K3 : clear sequence
--   K1+K3 : mutate pattern (drunk walk)

engine.name = "PolyPerc"

-- -------------------------
-- CONFIG
-- -------------------------

local GRID_W = 16
local GRID_H = 8

local SCALES = {
  { name = "major",      intervals = {0,2,4,5,7,9,11} },
  { name = "minor",      intervals = {0,2,3,5,7,8,10} },
  { name = "dorian",     intervals = {0,2,3,5,7,9,10} },
  { name = "phrygian",   intervals = {0,1,3,5,7,8,10} },
  { name = "lydian",     intervals = {0,2,4,6,7,9,11} },
  { name = "mixolydian", intervals = {0,2,4,5,7,9,10} },
  { name = "locrian",    intervals = {0,1,3,5,6,8,10} },
  { name = "pentatonic", intervals = {0,2,4,7,9} },
}

local BASS_SCALES = {
  { name = "chromatic",   intervals = {0,1,2,3,4,5,6,7,8,9,10,11} },
  { name = "blues",       intervals = {0,3,5,6,7,10} },
  { name = "minor_pent",  intervals = {0,3,5,7,10} },
  { name = "dorian",      intervals = {0,2,3,5,7,9,10} },
  { name = "mixolydian",  intervals = {0,2,4,5,7,9,10} },
  { name = "major",       intervals = {0,2,4,5,7,9,11} },
}

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

local SUBDIVISIONS = { 1/8, 1/6, 1/4, 1/3, 1/2, 1, 2 }
local SUB_NAMES    = { "1/32","1/24","1/16","1/12","1/8","1/4","1/2" }

local QUANTIZE_OPTS = { "free", "1/4", "1/8", "1/16", "1/32" }

-- Screen zones
local SCREEN_W = 128
local SCREEN_H = 64

-- -------------------------
-- STATE
-- -------------------------

local g = grid.connect()
local m = nil

local state = {
  playing     = false,
  root        = 0,       -- semitone 0-11 (C)
  scale_idx   = 1,
  octave      = 2,       -- base octave offset (0-4, displayed as 1-5)
  sub_idx     = 3,       -- index into SUBDIVISIONS
  bpm         = 120,
  volume      = 0.7,
  note_len    = 0.1,     -- note gate length in seconds
  swing       = 0,       -- swing amount (0-100)
  auto_mutate = false,   -- auto mutation on/off
  auto_mutate_bars = 4,  -- mutate every N bars
  midi_transpose_active = false,
  midi_transpose_note = nil,

  -- sequence: 16 steps, each can hold a note or nil
  steps       = {},
  step_pos    = 1,       -- current playback position
  bar_count   = 0,

  -- currently held pads (for live note tracking)
  held        = {},      -- {col, row} -> midi note

  -- last triggered note (for display)
  last_note   = nil,
  last_held_note = nil,  -- for legato mode

  -- screen rendering state
  beat_phase  = 0,       -- phase of beat pulse (0-1)
  popup_param = nil,     -- current parameter name in popup
  popup_val   = nil,     -- current parameter value
  popup_time  = 0,       -- time remaining for popup display
  screen_clock = 0,      -- clock for screen refresh

  -- legato mode
  legato      = false,   -- when true, don't send note_off between notes

  -- quantize mode
  quantize_idx = 1,      -- index into QUANTIZE_OPTS (1 = "free")

  -- bass scale selector
  bass_scale_idx = 1,    -- index into BASS_SCALES

  -- pattern recording
  recording   = false,   -- currently recording pattern
  record_buffer = {},    -- table of {note, time_offset}
  record_start_time = nil,
  pattern_loop_id = nil, -- clock ID for pattern loop playback
}

-- init steps
for i = 1, GRID_W do state.steps[i] = nil end

-- Clock IDs for cleanup
local clock_tick_id = nil
local screen_clock_id = nil

-- OP-XY MIDI
local opxy_out = nil
local opxy_enabled = false
local opxy_device = 1
local opxy_channel = 2  -- OP-XY bass channel

local function opxy_note_on(note, vel)
  if opxy_out and opxy_enabled then
    opxy_out:note_on(note, vel, opxy_channel)
  end
end

local function opxy_note_off(note)
  if opxy_out and opxy_enabled then
    opxy_out:note_off(note, 0, opxy_channel)
  end
end

local function opxy_cc(cc_num, val)
  if opxy_out and opxy_enabled then
    opxy_out:cc(cc_num, math.floor(util.clamp(val, 0, 127)), opxy_channel)
  end
end

local function opxy_all_notes_off()
  if opxy_out and opxy_enabled then
    opxy_out:cc(123, 0, opxy_channel)
  end
end

-- -------------------------
-- MUSIC UTILS
-- -------------------------

local function get_active_scale()
  -- returns the active scale: BASS_SCALES if bass_scale_idx is set, else SCALES
  if state.bass_scale_idx and state.bass_scale_idx > 0 then
    return BASS_SCALES[state.bass_scale_idx]
  end
  return SCALES[state.scale_idx]
end

local function scale_note(degree, octave)
  -- degree: 0-based index into scale intervals
  local sc = get_active_scale().intervals
  local len = #sc
  local oct_offset = math.floor(degree / len)
  local interval = sc[(degree % len) + 1]
  local midi = 24 + state.root + (octave + oct_offset) * 12 + interval
  return math.max(0, math.min(127, midi))
end

local function midi_to_hz(midi)
  return 440 * 2^((midi - 69) / 12)
end

local function apply_quantize()
  -- snap current clock position to nearest quantize subdivision
  if QUANTIZE_OPTS[state.quantize_idx] == "free" then
    return  -- no quantization
  end

  local quant_val = tonumber(QUANTIZE_OPTS[state.quantize_idx]:match("1/(%d+)"))
  if quant_val then
    local quant_beat = 4 / quant_val  -- convert to beat fractions
    clock.sync(quant_beat)
  end
end

-- -------------------------
-- SWING & MUTATION SYSTEM
-- -------------------------

local find_scale_degree  -- forward declaration (defined below)

local function mutate_pattern()
  -- Drunk walk: randomly shift 1-3 notes by ±1 scale degree
  local num_mutations = math.random(1, 3)
  local sc = get_active_scale().intervals
  local num_degrees = #sc

  for _ = 1, num_mutations do
    local step = math.random(1, GRID_W)
    if state.steps[step] ~= nil then
      local degree_idx = find_scale_degree(state.steps[step])
      if degree_idx then
        local direction = math.random() < 0.5 and 1 or -1
        local new_degree = degree_idx + direction
        if new_degree >= 0 and new_degree < num_degrees then
          local root_midi = 24 + state.root
          local note_relative_to_root = state.steps[step] - root_midi
          local octave = math.floor(note_relative_to_root / 12)
          state.steps[step] = scale_note(new_degree, octave)
        end
      end
    end
  end
end

find_scale_degree = function(midi)
  local sc = get_active_scale().intervals
  local root_midi = 24 + state.root
  local note_relative_to_root = midi - root_midi
  local note_in_octave = note_relative_to_root % 12
  if note_in_octave < 0 then note_in_octave = note_in_octave + 12 end
  
  for i, interval in ipairs(sc) do
    if interval == note_in_octave then
      return i - 1
    end
  end
  return nil  -- fallback: no matching scale degree found
end

-- -------------------------
-- GRID RENDERING
-- -------------------------

local function grid_redraw()
  if not g then return end
  g:all(0)

  local sc = get_active_scale().intervals
  local num_degrees = #sc

  -- rows 1-6: note pads
  -- col maps to scale degree (wrapping), row maps to octave
  -- row 1 = highest octave shown, row 6 = lowest
  for row = 1, 6 do
    local oct = state.octave + (6 - row)  -- row 1 = highest
    for col = 1, GRID_W do
      local degree = col - 1
      local midi = scale_note(degree, oct - state.octave)
      -- check if this is a held note
      local bright = 4
      for _, v in pairs(state.held) do
        if v == scale_note(degree, oct - state.octave) then bright = 15 end
      end
      -- highlight root notes (interval == 0)
      if sc[((degree % num_degrees)) + 1] == 0 then
        bright = (bright == 15) and 15 or 6
      end
      g:led(col, row, bright)
    end
  end

  -- row 7: root note selector
  for col = 1, 12 do
    local bright = (col - 1 == state.root) and 15 or 3
    g:led(col, 7, bright)
  end

  -- row 8: scale selector (cols 1-8)
  for col = 1, #SCALES do
    local bright = (col == state.scale_idx) and 15 or 3
    g:led(col, 8, bright)
  end

  -- row 8: octave select (cols 9-12 = octave 1-4)
  for i = 1, 4 do
    local bright = (i == state.octave) and 15 or 3
    g:led(8 + i, 8, bright)
  end

  -- row 8 col 14: subdivision
  g:led(14, 8, 8)

  -- row 8 col 15: blink if playing
  if state.playing then
    g:led(15, 8, state.step_pos % 2 == 0 and 15 or 5)
  else
    g:led(15, 8, 3)
  end

  -- row 8 col 16: clear
  g:led(16, 8, 3)

  g:refresh()
end

-- -------------------------
-- PLAYBACK
-- -------------------------

local function play_note(midi)
  if midi == nil then return end

  -- Handle legato: send note_off only if legato is off
  if not state.legato and state.last_held_note ~= nil and state.last_held_note ~= midi then
    engine.hz(0)  -- silent stop for synthesis engine
  end

  local hz = midi_to_hz(midi)
  engine.hz(hz)
  engine.amp(state.volume)
  engine.release(state.note_len)
  state.last_note = midi
  state.last_held_note = midi
  opxy_note_on(midi, 80)
  redraw()
end

local function clock_tick()
  while true do
    clock.sync(SUBDIVISIONS[state.sub_idx])
    if state.playing then
      -- Apply quantize if enabled
      apply_quantize()

      local note = state.steps[state.step_pos]

      -- Apply MIDI input transposition
      if state.midi_transpose_active and state.midi_transpose_note then
        local transposition = state.midi_transpose_note - state.root
        if note then
          note = note + transposition
        end
      end

      if note then
        play_note(note)
      end

      -- Send cutoff CC to OP-XY (key parameter for bass)
      opxy_cc(32, util.linlin(24, 60, 40, 120, state.last_note or 36))

      -- Apply swing delay for even-numbered steps
      local swing_delay = 0
      if state.swing > 0 and state.step_pos % 2 == 0 then
        local beat_duration = clock.get_beat_sec()
        swing_delay = (state.swing / 100) * 0.5 * beat_duration
      end

      if swing_delay > 0 then
        clock.sleep(swing_delay)
      end

      -- Track bars for auto-mutation
      if state.step_pos == GRID_W then
        state.bar_count = state.bar_count + 1
        if state.auto_mutate and state.bar_count % state.auto_mutate_bars == 0 then
          mutate_pattern()
        end
      end

      state.step_pos = (state.step_pos % GRID_W) + 1
      state.beat_phase = 0  -- reset beat phase on downbeat
      grid_redraw()
    end
  end
end

-- -------------------------
-- MIDI INPUT
-- -------------------------

local function init_midi()
  m = midi.connect(1)
  if m then
    m.event = function(data)
      local msg = midi.to_msg(data)
      if msg.type == "note_on" and msg.vel > 0 then
        -- Transpose to held MIDI note
        state.midi_transpose_active = true
        state.midi_transpose_note = msg.note % 12  -- Get semitone class
        redraw()
      elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
        -- Release transposition
        state.midi_transpose_active = false
        state.midi_transpose_note = nil
        redraw()
      end
    end
  end
end

-- -------------------------
-- PATTERN RECORDING
-- -------------------------

local function start_pattern_record()
  state.recording = true
  state.record_buffer = {}
  state.record_start_time = clock.get_beat_sec()
end

local function stop_and_loop_pattern()
  state.recording = false

  -- Cancel any existing pattern loop
  if state.pattern_loop_id then
    clock.cancel(state.pattern_loop_id)
  end

  if #state.record_buffer == 0 then return end

  -- Start looping recorded pattern
  state.pattern_loop_id = clock.run(function()
    while true do
      for _, note_event in ipairs(state.record_buffer) do
        local note = note_event.note
        local delay = note_event.time_offset
        clock.sleep(delay)
        play_note(note)
      end
    end
  end)
end

-- -------------------------
-- GRID INPUT
-- -------------------------

g.key = function(col, row, z)
  if z == 1 then
    -- rows 1-6: note pads
    if row <= 6 then
      local degree = col - 1
      local oct_offset = (6 - row)
      local midi = scale_note(degree, oct_offset)
      state.held[col * 10 + row] = midi
      -- record into current step if playing, else just play
      play_note(midi)
      if state.playing then
        state.steps[state.step_pos] = midi
      end

      -- Record into pattern buffer if recording
      if state.recording then
        local time_offset = clock.get_beat_sec() - state.record_start_time
        table.insert(state.record_buffer, {note = midi, time_offset = time_offset})
      end

    -- row 7: root note
    elseif row == 7 and col <= 12 then
      state.root = col - 1
      -- retune held notes
      grid_redraw()
      redraw()

    -- row 8: controls
    elseif row == 8 then
      if col <= #BASS_SCALES then
        -- Use bass scales for bass-specific control
        state.bass_scale_idx = col
      elseif col >= 9 and col <= 12 then
        state.octave = col - 8
      elseif col == 13 then
        -- Toggle legato mode
        state.legato = not state.legato
      elseif col == 14 then
        -- Quantize mode (rotate through options)
        state.quantize_idx = (state.quantize_idx % #QUANTIZE_OPTS) + 1
      elseif col == 15 then
        state.playing = not state.playing
        if state.playing then state.step_pos = 1 end
      elseif col == 16 then
        for i = 1, GRID_W do state.steps[i] = nil end
      end
      grid_redraw()
      redraw()
    end

  else -- key up
    state.held[col * 10 + row] = nil
    grid_redraw()
  end
end

-- -------------------------
-- SCREEN RENDERING
-- -------------------------

local function draw_status_strip()
  -- y 0-8: STATUS STRIP
  screen.level(4)
  screen.font_size(8)
  screen.move(0, 7)
  local status_text = "BASS"
  if state.recording then
    status_text = status_text .. " [REC]"
  end
  if state.legato then
    status_text = status_text .. " LEG"
  end
  screen.text(status_text)

  -- Current scale name at center (level 6)
  screen.level(6)
  local scale_name = get_active_scale().name
  screen.move(SCREEN_W / 2 - 20, 7)
  screen.text(scale_name)

  -- Quantize mode indicator
  screen.level(5)
  screen.font_size(7)
  screen.move(SCREEN_W - 35, 7)
  screen.text("Q:" .. QUANTIZE_OPTS[state.quantize_idx])

  -- Beat pulse dot at x=124 (right side)
  -- Flashes level 15 on downbeat, decays via sine to level 2
  local pulse_brightness = 2
  if state.beat_phase < 0.3 then
    -- Fast decay from 15 to 2 over first 30% of beat
    local decay = 1 - (state.beat_phase / 0.3)
    pulse_brightness = 2 + (15 - 2) * decay * decay
  end
  screen.level(math.floor(pulse_brightness))
  screen.rect(124, 2, 3, 3)
  screen.fill()
end

local function draw_live_zone()
  -- y 9-52: LIVE ZONE (16-step grid sequencer)
  local zone_top = 9
  local zone_height = 44
  local zone_bottom = zone_top + zone_height

  local step_width = SCREEN_W / GRID_W
  local sc = get_active_scale().intervals
  local num_degrees = #sc

  for step = 1, GRID_W do
    local x = (step - 1) * step_width
    local note = state.steps[step]

    -- Playhead: full-height thin line at level 15 with level 3 background
    if step == state.step_pos then
      screen.level(3)
      screen.rect(x, zone_top, step_width, zone_height)
      screen.fill()
    end

    -- Draw step indicator
    if note then
      -- Calculate pitch height (higher note = higher position)
      local degree = find_scale_degree(note)
      if degree then
        local pitch_height = (degree / num_degrees) * zone_height
        local bar_y = zone_bottom - pitch_height

        -- Active steps at level 12
        screen.level(12)
        screen.rect(x + 1, bar_y, step_width - 2, pitch_height)
        screen.fill()
      end
    else
      -- Empty steps: small dot at baseline at level 3
      screen.level(3)
      screen.rect(x + step_width / 2 - 1, zone_bottom - 2, 2, 2)
      screen.fill()
    end

    -- Playhead thin line overlay at level 15
    if step == state.step_pos then
      screen.level(15)
      screen.rect(x, zone_top, 1, zone_height)
      screen.fill()
    end
  end
end

local function draw_context_bar()
  -- y 53-58: CONTEXT BAR
  screen.level(8)
  screen.font_size(8)
  screen.move(0, 62)
  local scale_name = get_active_scale().name
  screen.text(NOTE_NAMES[state.root + 1] .. " " .. scale_name)

  -- BPM at center
  screen.level(6)
  screen.move(SCREEN_W / 2 - 10, 62)
  screen.text(math.floor(state.bpm) .. " BPM")

  -- Octave range at right
  screen.level(5)
  screen.move(SCREEN_W - 30, 62)
  screen.text("Oct " .. state.octave)

  -- MIDI channel at far right
  screen.level(4)
  screen.move(SCREEN_W - 15, 62)
  screen.text("Ch 1")
end

local function draw_parameter_popup()
  -- TRANSIENT PARAMETER POPUP: param name + value at level 15 with dark bg
  if state.popup_param and state.popup_time > 0 then
    local popup_text = state.popup_param .. ": " .. tostring(state.popup_val)

    -- Dark background rect
    screen.level(0)
    screen.rect(20, 25, 90, 15)
    screen.fill()

    -- Text
    screen.level(15)
    screen.font_size(8)
    screen.move(25, 35)
    screen.text(popup_text)
  end
end

function redraw()
  screen.clear()
  screen.aa(1)

  draw_status_strip()
  draw_live_zone()
  draw_context_bar()
  draw_parameter_popup()

  screen.update()
end

-- -------------------------
-- SCREEN CLOCK
-- -------------------------

local function screen_clock()
  while true do
    clock.sleep(0.1)  -- ~10 fps
    state.beat_phase = (state.beat_phase + 0.1) % 1.0
    if state.popup_time > 0 then
      state.popup_time = state.popup_time - 0.1
    end
    redraw()
  end
end

-- -------------------------
-- ENCODERS & KEYS
-- -------------------------

function enc(n, d)
  if n == 1 then
    state.bpm = util.clamp(state.bpm + d, 20, 300)
    clock.tempo = state.bpm
    state.popup_param = "BPM"
    state.popup_val = math.floor(state.bpm)
    state.popup_time = 0.8
  elseif n == 2 then
    state.sub_idx = util.clamp(state.sub_idx + d, 1, #SUBDIVISIONS)
    state.popup_param = "Subdivision"
    state.popup_val = SUB_NAMES[state.sub_idx]
    state.popup_time = 0.8
  elseif n == 3 then
    state.volume = util.clamp(state.volume + d * 0.02, 0, 1)
    engine.amp(state.volume)
    state.popup_param = "Volume"
    state.popup_val = math.floor(state.volume * 100) .. "%"
    state.popup_time = 0.8
  end
  grid_redraw()
  redraw()
end

function key(n, z)
  if z == 1 then
    if n == 2 then
      state.playing = not state.playing
      if state.playing then state.step_pos = 1 end
    elseif n == 3 then
      -- K3: toggle pattern record/loop
      if state.recording then
        stop_and_loop_pattern()
      else
        start_pattern_record()
      end
    end
    grid_redraw()
    redraw()
  end
end

-- -------------------------
-- INIT
-- -------------------------

function init()
  -- engine params
  engine.cutoff(4000)
  engine.gain(2.0)
  engine.amp(state.volume)
  engine.release(0.18)
  engine.pw(0.5)

  -- set initial clock
  params:set("clock_tempo", state.bpm)

  -- init MIDI input
  init_midi()

  -- OP-XY MIDI setup
  params:add_group("OP-XY", 3)
  params:add_option("opxy_enabled", "OP-XY output", {"off", "on"}, 1)
  params:set_action("opxy_enabled", function(x)
    opxy_enabled = (x == 2)
    if opxy_out == nil then
      opxy_out = midi.connect(params:get("opxy_device"))
    end
  end)
  params:add_number("opxy_device", "OP-XY MIDI device", 1, 4, 1)
  params:set_action("opxy_device", function(val)
    opxy_out = midi.connect(val)
  end)
  params:add_number("opxy_channel", "OP-XY channel", 1, 8, 2)
  params:set_action("opxy_channel", function(x) opxy_channel = x end)

  -- start clock coroutines and store IDs
  clock_tick_id = clock.run(clock_tick)
  screen_clock_id = clock.run(screen_clock)

  grid_redraw()
  redraw()
end

function cleanup()
  -- Cancel all clock runs
  if clock_tick_id then clock.cancel(clock_tick_id) end
  if screen_clock_id then clock.cancel(screen_clock_id) end
  if state.pattern_loop_id then clock.cancel(state.pattern_loop_id) end

  opxy_all_notes_off()
  if g then g:all(0); g:refresh() end
  if m then
    for ch = 1, 16 do
      m:cc(123, 0, ch)
      m:cc(120, 0, ch)
    end
  end
end
