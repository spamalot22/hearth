#ifndef RUNNER_AUDIO_OUTPUT_TEST_H_
#define RUNNER_AUDIO_OUTPUT_TEST_H_

#include <string>

// Plays a short tone through one Windows audio endpoint. The endpoint ID is the
// same MMDevice ID exposed by flutter_webrtc's audiooutput enumeration.
bool PlayAudioOutputTestTone(const std::string& device_id);

#endif  // RUNNER_AUDIO_OUTPUT_TEST_H_
