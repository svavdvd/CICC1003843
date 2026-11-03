#ifndef C5MB_PURE_CNN_RUNTIME_HPP
#define C5MB_PURE_CNN_RUNTIME_HPP

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "opencv2/core.hpp"

namespace c5mb {

struct PureCnnDetection {
  int label_id;
  float score;
  float left;
  float top;
  float right;
  float bottom;
};

struct PureCnnResult {
  std::vector<PureCnnDetection> detections;
  double preprocess_ms;
  double accelerator_ms;
  double postprocess_ms;
  uint64_t accelerator_cycles;
  unsigned activation_bank;
};

class PureCnnRuntime {
 public:
  struct Settings {
    std::string model_directory;
    std::string cma_device;
    std::string channel_order_override;
    uint64_t register_base;
    uint32_t timeout_ms;
    uint32_t poll_interval_us;
    float score_threshold;

    Settings();
  };

  explicit PureCnnRuntime(const Settings& settings);
  ~PureCnnRuntime();

  PureCnnResult Run(const cv::Mat& decoded_bgr);
  void Reset();

  const std::vector<std::string>& labels() const;
  std::string model_format() const;
  std::string channel_order() const;
  uint32_t core_id() const;
  uint32_t core_version() const;
  uint32_t completed_jobs() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;

  PureCnnRuntime(const PureCnnRuntime&);
  PureCnnRuntime& operator=(const PureCnnRuntime&);
};

}  // namespace c5mb

#endif  // C5MB_PURE_CNN_RUNTIME_HPP
