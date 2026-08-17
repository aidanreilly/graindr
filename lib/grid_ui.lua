-- lib/grid_ui.lua

local GridUI = {}
GridUI.__index = GridUI

function GridUI.new()
  local gui = setmetatable({}, GridUI)
  gui.mutes = {}
  gui.head_active = {}
  gui.head_pos = {}
  gui.alt_held = false

  gui.patterns = {}
  for i = 1, 7 do
    gui.mutes[i] = false
    gui.head_active[i] = false
    gui.head_pos[i] = -1
    gui.patterns[i] = {
      armed = false,
      playing = false,
      events = {},
      metro = nil,
      rec_start = 0,
      play_idx = 0,
      length = 0
    }
  end

  gui.on_head_start = function(head, position) end
  gui.on_head_reposition = function(head, position) end
  gui.on_head_stop = function(head) end
  gui.on_mute_toggle = function(head, state) end

  return gui
end

function GridUI:key(x, y, z)
  if y == 1 then
    self:handle_control_row(x, z)
  elseif y >= 2 and y <= 8 and z == 1 then
    local head = y - 1
    if not self.mutes[head] then
      local position = (x - 1) / 15

      if self.head_active[head] then
        self.on_head_reposition(head, position)
      else
        self.head_active[head] = true
        self.on_head_start(head, position)
      end

      self.head_pos[head] = position

      if self.patterns[head].armed then
        local t = util.time() - self.patterns[head].rec_start
        table.insert(self.patterns[head].events, { t = t, x = x })
      end
    end
  end
end

function GridUI:handle_control_row(x, z)
  if z == 0 then
    if x == 16 then self.alt_held = false end
    return
  end

  if x == 16 then
    self.alt_held = true
    return
  end

  if x >= 1 and x <= 7 then
    local head = x
    self.mutes[head] = not self.mutes[head]
    self.on_mute_toggle(head, self.mutes[head])
    if self.mutes[head] then
      self.head_active[head] = false
      self.on_head_stop(head)
    end
    return
  end

  if x >= 9 and x <= 15 then
    local head = x - 8
    local pat = self.patterns[head]

    if self.alt_held then
      self:pattern_stop(head)
      pat.events = {}
      pat.length = 0
      return
    end

    if pat.armed then
      pat.armed = false
      pat.length = util.time() - pat.rec_start
      if #pat.events > 0 then
        self:pattern_play(head)
      end
    elseif pat.playing then
      self:pattern_stop(head)
    elseif #pat.events > 0 then
      self:pattern_play(head)
    else
      pat.armed = true
      pat.events = {}
      pat.rec_start = util.time()
    end
  end
end

function GridUI:pattern_play(head)
  local pat = self.patterns[head]
  if #pat.events == 0 then return end

  pat.playing = true
  pat.play_idx = 1

  if pat.metro then
    metro.free(pat.metro.id)
  end

  pat.metro = metro.init()
  pat.metro.time = math.max(pat.events[1].t, 0.001)
  pat.metro.event = function()
    if not pat.playing then return end
    local evt = pat.events[pat.play_idx]
    if evt and not self.mutes[head] then
      local position = (evt.x - 1) / 15
      if self.head_active[head] then
        self.on_head_reposition(head, position)
      else
        self.head_active[head] = true
        self.on_head_start(head, position)
      end
      self.head_pos[head] = position
    end

    pat.play_idx = pat.play_idx + 1
    if pat.play_idx > #pat.events then
      local remaining = pat.length - pat.events[#pat.events].t
      pat.metro.time = math.max(remaining, 0.01)
      pat.play_idx = 1
    else
      local next_t = pat.events[pat.play_idx].t - pat.events[pat.play_idx - 1].t
      pat.metro.time = math.max(next_t, 0.001)
    end
  end
  pat.metro:start()
end

function GridUI:pattern_stop(head)
  local pat = self.patterns[head]
  pat.playing = false
  pat.armed = false
  if pat.metro then pat.metro:stop() end
end

function GridUI:set_head_pos(head, pos)
  if head >= 1 and head <= 7 then
    self.head_pos[head] = pos
  end
end

function GridUI:set_head_active(head, active)
  if head >= 1 and head <= 7 then
    self.head_active[head] = active
  end
end

function GridUI:is_muted(head)
  return self.mutes[head] or false
end

function GridUI:stop_all()
  for i = 1, 7 do
    self.head_active[i] = false
    self:pattern_stop(i)
  end
end

function GridUI:refresh(g)
  if g == nil then return end

  g:all(0)

  for i = 1, 7 do
    g:led(i, 1, self.mutes[i] and 4 or 15)
  end

  for i = 1, 7 do
    local pat = self.patterns[i]
    local level = 0
    if pat.armed then
      level = (math.floor(util.time() * 4) % 2 == 0) and 12 or 0
    elseif pat.playing then
      level = 15
    elseif #pat.events > 0 then
      level = 4
    end
    g:led(i + 8, 1, level)
  end

  g:led(16, 1, self.alt_held and 15 or 2)

  for head = 1, 7 do
    local pos = self.head_pos[head]
    if self.head_active[head] and not self.mutes[head] and pos >= 0 and pos <= 1 then
      local float_x = pos * 15 + 1
      local x_lo = math.floor(float_x)
      local x_hi = x_lo + 1
      local frac = float_x - x_lo
      local row = head + 1

      if x_lo >= 1 and x_lo <= 16 then
        g:led(x_lo, row, math.floor((1 - frac) * 12))
      end
      if x_hi >= 1 and x_hi <= 16 then
        g:led(x_hi, row, math.floor(frac * 12))
      end
    end
  end

  g:refresh()
end

return GridUI
