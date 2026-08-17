Engine_Sediment : CroneEngine {
    var buffer;
    var <voices;
    var <voiceVel;
    var <recSynth;
    var params;
    var spreadVal;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        voices = Array.fill(8, { nil });
        voiceVel = Array.fill(8, { 0.0 });
        spreadVal = 0.5;

        buffer = Buffer.alloc(context.server, 48000 * 60, 1);

        params = Dictionary[
            \scatter -> 0.5, \bloom -> 0.3, \drift -> 0.3,
            \position -> 0.5, \feedback -> 0.0, \dryWet -> 0.5,
            \freeze -> 0, \mode -> 0, \speed -> 1.0, \amp -> 0.8
        ];

        SynthDef(\sediment_voice, { arg out=0, bufnum, gate=1,
            t_jump=0, bufPos=0.5, speed=1,
            pitch=0, position=0.5, scatter=0.5, bloom=0.3,
            drift=0.3, feedback=0, dryWet=0.5, freeze=0,
            mode=0,
            amp=0.8, pan=0;
            var frames = BufFrames.kr(bufnum);
            var rate = BufRateScale.kr(bufnum) * speed;
            var phase = Phasor.ar(t_jump, rate, 0, frames, bufPos * frames);
            var inMono = BufRd.ar(1, bufnum, phase, interpolation: 4);
            var sig = Sediment.ar(inMono, inMono, pitch, position, scatter,
                                  bloom, drift, feedback, dryWet, freeze, mode);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.1), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\sediment_rec, { arg bufnum, gate=1;
            var in = SoundIn.ar(0);
            var env = EnvGen.kr(Env.asr(0, 1, 0.01), gate, doneAction: 2);
            RecordBuf.ar(in * env, bufnum, loop: 0);
        }).add;

        this.addCommand("note_on", "iff", { arg msg;
            var slot = msg[1].asInteger.clip(0, 7);
            var pitch = msg[2].asFloat;
            var amp = msg[3].asFloat;

            if(voices[slot].notNil, {
                voices[slot].set(\gate, 0);
            });

            voiceVel[slot] = amp;
            voices[slot] = Synth(\sediment_voice, [
                \out, 0, \bufnum, buffer.bufnum,
                \bufPos, 0.5, \speed, params[\speed],
                \pitch, pitch, \position, params[\position],
                \scatter, params[\scatter], \bloom, params[\bloom],
                \drift, params[\drift], \feedback, params[\feedback],
                \dryWet, params[\dryWet], \freeze, params[\freeze],
                \mode, params[\mode],
                \amp, amp * params[\amp],
                \pan, (slot - 3.5) / 3.5 * spreadVal,
                \t_jump, 1
            ], context.server);
        });

        this.addCommand("note_off", "i", { arg msg;
            var slot = msg[1].asInteger.clip(0, 7);
            if(voices[slot].notNil, {
                voices[slot].set(\gate, 0);
                voices[slot] = nil;
                voiceVel[slot] = 0.0;
            });
        });

        this.addCommand("voice_pos", "if", { arg msg;
            var slot = msg[1].asInteger.clip(0, 7);
            var pos = msg[2].asFloat.clip(0, 1);
            if(voices[slot].notNil, {
                voices[slot].set(\bufPos, pos, \t_jump, 1);
            });
        });

        this.addCommand("scatter", "f", { arg msg;
            params[\scatter] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\scatter, params[\scatter]) });
            });
        });

        this.addCommand("bloom", "f", { arg msg;
            params[\bloom] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\bloom, params[\bloom]) });
            });
        });

        this.addCommand("drift", "f", { arg msg;
            params[\drift] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\drift, params[\drift]) });
            });
        });

        this.addCommand("position", "f", { arg msg;
            params[\position] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\position, params[\position]) });
            });
        });

        this.addCommand("feedback", "f", { arg msg;
            params[\feedback] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\feedback, params[\feedback]) });
            });
        });

        this.addCommand("dry_wet", "f", { arg msg;
            params[\dryWet] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\dryWet, params[\dryWet]) });
            });
        });

        this.addCommand("freeze", "f", { arg msg;
            params[\freeze] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\freeze, params[\freeze]) });
            });
        });

        this.addCommand("mode", "i", { arg msg;
            params[\mode] = msg[1].asInteger.clip(0, 2);
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\mode, params[\mode]) });
            });
        });

        this.addCommand("speed", "f", { arg msg;
            params[\speed] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\speed, params[\speed]) });
            });
        });

        this.addCommand("volume", "f", { arg msg;
            params[\amp] = msg[1].asFloat;
            voices.do({ arg synth, i;
                if(synth.notNil, {
                    synth.set(\amp, voiceVel[i] * params[\amp]);
                });
            });
        });

        this.addCommand("spread", "f", { arg msg;
            spreadVal = msg[1].asFloat;
            voices.do({ arg synth, i;
                if(synth.notNil, {
                    synth.set(\pan, (i - 3.5) / 3.5 * spreadVal);
                });
            });
        });

        this.addCommand("buf_load", "s", { arg msg;
            var path = msg[1].asString;
            voices.do({ arg synth, i;
                if(synth.notNil, { synth.set(\gate, 0); voices[i] = nil });
            });
            Buffer.read(context.server, path, action: { arg newBuf;
                buffer.free;
                buffer = newBuf;
                context.server.addr.sendMsg("/sediment/buf_info",
                    newBuf.numFrames, newBuf.sampleRate);
                this.sendWaveform();
            });
        });

        this.addCommand("rec_start", "", { arg msg;
            if(recSynth.notNil, { recSynth.free });
            recSynth = Synth(\sediment_rec, [\bufnum, buffer.bufnum], context.server);
        });

        this.addCommand("rec_stop", "", { arg msg;
            if(recSynth.notNil, {
                recSynth.set(\gate, 0);
                recSynth = nil;
                AppClock.sched(0.1, { this.sendWaveform(); nil });
            });
        });
    }

    sendWaveform {
        buffer.loadToFloatArray(action: { arg data;
            var numChans = buffer.numChannels;
            var monoFrames = data.size div: numChans;
            var segSize = (monoFrames / 128).asInteger.max(1);
            var waveData = Array.new(256);

            128.do({ arg i;
                var startIdx = i * segSize * numChans;
                var minVal = 1.0, maxVal = -1.0;

                segSize.do({ arg j;
                    var idx = startIdx + (j * numChans);
                    if(idx < data.size, {
                        var samp = data[idx];
                        if(samp < minVal, { minVal = samp });
                        if(samp > maxVal, { maxVal = samp });
                    });
                });

                waveData = waveData.add(minVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
                waveData = waveData.add(maxVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
            });

            context.server.addr.sendMsg("/sediment/waveform", *waveData);
        });
    }

    free {
        voices.do({ arg synth; if(synth.notNil, { synth.free }) });
        if(recSynth.notNil, { recSynth.free });
        buffer.free;
    }
}
