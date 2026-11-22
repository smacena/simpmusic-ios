#ifndef SIMP_DSP_H
#define SIMP_DSP_H
#include <MediaToolbox/MediaToolbox.h>

/* SimpMusic real-time audio chain (equalizer, normalization, echo, reverb, limiter) in C. */
void simp_eq_set(const double* gainsDb, int count, double preampDb);
void simp_normalize_set(float gain);
void simp_echo_set(const double* delaysMs, const float* decays, int n, float inGain, float outGain);
int simp_reverb_set(const float* irL, const float* irR, int len, float mix);
void simp_process_channel(int slot, int ch, float* data, int frames);
MTAudioProcessingTapRef simp_create_tap(int slot) CF_RETURNS_RETAINED;
double simp_sample_rate(void);
float simp_level(void);
void simp_pitch_set(float ratio);
void simp_dj_set(int slot, int type, float cutoffHz);

#endif
