#include "audio_output_test.h"

#include <audioclient.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <thread>

namespace {

using Microsoft::WRL::ComPtr;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) return {};
  std::wstring converted(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), converted.data(),
                          length) != length) {
    return {};
  }
  return converted;
}

bool IsFloatFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
  if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
      format->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    return false;
  }
  const auto* extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
  return IsEqualGUID(extensible->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
}

bool IsPcmFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_PCM) return true;
  if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
      format->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    return false;
  }
  const auto* extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
  return IsEqualGUID(extensible->SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
}

void WriteSample(BYTE* destination, const WAVEFORMATEX* format, float sample) {
  if (IsFloatFormat(format) && format->wBitsPerSample == 32) {
    std::memcpy(destination, &sample, sizeof(sample));
    return;
  }
  if (!IsPcmFormat(format)) return;

  const float limited = std::clamp(sample, -1.0f, 1.0f);
  if (format->wBitsPerSample == 16) {
    const auto value = static_cast<int16_t>(limited * 32767.0f);
    std::memcpy(destination, &value, sizeof(value));
  } else if (format->wBitsPerSample == 24) {
    const auto value = static_cast<int32_t>(limited * 8388607.0f);
    destination[0] = static_cast<BYTE>(value & 0xff);
    destination[1] = static_cast<BYTE>((value >> 8) & 0xff);
    destination[2] = static_cast<BYTE>((value >> 16) & 0xff);
  } else if (format->wBitsPerSample == 32) {
    const auto value = static_cast<int32_t>(limited * 2147483647.0f);
    std::memcpy(destination, &value, sizeof(value));
  }
}

void FillTone(BYTE* buffer, UINT32 frames, UINT32 start_frame,
              UINT32 total_frames, const WAVEFORMATEX* format) {
  std::memset(buffer, 0, static_cast<size_t>(frames) * format->nBlockAlign);
  const UINT32 bytes_per_sample = format->wBitsPerSample / 8;
  constexpr double kPi = 3.14159265358979323846;
  for (UINT32 frame = 0; frame < frames; ++frame) {
    const UINT32 absolute_frame = start_frame + frame;
    if (absolute_frame >= total_frames) break;
    const double progress = static_cast<double>(absolute_frame) / total_frames;
    const double frequency = 440.0 + 220.0 * progress;
    const double envelope = std::sin(kPi * progress);
    const float sample = static_cast<float>(
        std::sin(2.0 * kPi * frequency * absolute_frame /
                 format->nSamplesPerSec) *
        envelope * 0.25);
    BYTE* frame_data = buffer + static_cast<size_t>(frame) * format->nBlockAlign;
    for (WORD channel = 0; channel < format->nChannels; ++channel) {
      WriteSample(frame_data + channel * bytes_per_sample, format, sample);
    }
  }
}

}  // namespace

bool PlayAudioOutputTestTone(const std::string& device_id) {
  const std::wstring wide_device_id = Utf8ToWide(device_id);
  if (wide_device_id.empty()) return false;

  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool uninitialize_com = SUCCEEDED(com_result);
  if (FAILED(com_result) && com_result != RPC_E_CHANGED_MODE) return false;

  bool played = false;
  WAVEFORMATEX* format = nullptr;
  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> client;
  ComPtr<IAudioRenderClient> renderer;

  HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                    CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (SUCCEEDED(result)) {
    result = enumerator->GetDevice(wide_device_id.c_str(), &device);
  }
  if (SUCCEEDED(result)) {
    result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void**>(client.GetAddressOf()));
  }
  if (SUCCEEDED(result)) result = client->GetMixFormat(&format);
  if (SUCCEEDED(result)) {
    if (format == nullptr || (!IsFloatFormat(format) && !IsPcmFormat(format))) {
      result = E_FAIL;
    } else {
      result = client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 1000000, 0,
                                  format, nullptr);
    }
  }

  UINT32 buffer_frames = 0;
  if (SUCCEEDED(result)) result = client->GetBufferSize(&buffer_frames);
  if (SUCCEEDED(result)) {
    result = client->GetService(IID_PPV_ARGS(&renderer));
  }
  if (SUCCEEDED(result)) result = client->Start();

  if (SUCCEEDED(result)) {
    const UINT32 total_frames =
        static_cast<UINT32>(format->nSamplesPerSec * 7 / 10);
    UINT32 generated = 0;
    while (generated < total_frames && SUCCEEDED(result)) {
      UINT32 padding = 0;
      result = client->GetCurrentPadding(&padding);
      if (FAILED(result)) break;
      const UINT32 available = buffer_frames - padding;
      if (available == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        continue;
      }
      BYTE* buffer = nullptr;
      result = renderer->GetBuffer(available, &buffer);
      if (FAILED(result)) break;
      FillTone(buffer, available, generated, total_frames, format);
      result = renderer->ReleaseBuffer(available, 0);
      generated += std::min(available, total_frames - generated);
    }
    if (SUCCEEDED(result)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(120));
      played = true;
    }
    client->Stop();
  }

  if (format != nullptr) CoTaskMemFree(format);
  if (uninitialize_com) CoUninitialize();
  return played;
}
