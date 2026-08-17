-- lib/waveform.lua

local Waveform = {}
Waveform.__index = Waveform

function Waveform.new(x, y, w, h, num_heads)
  local wf = setmetatable({}, Waveform)
  wf.x = x
  wf.y = y
  wf.w = w
  wf.h = h
  wf.num_heads = num_heads or 7
  wf.samples = {}
  wf.head_pos = {}
  wf.head_active = {}
  for i = 1, wf.num_heads do
    wf.head_pos[i] = -1
    wf.head_active[i] = false
  end
  return wf
end

function Waveform:set_samples(data)
  self.samples = {}
  for i = 1, 128 do
    local min_val = util.linlin(0, 126, -1, 1, data[(i - 1) * 2 + 1] or 63)
    local max_val = util.linlin(0, 126, -1, 1, data[(i - 1) * 2 + 2] or 63)
    self.samples[i] = { min_val, max_val }
  end
end

function Waveform:set_head_pos(head, pos)
  if head >= 1 and head <= self.num_heads then
    self.head_pos[head] = pos
  end
end

function Waveform:set_head_active(head, active)
  if head >= 1 and head <= self.num_heads then
    self.head_active[head] = active
  end
end

function Waveform:clear()
  self.samples = {}
  for i = 1, self.num_heads do
    self.head_pos[i] = -1
    self.head_active[i] = false
  end
end

function Waveform:draw()
  local center_y = self.y + self.h / 2
  local half_h = self.h / 2

  if #self.samples > 0 then
    screen.level(6)
    for i = 1, math.min(#self.samples, self.w) do
      local s = self.samples[i]
      local px = self.x + i - 1
      local y_top = center_y - s[2] * half_h
      local y_bot = center_y - s[1] * half_h
      screen.move(px, y_top)
      screen.line(px, y_bot)
      screen.stroke()
    end
  else
    screen.level(2)
    screen.move(self.x, center_y)
    screen.line(self.x + self.w, center_y)
    screen.stroke()
  end

  for i = 1, self.num_heads do
    local pos = self.head_pos[i]
    if self.head_active[i] and pos >= 0 and pos <= 1 then
      local px = self.x + math.floor(pos * (self.w - 1))
      screen.level(15)
      screen.move(px, self.y)
      screen.line(px, self.y + self.h)
      screen.stroke()
      screen.move(px - 1, self.y + self.h + 6)
      screen.level(10)
      screen.text(tostring(i))
    end
  end
end

return Waveform
