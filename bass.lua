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

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

local SUBDIVISIONS = { 1/8, 1/6, 1/4, 1/3, 1/2, 1, 2 }
local SUB_NAMES    = { "1/32","1/24","1/16","1/12","1/8","1/4","1/2" }

-- -------------------------
-- STATE
-- -------------------------

local g = grid.connect()

local state = {
  playing     = false,
  root        = 0,       -- semitone 0-11 (C)
  scale_idx   = 1,
  octave      = 2,       -- base octave offset (0-4, displayed as 1-5)
  sub_idx     = 3,       -- index into SUBDIVISIONS
  bpm         = 120,
  volume      = 0.7,
  note_len    = 0.1,     -- note gate length in seconds

  -- sequence: 16 steps, each can hold a note or nil
  steps       = {},
  step_pos    = 1,       -- current playback position

  -- currently held pads (for live note tracking)
  held        = {},      -- {col, row} -> midi note

  -- last triggered note (for display)
  last_note   = nil,
}

-- init steps
for i = 1, GRID_W do state.steps[i] = nil end

-- -------------------------
-- MUSIC UTILS
-- -------------------------

local function scale_note(degree, octave)
  -- degree: 0-based index into scale intervals
  local sc = SCALES[state.scale_idx].intervals
  local len = #sc
  local oct_offset = math.floor(degree / len)
  local interval = sc[(degree % len) + 1]
  local midi = 24 + state.root + (octave + oct_offset) * 12 + interval
  return math.max(0, math.min(127, midi))
end

local function midi_to_hz(midi)
  return 440 * 2^((midi - 69) / 12)
end

-- -------------------------
-- GRID RENDERING
-- -------------------------

local function grid_redraw()
  if not g then return end
  g:all(0)

  local sc = SCALES[state.scale_idx].intervals
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
  local hz = midi_to_hz(midi)
  engine.hz(hz)
  engine.amp(state.volume)
  engine.release(state.note_len)
  state.last_note = midi
  redraw()
end

local function clock_tick ()
  while true do
    clock.sync(SUBDIVISIONS[state.sub_idx])
    if state.playing then
      local note = state.steps[state.step_pos]
      if note then
        play_note(note)
      end
      state.step_pos = (state.step_pos % GRID_W) + 1
      grid_redraw()
    end
  end
end

-- -------------------------
-- GRID INPUT
-- -------------------------

g.key = function(col, row, z)
  if z == 1 then
    -- rows 16: note pads
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

    -- row 7: root note
    elseif row == 7 and col <= 12 then
      state.root = col - 1
      -- retune held notes
      grid_redraw()
      redraw()

    -- row 8: controls
    elseif row == 8 then
      if col <= #SCALES then
        state.scale_idx = col
      elseif col >= 9 and col <= 12 then
        state.octave = col - 8
      elseif col == 14 then
        state.sub_idx = (state.sub_idx % #SUBDIVISIONS) + 1
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
-- NORNS UI
-- -------------------------

function redraw()
  screen.clear()
  screen.aa(1)

  -- title
  screen.level(15)
  screen.font_size(8)
  screen.move(0, 8)
  screen.text("BASS")

  -- status
  screen.level(state.playing and 15 or 5)
  screen.move(30, 8)
  screen.text(state.playing and "PLAY" or "STOP")

  -- BPM
  screen.level(10)
  screen.move(0, 22)
  screen.text("BPM  " .. math.floor(state.bpm))

  -- subdivision
  screen.move(0, 32)
  screen.text("DIV  " .. SUB_NAMES[state.sub_idx])

  -- scale
  local sc_name = SCALES[state.scale_idx].name
  screen.move(0, 42)
  screen.text("SCL  " .. sc_name)

  -- root + octave
  screen.move(0, 52)
  screen.text("ROOT " .. NOTE_NAMES[state.root + 1] .. "  OCT " .. state.octave)

  -- last note
  if state.last_note then
    screen.level(15)
    screen.move(0, 62)
    screen.text("NOTE " .. NOTE_NAMES[(state.last_note % 12) + 1]
      .. math.floor(state.last_note / 12 - 1))
  end

  -- step dots
  for i = 1, GRID_W do
    local x = 80 + (i - 1) * 3
    local has_note = state.steps[i] ~= nil
    local is_pos = (i == state.step_pos)
    screen.level(is_pos and 15 or (has_note and 8 or 2))
    screen.rect(x, 56, 2, has_note and 6 or 2)
    screen.fill()
  end

  screen.update()
end

-- -------------------------
-- ENCODERS & KEYS
-- -------------------------

function enc(n, d)
  if n == 1 then
    state.bpm = util.clamp(state.bpm + d, 20, 300)
    clock.tempo = state.bpm
  elseif n == 2 then
    state.sub_idx = util.clamp(state.sub_idx + d, 1, #SUBDIVISIONS)
  elseif n == 3 then
    state.volume = util.clamp(state.volume + d * 0.02, 0, 1)
    engine.amp(state.volume)
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
      for i = 1, GRID_W do state.steps[i] = nil end
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

  -- start clock coroutine
  clock.run(clock_tick)

  grid_redraw()
  redraw()
end
