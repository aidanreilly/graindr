-- lib/delay.lua
-- softcut delay, after halfsecond by @tehn.

local Delay = {}

local VOICE = 1
local BUF_START = 1
local MAX_TIME = 4.0

function Delay.init()
  softcut.buffer_clear()

  audio.level_cut(1.0)
  -- the engine feeds the delay. live input does not: graindr records from
  -- input itself, and monitoring belongs to SYSTEM > AUDIO.
  audio.level_eng_cut(1.0)
  audio.level_adc_cut(0)

  softcut.level(VOICE, 0)
  softcut.level_slew_time(VOICE, 0.25)
  softcut.level_input_cut(1, VOICE, 1.0)
  softcut.level_input_cut(2, VOICE, 1.0)
  softcut.pan(VOICE, 0)

  softcut.play(VOICE, 1)
  softcut.rate(VOICE, 1)
  -- slewed, so a rate change bends like tape rather than jumping
  softcut.rate_slew_time(VOICE, 0.25)
  softcut.loop_start(VOICE, BUF_START)
  softcut.loop_end(VOICE, BUF_START + 0.5)
  softcut.loop(VOICE, 1)
  softcut.fade_time(VOICE, 0.1)
  softcut.rec(VOICE, 1)
  softcut.rec_level(VOICE, 1)
  softcut.pre_level(VOICE, 0.5)
  softcut.position(VOICE, BUF_START)
  softcut.enable(VOICE, 1)

  -- lowpass, where halfsecond uses bandpass: repeats darken as they recede
  -- rather than taking on its hollow character
  softcut.filter_dry(VOICE, 0)
  softcut.filter_lp(VOICE, 1.0)
  softcut.filter_bp(VOICE, 0)
  softcut.filter_fc(VOICE, 4000)
  softcut.filter_rq(VOICE, 2.0)
end

-- delay time is the loop length, so this moves the loop end
function Delay.set_time(t)
  softcut.loop_end(VOICE, BUF_START + util.clamp(t, 0.05, MAX_TIME))
end

function Delay.set_feedback(x) softcut.pre_level(VOICE, x) end
function Delay.set_level(x) softcut.level(VOICE, x) end
function Delay.set_rate(x) softcut.rate(VOICE, x) end
function Delay.set_pan(x) softcut.pan(VOICE, x) end
function Delay.set_filter_fc(x) softcut.filter_fc(VOICE, x) end
function Delay.set_filter_rq(x) softcut.filter_rq(VOICE, x) end

function Delay.stop()
  softcut.rec(VOICE, 0)
  softcut.play(VOICE, 0)
  softcut.enable(VOICE, 0)
  audio.level_eng_cut(0)
end

return Delay
