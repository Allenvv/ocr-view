#ifndef PM25_REC_MODEL_H_
#define PM25_REC_MODEL_H_

#include <onnxruntime_cxx_api.h>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

struct Pm25Recognition {
  std::string text;
  double confidence;
};

class Pm25RecModel {
 public:
  explicit Pm25RecModel(const std::filesystem::path& model_dir);
  Pm25Recognition Run(const std::vector<uint8_t>& rgba, uint32_t frame_width,
                      uint32_t frame_height, double l, double t, double r, double b);
  const std::string& version() const { return version_; }
  const std::string& sha256() const { return sha256_; }
 private:
  Ort::Env env_;
  Ort::Session session_{nullptr};
  std::string input_, output_, version_, sha256_;
  int width_{}, height_{};
  double mean_{.5}, scale_{.5};
  std::vector<float> pixels_;
};
#endif
