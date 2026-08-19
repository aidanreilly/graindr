// Engine_Graindr
//
// Based on Engine_Glut by artfwo <https://github.com/artfwo/glut>.
//
// Differences from Glut:
//   - one shared stereo buffer pair, since graindr draws one waveform
//   - a control-rate LFO per voice modulating playhead speed
//   - master volume on the effect synth, freeing \gain for a per-voice level
//   - no reverb of its own: crone's reverb sits downstream, so the softcut
//     delay can feed it as well
//   - waveform summary and buffer info sent to lua over custom OSC
//   - a global ADSR with a sustain time, in place of Glut's scaled ASR
//   - the playhead only advances while the envelope is open
//   - the envelope value is polled back to lua, which fades the playhead
//   - loop points per voice, with a direction
//   - \scatter, varying the clock period and each grain's length
//   - Glut's \freeze argument and level_N polls removed as unused here

Engine_Graindr : CroneEngine {
	classvar nvoices = 8;
	classvar bufSeconds = 60;
	var pg;
	var effect;
	var <bufL;
	var <bufR;
	var <voices;
	var mixBus;
	var <phases;
	var <envs;
	var recSynth;
	var matronAddr;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// bufL and bufR are always distinct Buffers: aliasing them for a mono file
	// would double-free on the next load and collapse a recording into one channel.
	swapBuffers { arg newL, newR;
		var oldL = bufL;
		var oldR = bufR;
		bufL = newL;
		bufR = newR;
		voices.do({ arg v; v.set(\buf_l, bufL, \buf_r, bufR) });
		if(oldL.notNil, { oldL.free });
		if(oldR.notNil, { oldR.free });
	}

	alloc {
		// not Crone.remoteAddr (8888): that registers handlers only for specific
		// /report/* paths, so custom paths are dropped. matron's generic receiver,
		// the one that reaches lua's osc.event, is args_remote_port, default 10111.
		matronAddr = NetAddr("127.0.0.1", 10111);

		bufL = Buffer.alloc(context.server, context.server.sampleRate * bufSeconds, 1);
		bufR = Buffer.alloc(context.server, context.server.sampleRate * bufSeconds, 1);

		SynthDef(\graindr_voice, {
			arg out, phase_out, env_out, buf_l, buf_r,
			gate=0, hold=0, t_trig=0, sustain_time=2, pos=0, t_reset_pos=0,
			speed=1, pitch=1, pan=0, gain=1,
			size=0.1, density=20, jitter=0, spread=0, scatter=0,
			attack=0.5, decay=0.3, sustain=1.0, release=1.0,
			lfo_shape=0, lfo_rate=0.2, lfo_depth=0,
			loop_lo=0, loop_hi=1, loop_dir=1;

			var slot;
			var grain_trig;
			var grain_dur;
			var jitter_sig;
			var pan_sig;
			var sig_l;
			var sig_r;
			var buf_dur;
			var lfo_sig;
			var eff_speed;
			var running;
			var buf_pos;
			var pos_sig;
			var held_env;
			var shot_env;
			var hold_env;
			var sig_mix;
			var env;

			buf_dur = BufDur.kr(buf_l);

			// bipolar in every shape, so lfo_depth means one thing throughout
			lfo_sig = Select.kr(lfo_shape, [
				SinOsc.kr(lfo_rate),
				LFTri.kr(lfo_rate),
				LFSaw.kr(lfo_rate),
				(LFPulse.kr(lfo_rate, 0, 0.5) * 2) - 1,
				LFNoise0.kr(lfo_rate)
			]);

			// three envelopes over the same values, maxed so none can close another.
			// held_env is a MIDI note; a negative gate force-releases it, which is panic.
			held_env = EnvGen.kr(
				Env.adsr(attack, decay, sustain, release),
				gate: gate);

			// shot_env is one cycle from a grid press. no sustain node, so t_trig is a
			// trigger: it ends on its own, and a second press restarts the attack.
			shot_env = EnvGen.kr(
				Env.new([0, 1, sustain, sustain, 0],
					[attack, decay, sustain_time, release], -4),
				gate: t_trig);

			// hold_env is a looping voice: full level, no decay or sustain level,
			// nothing running out. attack and release stay as the ramps in and out.
			hold_env = EnvGen.kr(
				Env.asr(attack, 1.0, release, -4),
				gate: hold);

			env = held_env.max(shot_env).max(hold_env);

			// the playhead runs only while the voice sounds, and freezes where it
			// stands when the release runs out
			running = env > 0.0001;

			// the sum swings through zero at depth > |speed|, reversing the playhead.
			// loop_dir flips it, so a right-to-left gesture scans backwards.
			eff_speed = (speed + (lfo_sig * lfo_depth)) * loop_dir * running;

			// Phasor wraps between start and end, so a loop needs nothing extra:
			// unset they are 0 and 1. positional: trig, rate, start, end, resetPos
			buf_pos = Phasor.kr(
				t_reset_pos,
				buf_dur.reciprocal / ControlRate.ir * eff_speed,
				loop_lo,
				loop_hi,
				pos);

			// Phasor corrects by one period per block, so a reset from outside the
			// loop needs a real modulo to pull it in
			pos_sig = Wrap.kr(buf_pos, loop_lo, loop_hi);

			// a plain Impulse fires on an exact grid, which at low densities is
			// audible as a pulse. LFNoise0 gives each period its own length, so
			// onsets land anywhere in their slot. midiratio, so the period is
			// scaled symmetrically and never reaches zero.
			slot = (LFNoise0.kr(density) * scatter * 12).midiratio;

			// `running` gates the trigger, so a voice at rest computes no grains at
			// all — otherwise eight idle voices would cost eight playing ones.
			// Grains in flight still finish, so this cannot click.
			grain_trig = Impulse.kr(density * slot) * running;

			// grains get their own lengths too: identical overlapping grains
			// comb-filter against each other, varied ones do not
			grain_dur = size * (TRand.kr(grain_trig, -1, 1) * scatter * 6).midiratio;

			jitter_sig = TRand.kr(grain_trig,
				buf_dur.reciprocal.neg * jitter,
				buf_dur.reciprocal * jitter);
			pan_sig = TRand.kr(grain_trig, spread.neg, spread);

			// cubic, not linear: every grain of a MIDI note off the root is a
			// resampled read
			sig_l = GrainBuf.ar(1, grain_trig, grain_dur, buf_l, pitch, pos_sig + jitter_sig, 4);
			sig_r = GrainBuf.ar(1, grain_trig, grain_dur, buf_r, pitch, pos_sig + jitter_sig, 4);

			sig_mix = Balance2.ar(sig_l, sig_r, pan + pan_sig);

			Out.ar(out, sig_mix * env * gain);
			Out.kr(phase_out, pos_sig);
			// lua fades the playhead with this, so the display is the real envelope
			Out.kr(env_out, env);
		}).add;

		// master gain only. reverb is crone's, downstream of the engine, so the
		// delay can feed it too — see lib/delay.lua.
		SynthDef(\graindr_effect, {
			arg in, out, amp=1;
			Out.ar(out, In.ar(in, 2) * amp);
		}).add;

		SynthDef(\graindr_rec, {
			arg buf_l, buf_r, gate=1;
			var env = EnvGen.kr(Env.asr(0, 1, 0.01), gate, doneAction: 2);
			RecordBuf.ar(SoundIn.ar(0) * env, buf_l, loop: 0);
			RecordBuf.ar(SoundIn.ar(1) * env, buf_r, loop: 0);
		}).add;

		context.server.sync;

		mixBus = Bus.audio(context.server, 2);

		effect = Synth.new(\graindr_effect,
			[\in, mixBus.index, \out, context.out_b.index],
			target: context.xg);

		phases = Array.fill(nvoices, { arg i; Bus.control(context.server); });
		envs = Array.fill(nvoices, { arg i; Bus.control(context.server); });

		pg = ParGroup.head(context.xg);

		// allocated once and never freed. an untriggered voice is silent, its
		// Phasor stalled and its grain triggers gated off.
		voices = Array.fill(nvoices, { arg i;
			Synth.new(\graindr_voice, [
				\out, mixBus.index,
				\phase_out, phases[i].index,
				\env_out, envs[i].index,
				\buf_l, bufL,
				\buf_r, bufR,
				\pos, i / nvoices
			], target: pg);
		});

		context.server.sync;

		// --- per-voice commands, 1-based voice index like Glut ---

		this.addCommand("gate", "ii", { arg msg;
			voices[msg[1] - 1].set(\gate, msg[2]);
		});

		this.addCommand("trig", "i", { arg msg;
			voices[msg[1] - 1].set(\t_trig, 1);
		});

		// sustains a looping voice, bypassing the ADSR entirely
		this.addCommand("hold", "ii", { arg msg;
			voices[msg[1] - 1].set(\hold, msg[2]);
		});

		// a negative gate force-releases EnvGen over -1 - gate seconds. 20ms reads
		// as a cut without clicking, and every envelope can open again after.
		this.addCommand("panic", "i", { arg msg;
			voices[msg[1] - 1].set(\gate, -1.02, \t_trig, -1.02, \hold, -1.02);
		});

		this.addCommand("seek", "if", { arg msg;
			voices[msg[1] - 1].set(\pos, msg[2], \t_reset_pos, 1);
		});

		// lo and hi are ordered; dir carries which way the gesture went
		this.addCommand("loop", "iffi", { arg msg;
			voices[msg[1] - 1].set(
				\loop_lo, msg[2], \loop_hi, msg[3], \loop_dir, msg[4]);
		});

		this.addCommand("loop_clear", "i", { arg msg;
			voices[msg[1] - 1].set(\loop_lo, 0, \loop_hi, 1, \loop_dir, 1);
		});

		this.addCommand("speed", "if", { arg msg;
			voices[msg[1] - 1].set(\speed, msg[2]);
		});

		this.addCommand("pitch", "if", { arg msg;
			voices[msg[1] - 1].set(\pitch, msg[2]);
		});

		this.addCommand("pan", "if", { arg msg;
			voices[msg[1] - 1].set(\pan, msg[2]);
		});

		this.addCommand("level", "if", { arg msg;
			voices[msg[1] - 1].set(\gain, msg[2]);
		});

		this.addCommand("lfo_shape", "ii", { arg msg;
			voices[msg[1] - 1].set(\lfo_shape, msg[2]);
		});

		this.addCommand("lfo_rate", "if", { arg msg;
			voices[msg[1] - 1].set(\lfo_rate, msg[2]);
		});

		this.addCommand("lfo_depth", "if", { arg msg;
			voices[msg[1] - 1].set(\lfo_depth, msg[2]);
		});

		// --- global commands ---

		this.addCommand("size", "f", { arg msg;
			voices.do({ arg v; v.set(\size, msg[1]) });
		});

		this.addCommand("density", "f", { arg msg;
			voices.do({ arg v; v.set(\density, msg[1]) });
		});

		this.addCommand("scatter", "f", { arg msg;
			voices.do({ arg v; v.set(\scatter, msg[1]) });
		});

		this.addCommand("jitter", "f", { arg msg;
			voices.do({ arg v; v.set(\jitter, msg[1]) });
		});

		this.addCommand("spread", "f", { arg msg;
			voices.do({ arg v; v.set(\spread, msg[1]) });
		});

		this.addCommand("attack", "f", { arg msg;
			voices.do({ arg v; v.set(\attack, msg[1]) });
		});

		this.addCommand("decay", "f", { arg msg;
			voices.do({ arg v; v.set(\decay, msg[1]) });
		});

		this.addCommand("sustain", "f", { arg msg;
			voices.do({ arg v; v.set(\sustain, msg[1]) });
		});

		this.addCommand("release", "f", { arg msg;
			voices.do({ arg v; v.set(\release, msg[1]) });
		});

		this.addCommand("sustain_time", "f", { arg msg;
			voices.do({ arg v; v.set(\sustain_time, msg[1]) });
		});

		this.addCommand("volume", "f", { arg msg;
			effect.set(\amp, msg[1]);
		});

		// reads at most bufSeconds, the recorder's ceiling. unbounded, an hour long
		// file would ask the server for gigabytes. longer files are cut, not refused.
		this.addCommand("buf_load", "s", { arg msg;
			var path = msg[1].asString;
			var file;

			if(File.exists(path).not, {
				("Engine_Graindr: no such file: " ++ path).warn;
			}, {
				file = SoundFile.openRead(path);
				if(file.isNil, {
					("Engine_Graindr: could not read as audio: " ++ path).warn;
				}, {
					var numChannels = file.numChannels;
					var fileFrames = file.numFrames;
					var maxFrames = (bufSeconds * file.sampleRate).asInteger;
					var frames = fileFrames.min(maxFrames).max(1);
					var truncated = if(fileFrames > maxFrames, { 1 }, { 0 });
					var srcR = if(numChannels > 1, { 1 }, { 0 });
					file.close;

					if(truncated == 1, {
						("Engine_Graindr: " ++ path ++ " is longer than "
							++ bufSeconds ++ "s, loading the first "
							++ bufSeconds ++ "s").warn;
					});

					// both reads complete before the old pair is freed, so a failed
					// read cannot leave a voice pointing at freed memory
					Buffer.readChannel(context.server, path, 0, frames, [0], { arg newL;
						Buffer.readChannel(context.server, path, 0, frames, [srcR], { arg newR;
							this.swapBuffers(newL, newR);
							matronAddr.sendMsg("/graindr/buf_info",
								newL.numFrames, newL.sampleRate, truncated);
							this.sendWaveform();
						});
					});
				});
			});
		});

		this.addCommand("rec_start", "", { arg msg;
			if(recSynth.notNil, { recSynth.free; recSynth = nil });
			// reallocate to full length first, or a short sample already loaded
			// would cap the recording at its own duration
			Routine({
				var newL = Buffer.alloc(context.server,
					context.server.sampleRate * bufSeconds, 1);
				var newR = Buffer.alloc(context.server,
					context.server.sampleRate * bufSeconds, 1);
				context.server.sync;
				this.swapBuffers(newL, newR);
				recSynth = Synth(\graindr_rec,
					[\buf_l, bufL, \buf_r, bufR], context.server);
			}).play(AppClock);
		});

		// lua passes the recorded duration, so the capture buffer can be trimmed.
		// without it the playheads would scan the unrecorded silence.
		this.addCommand("rec_stop", "f", { arg msg;
			var dur = msg[1].asFloat;
			if(recSynth.notNil, {
				recSynth.set(\gate, 0);
				recSynth = nil;
				Routine({
					var frames = (dur * context.server.sampleRate).asInteger
						.clip(1, bufSeconds * context.server.sampleRate);
					var newL, newR;
					0.1.wait; // let the record synth's release finish writing
					newL = Buffer.alloc(context.server, frames, 1);
					newR = Buffer.alloc(context.server, frames, 1);
					context.server.sync;
					bufL.copyData(newL, 0, 0, frames);
					bufR.copyData(newR, 0, 0, frames);
					context.server.sync;
					this.swapBuffers(newL, newR);
					matronAddr.sendMsg("/graindr/buf_info",
						frames, context.server.sampleRate, 0);
					this.sendWaveform();
				}).play(AppClock);
			});
		});

		nvoices.do({ arg i;
			this.addPoll(("phase_" ++ (i + 1)).asSymbol, {
				phases[i].getSynchronous
			});
			this.addPoll(("env_" ++ (i + 1)).asSymbol, {
				envs[i].getSynchronous
			});
		});
	}

	// 128 min/max pairs packed as bytes 0-126. polls carry one float, so this
	// goes over custom OSC.
	sendWaveform {
		bufL.loadToFloatArray(action: { arg data;
			var peak = 0.0;
			var scale;
			var waveData = Array.new(256);

			if(data.size < 1, {
				"Engine_Graindr: empty buffer, no waveform to send".warn;
			}, {
				// normalised to the buffer's own peak, so a quiet sample fills the
				// screen. the floor stops near-silence becoming a screen of noise.
				data.do({ arg samp;
					var mag = samp.abs;
					if(mag > peak, { peak = mag });
				});
				scale = if(peak > 0.01, { 1.0 / peak }, { 1.0 });

				// bounds from the true fractional width, not a truncated integer:
				// the last columns are not dropped, and a buffer under 128 frames
				// still fills the display
				128.do({ arg i;
					var startIdx = (i * data.size / 128).asInteger;
					var endIdx = ((i + 1) * data.size / 128).asInteger
						.max(startIdx + 1).min(data.size);
					var minVal = 0.0;
					var maxVal = 0.0;

					(endIdx - startIdx).do({ arg j;
						var samp = data[startIdx + j] * scale;
						if(samp < minVal, { minVal = samp });
						if(samp > maxVal, { maxVal = samp });
					});

					waveData = waveData.add(minVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
					waveData = waveData.add(maxVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
				});

				matronAddr.sendMsg("/graindr/waveform", *waveData);
			});
		});
	}

	free {
		if(recSynth.notNil, { recSynth.free });
		voices.do({ arg v; v.free });
		phases.do({ arg b; b.free });
		envs.do({ arg b; b.free });
		effect.free;
		mixBus.free;
		bufL.free;
		bufR.free;
	}
}
