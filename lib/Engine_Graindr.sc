Engine_Graindr : CroneEngine {
    var buffer;
    var <heads;          // Array of 7 synth slots (nil when inactive)
    var <headParams;     // Array of 7 Dictionaries: amp, pan
    var <ugenMode;       // 0-8 index
    var <recSynth;
    var ugenNames;
    var ugenCategories;
    var gridMappedParam; // which synth arg head_position sets, per UGen mode
    var gridParamRanges; // [min, max] for the grid-mapped param per UGen mode
    var params;          // Dictionary of all UGen param current values

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        ugenNames = [
            \graindr_silt, \graindr_clast, \graindr_sediment,
            \graindr_talus, \graindr_scree, \graindr_loess,
            \graindr_creep, \graindr_moraine, \graindr_tuff
        ];
        ugenCategories = [
            \buffer, \buffer, \live, \live, \live, \live, \live, \live, \synth
        ];
        gridMappedParam = [
            \position, \position, \position,
            \delay, \sliceDur, \timeSpread,
            \step, \amount, \fund
        ];
        gridParamRanges = [
            [0, 1], [0, 1], [0, 1],
            [0.01, 2.0], [0.01, 1.0], [0, 1],
            [0, 1], [0, 1], [20, 2000]
        ];

        ugenMode = 0;
        heads = Array.fill(7, { nil });
        headParams = Array.fill(7, { Dictionary[\amp -> 0.8, \pan -> 0] });

        buffer = Buffer.alloc(context.server, 48000 * 60, 2);

        params = Dictionary[
            \silt_density -> 20, \silt_dur -> 0.1,
            \silt_scatter -> 0.3, \silt_dist -> 0, \silt_distParam -> 0.5,
            \silt_pitch -> 0, \silt_shape -> 0.5,
            \clast_cycles -> 4, \clast_density -> 40,
            \clast_scan -> 0.0, \clast_pitch -> 0, \clast_spread -> 0.4,
            \clast_shape -> 0.5,
            \sed_pitch -> 0, \sed_scatter -> 0.5,
            \sed_bloom -> 0.3, \sed_drift -> 0.3, \sed_feedback -> 0,
            \sed_dryWet -> 0.5, \sed_freeze -> 0, \sed_mode -> 0,
            \talus_density -> 20, \talus_dur -> 0.2,
            \talus_pitch -> 0, \talus_feedback -> 0.3, \talus_spread -> 0.5,
            \scree_jump -> 0.3, \scree_repeats -> 2,
            \scree_pitch -> 0, \scree_scatter -> 0.3,
            \loess_density -> 300, \loess_grainDur -> 0.006,
            \loess_pitch -> 0, \loess_pitchSpread -> 0.5,
            \creep_ambitus -> 1, \creep_grainDur -> 0.12,
            \creep_overlap -> 0.5, \creep_pitch -> 0, \creep_pause -> 0.0,
            \creep_spread -> 0.5,
            \moraine_mode -> 0, \moraine_gate -> 0.05, \moraine_minHole -> 0.02,
            \moraine_pitch -> 0,
            \tuff_form -> 700, \tuff_attack -> 0.003,
            \tuff_decay -> 0.02, \tuff_dur -> 0.05, \tuff_band -> 60,
            \tuff_oct -> 0, \tuff_spread -> 0.0
        ];

        // ── SynthDefs ──

        SynthDef(\graindr_silt, { arg out=0, bufnum, gate=1,
            density=20, dur=0.1, position=0.5, scatter=0.3,
            dist=0, distParam=0.5, pitch=0, shape=0.5,
            amp=1, pan=0;
            var sig = Silt.ar(bufnum, density, dur, position, scatter,
                              dist, distParam, pitch, shape);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_clast, { arg out=0, bufnum, gate=1,
            cycles=4, density=40, position=0.5, scan=0.0,
            pitch=0, spread=0.4, shape=0.5,
            amp=1, pan=0;
            var sig = Clast.ar(bufnum, cycles, density, position, scan,
                               pitch, spread, shape);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_sediment, { arg out=0, gate=1,
            pitch=0, position=0.5, scatter=0.5, bloom=0.3,
            drift=0.3, feedback=0, dryWet=0.5, freeze=0,
            mode=0, trigger=0,
            amp=1, pan=0;
            var inL = SoundIn.ar(0), inR = SoundIn.ar(1);
            var sig = Sediment.ar(inL, inR, pitch, position, scatter,
                                  bloom, drift, feedback, dryWet, freeze, mode, trigger);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_talus, { arg out=0, gate=1,
            delay=0.25, density=20, dur=0.2, pitch=0,
            feedback=0.3, spread=0.5,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Talus.ar(in, 2, delay, density, dur, pitch, feedback, spread);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_scree, { arg out=0, gate=1,
            sliceDur=0.1, jump=0.3, repeats=2, pitch=0, scatter=0.3,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Scree.ar(in, 2, sliceDur, jump, repeats, pitch, scatter);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_loess, { arg out=0, gate=1,
            density=300, grainDur=0.006, timeSpread=0.5,
            pitch=0, pitchSpread=0.5,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Loess.ar(in, density, grainDur, timeSpread, pitch, pitchSpread);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_creep, { arg out=0, gate=1,
            ambitus=1, step=0.2, grainDur=0.12, overlap=0.5,
            pitch=0, pause=0.0, spread=0.5,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Creep.ar(in, 2, ambitus, step, grainDur, overlap,
                               pitch, pause, spread);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_moraine, { arg out=0, gate=1,
            mode=0, gateThresh=0.05, minHole=0.02, amount=0.5, pitch=0,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Moraine.ar(in, 4, mode, gateThresh, minHole, amount, pitch);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_tuff, { arg out=0, gate=1,
            fund=100, form=700, attack=0.003, decay=0.02,
            dur=0.05, band=60, oct=0, spread=0.0,
            amp=1, pan=0;
            var sig = Tuff.ar(fund, form, attack, decay, dur, band, oct, spread);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_rec, { arg bufnum, gate=1;
            var in = SoundIn.ar([0, 1]);
            var env = EnvGen.kr(Env.asr(0, 1, 0.01), gate, doneAction: 2);
            RecordBuf.ar(in * env, bufnum, loop: 0);
        }).add;

        // ── Commands ──

        // buildArgs helper
        var buildArgs = { arg headIdx, position;
            var argList = [\out, 0, \amp, headParams[headIdx][\amp],
                           \pan, headParams[headIdx][\pan]];
            var cat = ugenCategories[ugenMode];
            var mappedParam = gridMappedParam[ugenMode];
            var range = gridParamRanges[ugenMode];
            var mappedVal;

            if(cat == \buffer, {
                argList = argList ++ [\bufnum, buffer.bufnum];
            });

            // Map position 0-1 to the UGen's param range
            if(ugenMode == 8, {
                // Tuff: exponential mapping for frequency
                mappedVal = position.linexp(0, 1, range[0], range[1]);
            }, {
                mappedVal = position.linlin(0, 1, range[0], range[1]);
            });
            argList = argList ++ [mappedParam, mappedVal];

            // Add all current params for this UGen mode
            switch(ugenMode,
                0, {
                    argList = argList ++ [
                        \density, params[\silt_density], \dur, params[\silt_dur],
                        \scatter, params[\silt_scatter], \dist, params[\silt_dist],
                        \distParam, params[\silt_distParam],
                        \pitch, params[\silt_pitch], \shape, params[\silt_shape]
                    ];
                },
                1, {
                    argList = argList ++ [
                        \cycles, params[\clast_cycles], \density, params[\clast_density],
                        \scan, params[\clast_scan],
                        \pitch, params[\clast_pitch], \spread, params[\clast_spread],
                        \shape, params[\clast_shape]
                    ];
                },
                2, {
                    argList = argList ++ [
                        \pitch, params[\sed_pitch],
                        \scatter, params[\sed_scatter], \bloom, params[\sed_bloom],
                        \drift, params[\sed_drift], \feedback, params[\sed_feedback],
                        \dryWet, params[\sed_dryWet], \freeze, params[\sed_freeze],
                        \mode, params[\sed_mode], \trigger, 1
                    ];
                },
                3, {
                    argList = argList ++ [
                        \density, params[\talus_density], \dur, params[\talus_dur],
                        \pitch, params[\talus_pitch],
                        \feedback, params[\talus_feedback], \spread, params[\talus_spread]
                    ];
                },
                4, {
                    argList = argList ++ [
                        \jump, params[\scree_jump], \repeats, params[\scree_repeats],
                        \pitch, params[\scree_pitch], \scatter, params[\scree_scatter]
                    ];
                },
                5, {
                    argList = argList ++ [
                        \density, params[\loess_density],
                        \grainDur, params[\loess_grainDur],
                        \pitch, params[\loess_pitch],
                        \pitchSpread, params[\loess_pitchSpread]
                    ];
                },
                6, {
                    argList = argList ++ [
                        \ambitus, params[\creep_ambitus],
                        \grainDur, params[\creep_grainDur],
                        \overlap, params[\creep_overlap],
                        \pitch, params[\creep_pitch], \pause, params[\creep_pause],
                        \spread, params[\creep_spread]
                    ];
                },
                7, {
                    argList = argList ++ [
                        \mode, params[\moraine_mode],
                        \gateThresh, params[\moraine_gate],
                        \minHole, params[\moraine_minHole],
                        \pitch, params[\moraine_pitch]
                    ];
                },
                8, {
                    argList = argList ++ [
                        \form, params[\tuff_form], \attack, params[\tuff_attack],
                        \decay, params[\tuff_decay], \dur, params[\tuff_dur],
                        \band, params[\tuff_band], \oct, params[\tuff_oct],
                        \spread, params[\tuff_spread]
                    ];
                }
            );
            argList;
        };

        this.addCommand("ugen_select", "i", { arg msg;
            var newMode = msg[1].asInteger.clip(0, 8);
            heads.do({ arg synth, i;
                if(synth.notNil, {
                    synth.set(\gate, 0);
                    heads[i] = nil;
                });
            });
            ugenMode = newMode;
        });

        this.addCommand("head_start", "if", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            var position = msg[2].asFloat.clip(0, 1);
            var name = ugenNames[ugenMode];
            var args;

            if(heads[idx].notNil, {
                heads[idx].set(\gate, 0);
            });

            args = buildArgs.value(idx, position);
            heads[idx] = Synth(name, args, context.server);
        });

        this.addCommand("head_stop", "i", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            if(heads[idx].notNil, {
                heads[idx].set(\gate, 0);
                heads[idx] = nil;
            });
        });

        this.addCommand("head_position", "if", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            var position = msg[2].asFloat.clip(0, 1);
            var mappedParam = gridMappedParam[ugenMode];
            var range = gridParamRanges[ugenMode];
            var mappedVal;

            if(heads[idx].notNil, {
                if(ugenMode == 8, {
                    mappedVal = position.linexp(0, 1, range[0], range[1]);
                }, {
                    mappedVal = position.linlin(0, 1, range[0], range[1]);
                });
                heads[idx].set(mappedParam, mappedVal);
            });
        });

        this.addCommand("head_volume", "if", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            var val = msg[2].asFloat;
            headParams[idx][\amp] = val;
            if(heads[idx].notNil, { heads[idx].set(\amp, val) });
        });

        this.addCommand("head_pan", "if", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            var val = msg[2].asFloat;
            headParams[idx][\pan] = val;
            if(heads[idx].notNil, { heads[idx].set(\pan, val) });
        });

        this.addCommand("buf_load", "s", { arg msg;
            var path = msg[1].asString;
            heads.do({ arg synth, i;
                if(synth.notNil, { synth.set(\gate, 0); heads[i] = nil });
            });
            Buffer.read(context.server, path, action: { arg newBuf;
                buffer.free;
                buffer = newBuf;
                this.sendWaveform();
            });
        });

        this.addCommand("rec_start", "", { arg msg;
            if(recSynth.notNil, { recSynth.free });
            recSynth = Synth(\graindr_rec, [\bufnum, buffer.bufnum], context.server);
        });

        this.addCommand("rec_stop", "", { arg msg;
            if(recSynth.notNil, {
                recSynth.set(\gate, 0);
                recSynth = nil;
                AppClock.sched(0.1, { this.sendWaveform(); nil });
            });
        });

        // Per-UGen param commands
        params.keysDo({ arg key;
            this.addCommand(key.asString, "f", { arg msg;
                var val = msg[1].asFloat;
                var synthArg;
                params[key] = val;
                synthArg = key.asString;
                synthArg = synthArg[(synthArg.indexOf($_) + 1)..].asSymbol;
                heads.do({ arg synth;
                    if(synth.notNil, { synth.set(synthArg, val) });
                });
            });
        });
    }

    sendWaveform {
        buffer.loadToFloatArray(action: { arg data;
            var numFrames = data.size div: 2;
            var segSize = (numFrames / 128).asInteger.max(1);
            var waveData = Array.new(256);

            128.do({ arg i;
                var startIdx = i * segSize * 2;
                var minVal = 1.0, maxVal = -1.0;

                segSize.do({ arg j;
                    var idx = startIdx + (j * 2);
                    if(idx < data.size, {
                        var samp = (data[idx] + data[idx + 1]) * 0.5;
                        if(samp < minVal, { minVal = samp });
                        if(samp > maxVal, { maxVal = samp });
                    });
                });

                waveData = waveData.add(minVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
                waveData = waveData.add(maxVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
            });

            context.server.addr.sendMsg("/graindr/waveform", *waveData);
        });
    }

    free {
        heads.do({ arg synth; if(synth.notNil, { synth.free }) });
        if(recSynth.notNil, { recSynth.free });
        buffer.free;
    }
}
