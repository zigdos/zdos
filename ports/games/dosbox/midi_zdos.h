/* DOSBox's MIDI device on ZDOS (mididevice=zdos, the default there):
   MIDI.ZDL's synthesizer, rendering into a mixer channel of its own.
   midiconfig: a SoundFont 2's path; empty: %MIDISYNTH% (FM or the
   SoundFont). The MPU-401's bytes and the mixer's calls come on the
   emulation's thread: no lock. */
#include "mixer.h"
// midi.cpp's state is "midi" too: the type renamed (C functions,
// so the name isn't linked)
#define midi zdos_midi
#include <midi.h>
#undef midi

class MidiHandler_zdos : public MidiHandler {
private:
	enum { RATE = 44100, FRAMES = 1024 };
	static zdos_midi *synth;
	static MixerChannel *chan;
	static Bit16s buf[2 * FRAMES];

	static void Render(Bitu len) {
		while (len > 0) {
			Bitu n = len < FRAMES ? len : FRAMES;
			midi_render(synth, buf, (int)n, 0);
			chan->AddSamples_s16(n, buf);
			len -= n;
		}
	}

	// GM System On and GS Reset: every channel as at the start
	static bool IsReset(const Bit8u *s, Bitu len) {
		static const Bit8u gm[] = {0xf0, 0x7e, 0x7f, 0x09, 0x01, 0xf7};
		static const Bit8u gs[] = {0xf0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7f, 0x00, 0x41, 0xf7};
		return (len == sizeof(gm) && !memcmp(s, gm, len)) || (len == sizeof(gs) && !memcmp(s, gs, len));
	}

public:
	MidiHandler_zdos() : MidiHandler() {};
	const char *GetName(void) { return "zdos"; };

	bool Open(const char *conf) {
		if (synth) return false;
		synth = conf && conf[0] ? midi_open(MIDI_SF2, conf) : midi_open(MIDI_DEFAULT, NULL);
		if (!synth) return false;
		if (midi_set_output(synth, RATE, 2) != 0) {
			midi_close(synth);
			synth = 0;
			return false;
		}
		chan = MIXER_AddChannel(Render, RATE, "MIDI");
		chan->Enable(false); // until the first message
		LOG_MSG("MIDI: MIDI.ZDL, %s", midi_synth(synth) == MIDI_FM ? "FM" : "SoundFont");
		return true;
	};

	void Close(void) {
		if (!synth) return;
		chan->Enable(false);
		MIXER_DelChannel(chan);
		chan = 0;
		midi_close(synth);
		synth = 0;
	};

	void PlayMsg(Bit8u *msg) {
		chan->Enable(true);
		midi_write(synth, msg, (int)MIDI_evt_len[*msg]);
	};

	void PlaySysex(Bit8u *sysex, Bitu len) {
		if (IsReset(sysex, len)) midi_reset(synth);
	};
};

zdos_midi *MidiHandler_zdos::synth = 0;
MixerChannel *MidiHandler_zdos::chan = 0;
Bit16s MidiHandler_zdos::buf[2 * FRAMES];

MidiHandler_zdos Midi_zdos;
