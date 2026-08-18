// Engine_Graindr
//
// Based on Engine_Glut by artfwo <https://github.com/artfwo/glut>.
//
// Differences from Glut:
//   - one shared stereo buffer pair for all voices, rather than a buffer per
//     voice, because graindr draws a single waveform with eight playheads
//   - a control-rate LFO per voice modulating playhead speed bipolarly
//   - master volume on the effect synth, freeing \gain for a per-voice level
//   - waveform summary and buffer info sent to lua over custom OSC
//   - a global ADSR replaces Glut's envscale-scaled ASR, with a sustain time
//     so a single grid press plays one complete envelope cycle
//   - the playhead only advances while the envelope is open, so a voice at
//     rest is silent and stationary rather than free-running
//   - the envelope value is polled back to lua, which fades the playhead on
//     screen and grid along the same curve you hear
//   - loop points per voice, with a direction, so a grid gesture can trap a
//     playhead in a region and run it either way through it
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

	// Swap in a new buffer pair, repoint every voice at it, then free the old
	// pair. bufL and bufR are always distinct Buffer objects: they are shared
	// across all eight voices and are recorded into, so aliasing them for a
	// mono file would double-free on the next load and would collapse both
	// channels of a recording into one buffer.
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
		// Crone.remoteAddr (port 8888) is matron's *internal* report channel —
		// oracle.cc registers handlers only for specific /report/* and
		// /crone/ready paths there, with no wildcard fallback, so custom
		// paths sent to it are silently dropped by liblo. matron's generic
		// OSC receiver that actually forwards to lua's osc.event listens on
		// args_remote_port() instead, which defaults to 10111.
		matronAddr = NetAddr("127.0.0.1", 10111);

		bufL = Buffer.alloc(context.server, context.server.sampleRate * bufSeconds, 1);
		bufR = Buffer.alloc(context.server, context.server.sampleRate * bufSeconds, 1);

		SynthDef(\graindr_voice, {
			arg out, phase_out, env_out, buf_l, buf_r,
			gate=0, hold=0, t_trig=0, sustain_time=2, pos=0, t_reset_pos=0,
			speed=1, pitch=1, pan=0, gain=1,
			size=0.1, density=20, jitter=0, spread=0,
			attack=0.5, decay=0.3, sustain=1.0, release=1.0,
			lfo_shape=0, lfo_rate=0.2, lfo_depth=0,
			loop_lo=0, loop_hi=1, loop_dir=1;

			var grain_trig;
			var jitter_sig;
			var buf_dur;
			var pan_sig;
			var lfo_sig;
			var eff_speed;
			var running;
			var buf_pos;
			var pos_sig;
			var held_env;
			var shot_env;
			var hold_env;
			var sig_l;
			var sig_r;
			var sig_mix;
			var env;

			grain_trig = Impulse.kr(density);
			buf_dur = BufDur.kr(buf_l);

			pan_sig = TRand.kr(trig: grain_trig,
				lo: spread.neg,
				hi: spread);

			jitter_sig = TRand.kr(trig: grain_trig,
				lo: buf_dur.reciprocal.neg * jitter,
				hi: buf_dur.reciprocal * jitter);

			// bipolar, -1 to 1 in every shape, so lfo_depth means the same
			// thing whichever shape is selected
			lfo_sig = Select.kr(lfo_shape, [
				SinOsc.kr(lfo_rate),
				LFTri.kr(lfo_rate),
				LFSaw.kr(lfo_rate),
				(LFPulse.kr(lfo_rate, 0, 0.5) * 2) - 1,
				LFNoise0.kr(lfo_rate)
			]);

			// three envelopes over the same values, combined with max so none
			// of them can close another.
			//
			// held_env sustains for as long as a MIDI note holds it open.
			// A negative gate forces an immediate release, which is how panic
			// cuts a voice short.
			held_env = EnvGen.kr(
				Env.adsr(attack, decay, sustain, release),
				gate: gate);

			// shot_env is one complete cycle fired by a grid press. the Env
			// has no sustain node, so t_trig acts as a trigger: it runs
			// A-D-S-R once and ends on its own, and a second press during the
			// sustain restarts it from the attack rather than being swallowed
			// by an already-open gate.
			shot_env = EnvGen.kr(
				Env.new([0, 1, sustain, sustain, 0],
					[attack, decay, sustain_time, release], -4),
				gate: t_trig);

			// hold_env is a looping voice. A loop takes the ADSR out of the
			// picture: decay and sustain level do not apply and nothing runs
			// out, so the voice sustains at full level for as long as the loop
			// is set. Attack and release times are kept only as the ramps in
			// and out, so engaging and clearing a loop does not click.
			hold_env = EnvGen.kr(
				Env.asr(attack, 1.0, release, -4),
				gate: hold);

			env = held_env.max(shot_env).max(hold_env);

			// the playhead exists only while the voice is sounding. it starts
			// moving on the attack and freezes where it stands the moment the
			// release runs out, so a voice at rest shows nothing on the grid
			// or the screen until it is triggered again.
			running = env > 0.0001;

			// the sum swings through zero at depth > |speed|, which is what
			// reverses the playhead. loop_dir flips the whole thing, so a
			// right-to-left grid gesture scans its loop backwards.
			eff_speed = (speed + (lfo_sig * lfo_depth)) * loop_dir * running;

			// Phasor wraps between start and end, so the loop needs no extra
			// machinery: with no loop set those are 0 and 1, which is a plain
			// scan of the whole buffer.
			// positional: trig, rate, start, end, resetPos
			buf_pos = Phasor.kr(
				t_reset_pos,
				buf_dur.reciprocal / ControlRate.ir * eff_speed,
				loop_lo,
				loop_hi,
				pos);

			// Phasor only corrects by one period per block, so a reset to a
			// position outside the loop needs a real modulo to pull it in
			pos_sig = Wrap.kr(buf_pos, loop_lo, loop_hi);

			sig_l = GrainBuf.ar(1, grain_trig, size, buf_l, pitch, pos_sig + jitter_sig, 2);
			sig_r = GrainBuf.ar(1, grain_trig, size, buf_r, pitch, pos_sig + jitter_sig, 2);

			sig_mix = Balance2.ar(sig_l, sig_r, pan + pan_sig);

			Out.ar(out, sig_mix * env * gain);
			Out.kr(phase_out, pos_sig);
			// lua fades the playhead on screen and grid with this, so what you
			// see is the envelope you hear rather than an estimate of it
			Out.kr(env_out, env);
		}).add;

		SynthDef(\graindr_effect, {
			arg in, out, mix=0.5, room=0.5, damp=0.5, amp=1;
			var sig = In.ar(in, 2);
			sig = FreeVerb.ar(sig, mix, room, damp);
			Out.ar(out, sig * amp);
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

		// voices are allocated once and never freed. an untriggered voice is
		// silent and its Phasor is stalled, so it costs nothing but the grain
		// oscillator ticking over into a closed envelope.
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

		// a negative gate forces EnvGen to release over -1 - gate seconds.
		// 20ms is short enough to read as a cut and long enough not to click,
		// and it leaves every envelope able to open again afterwards.
		this.addCommand("panic", "i", { arg msg;
			voices[msg[1] - 1].set(\gate, -1.02, \t_trig, -1.02, \hold, -1.02);
		});

		this.addCommand("seek", "if", { arg msg;
			voices[msg[1] - 1].set(\pos, msg[2], \t_reset_pos, 1);
		});

		// lo and hi are always ordered; dir carries which way round the
		// gesture was made, and is 1 when there is no loop
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

		this.addCommand("reverb_mix", "f", { arg msg; effect.set(\mix, msg[1]); });
		this.addCommand("reverb_room", "f", { arg msg; effect.set(\room, msg[1]); });
		this.addCommand("reverb_damp", "f", { arg msg; effect.set(\damp, msg[1]); });

		this.addCommand("buf_load", "s", { arg msg;
			var path = msg[1].asString;
			if(File.exists(path), {
				var numChannels = SoundFile.use(path, { arg f; f.numChannels });
				var srcR = if(numChannels > 1, { 1 }, { 0 });
				// both reads complete before the old pair is freed, so a
				// failed read cannot leave a voice pointing at freed memory
				Buffer.readChannel(context.server, path, 0, -1, [0], { arg newL;
					Buffer.readChannel(context.server, path, 0, -1, [srcR], { arg newR;
						this.swapBuffers(newL, newR);
						matronAddr.sendMsg("/graindr/buf_info",
							newL.numFrames, newL.sampleRate);
						this.sendWaveform();
					});
				});
			}, {
				("Engine_Graindr: no such file: " ++ path).warn;
			});
		});

		this.addCommand("rec_start", "", { arg msg;
			if(recSynth.notNil, { recSynth.free; recSynth = nil });
			// reallocate to full length first: a previously loaded short
			// sample would otherwise cap the recording at its own duration
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

		// takes the recorded duration in seconds from lua, so the 60 second
		// capture buffer can be trimmed down to what was actually recorded.
		// without this the playheads would scan the unrecorded silence.
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
						frames, context.server.sampleRate);
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

	// 128 min/max pairs summarising bufL, packed as bytes 0-126 for the
	// screen. Polls carry a single float, so this goes over custom OSC.
	sendWaveform {
		bufL.loadToFloatArray(action: { arg data;
			var segSize = (data.size / 128).asInteger.max(1);
			var waveData = Array.new(256);

			128.do({ arg i;
				var startIdx = i * segSize;
				var minVal = 1.0;
				var maxVal = -1.0;

				segSize.do({ arg j;
					var idx = startIdx + j;
					if(idx < data.size, {
						var samp = data[idx];
						if(samp < minVal, { minVal = samp });
						if(samp > maxVal, { maxVal = samp });
					});
				});

				waveData = waveData.add(minVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
				waveData = waveData.add(maxVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
			});

			matronAddr.sendMsg("/graindr/waveform", *waveData);
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
