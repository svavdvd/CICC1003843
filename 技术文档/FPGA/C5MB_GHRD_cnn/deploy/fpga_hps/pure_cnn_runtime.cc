#include "pure_cnn_runtime.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <limits>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

#include "json.hpp"
#include "opencv2/imgproc.hpp"

namespace c5mb {
namespace {

using json = nlohmann::json;

const uint32_t kExpectedCoreId = 0x50434E4EU;
const uint32_t kExpectedCoreVersion = 0x00010000U;
const std::size_t kRegisterSpan = 0x400U;
const std::size_t kAlignment = 64U;
const unsigned int kCmaMagic = ('C' + 'M' + 'A' + 'B') / 4;

std::string SystemError(const std::string& operation, int error_number) {
  return operation + " failed: " + std::strerror(error_number);
}

std::size_t AlignUp(std::size_t value, std::size_t alignment) {
  if (alignment == 0U || value >
      std::numeric_limits<std::size_t>::max() - (alignment - 1U)) {
    throw std::runtime_error("size alignment overflow");
  }
  return (value + alignment - 1U) / alignment * alignment;
}

std::string JoinPath(const std::string& directory, const std::string& name) {
  if (directory.empty()) {
    return name;
  }
  const char last = directory[directory.size() - 1U];
  return directory + (last == '/' ? "" : "/") + name;
}

std::vector<uint8_t> ReadBinary(const std::string& path) {
  std::ifstream stream(path.c_str(), std::ios::binary | std::ios::ate);
  if (!stream) {
    throw std::runtime_error("cannot open binary file: " + path);
  }
  const std::streamoff end = stream.tellg();
  if (end < 0 || static_cast<uint64_t>(end) >
                     std::numeric_limits<std::size_t>::max()) {
    throw std::runtime_error("invalid binary file size: " + path);
  }
  std::vector<uint8_t> bytes(static_cast<std::size_t>(end));
  stream.seekg(0, std::ios::beg);
  if (!bytes.empty()) {
    stream.read(reinterpret_cast<char*>(&bytes[0]), bytes.size());
  }
  if (!stream) {
    throw std::runtime_error("cannot read binary file: " + path);
  }
  return bytes;
}

json ReadJson(const std::string& path) {
  std::ifstream stream(path.c_str());
  if (!stream) {
    throw std::runtime_error("cannot open model manifest: " + path);
  }
  json value;
  stream >> value;
  return value;
}

uint32_t CheckedU32(uint64_t value, const std::string& field) {
  if (value > std::numeric_limits<uint32_t>::max()) {
    throw std::runtime_error(field + " exceeds the PL 32-bit address range");
  }
  return static_cast<uint32_t>(value);
}

int8_t QuantizeInt8(float value) {
  long rounded = std::lround(value);
  if (rounded < -127L) {
    rounded = -127L;
  } else if (rounded > 127L) {
    rounded = 127L;
  }
  return static_cast<int8_t>(rounded);
}

float Clamp(float value, float minimum, float maximum) {
  return std::max(minimum, std::min(value, maximum));
}

struct CmaBlock {
  void* addr;
  void* virt;
  unsigned long phys;
  std::size_t size;
};

class CmaMemory {
 public:
  CmaMemory(const std::string& device, std::size_t requested_bytes)
      : fd_(-1), mapping_(MAP_FAILED) {
    std::memset(&block_, 0, sizeof(block_));
    const long page_size_value = sysconf(_SC_PAGESIZE);
    if (page_size_value <= 0) {
      throw std::runtime_error("sysconf(_SC_PAGESIZE) failed");
    }
    block_.size = AlignUp(requested_bytes,
                          static_cast<std::size_t>(page_size_value));
    fd_ = open(device.c_str(), O_RDWR | O_SYNC);
    if (fd_ < 0) {
      throw std::runtime_error(SystemError("open " + device, errno));
    }
    if (ioctl(fd_, _IO(kCmaMagic, 0x00), &block_) != 0) {
      const int saved_errno = errno;
      close(fd_);
      fd_ = -1;
      throw std::runtime_error(SystemError("CMA allocate", saved_errno));
    }
    mapping_ = mmap(NULL, block_.size, PROT_READ | PROT_WRITE, MAP_SHARED,
                    fd_, static_cast<off_t>(block_.phys));
    if (mapping_ == MAP_FAILED) {
      const int saved_errno = errno;
      ioctl(fd_, _IO(kCmaMagic, 0x01), &block_);
      close(fd_);
      fd_ = -1;
      throw std::runtime_error(SystemError("mmap CMA memory", saved_errno));
    }
    block_.addr = mapping_;
  }

  ~CmaMemory() {
    if (mapping_ != MAP_FAILED) {
      munmap(mapping_, block_.size);
      mapping_ = MAP_FAILED;
    }
    if (fd_ >= 0) {
      ioctl(fd_, _IO(kCmaMagic, 0x01), &block_);
      close(fd_);
      fd_ = -1;
    }
  }

  uint8_t* data() { return static_cast<uint8_t*>(mapping_); }
  const uint8_t* data() const { return static_cast<const uint8_t*>(mapping_); }
  uint64_t physical() const { return static_cast<uint64_t>(block_.phys); }
  std::size_t size() const { return block_.size; }

 private:
  CmaMemory(const CmaMemory&);
  CmaMemory& operator=(const CmaMemory&);

  int fd_;
  void* mapping_;
  CmaBlock block_;
};

class RegisterBank {
 public:
  explicit RegisterBank(uint64_t physical_base)
      : fd_(-1), mapping_(MAP_FAILED), mapping_bytes_(0), registers_(NULL) {
    const long page_size_value = sysconf(_SC_PAGESIZE);
    if (page_size_value <= 0) {
      throw std::runtime_error("sysconf(_SC_PAGESIZE) failed");
    }
    const std::size_t page_size = static_cast<std::size_t>(page_size_value);
    const uint64_t page_mask = static_cast<uint64_t>(page_size - 1U);
    const uint64_t page_base = physical_base & ~page_mask;
    const std::size_t page_offset =
        static_cast<std::size_t>(physical_base - page_base);
    mapping_bytes_ = page_offset + kRegisterSpan;
    fd_ = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_ < 0) {
      throw std::runtime_error(SystemError("open /dev/mem", errno));
    }
    mapping_ = mmap(NULL, mapping_bytes_, PROT_READ | PROT_WRITE, MAP_SHARED,
                    fd_, static_cast<off_t>(page_base));
    if (mapping_ == MAP_FAILED) {
      const int saved_errno = errno;
      close(fd_);
      fd_ = -1;
      throw std::runtime_error(SystemError("mmap pure CNN registers",
                                           saved_errno));
    }
    registers_ = reinterpret_cast<volatile uint32_t*>(
        static_cast<uint8_t*>(mapping_) + page_offset);
  }

  ~RegisterBank() {
    if (mapping_ != MAP_FAILED) {
      munmap(mapping_, mapping_bytes_);
    }
    if (fd_ >= 0) {
      close(fd_);
    }
  }

  uint32_t Read(uint32_t word) const {
    const uint32_t value = registers_[word];
    __sync_synchronize();
    return value;
  }

  void Write(uint32_t word, uint32_t value) {
    registers_[word] = value;
    __sync_synchronize();
  }

 private:
  RegisterBank(const RegisterBank&);
  RegisterBank& operator=(const RegisterBank&);

  int fd_;
  void* mapping_;
  std::size_t mapping_bytes_;
  volatile uint32_t* registers_;
};

struct Layer {
  std::string name;
  std::string op;
  uint32_t input_width;
  uint32_t input_height;
  uint32_t input_blocks;
  uint32_t output_width;
  uint32_t output_height;
  uint32_t output_blocks;
  uint32_t kernel;
  uint32_t stride;
  uint32_t padding;
  uint32_t activation_code;
  std::size_t input_offset;
  std::size_t output_offset;
  std::size_t weight_offset;
  std::size_t weight_bytes;
  std::size_t bias_offset;
  std::size_t bias_bytes;
  std::size_t quant_offset;
  std::size_t quant_bytes;
  float output_scale;
};

struct Head {
  int index;
  uint32_t width;
  uint32_t height;
  uint32_t anchors;
  uint32_t classes;
  std::size_t box_layer;
  std::size_t score_layer;
  std::size_t prior_start;
  std::size_t prior_count;
  std::array<float, 4> variances;
};

struct Model {
  std::string format;
  std::string channel_order;
  uint32_t input_width;
  uint32_t input_height;
  std::size_t input_offset;
  float input_scale;
  std::array<float, 3> mean;
  std::array<float, 3> standard_deviation;
  std::vector<std::string> labels;
  std::vector<Layer> layers;
  std::vector<Head> heads;
  int background_label;
  float score_threshold;
  float nms_threshold;
  int nms_top_k;
  int keep_top_k;
  std::size_t parameter_bytes;
  std::size_t prior_bytes;
  std::size_t arena_bytes;
};

std::size_t JsonSize(const json& value, const char* name) {
  return value.at(name).get<std::size_t>();
}

uint32_t JsonU32(const json& value, const char* name) {
  const uint64_t result = value.at(name).get<uint64_t>();
  if (result > std::numeric_limits<uint32_t>::max()) {
    throw std::runtime_error(std::string("manifest value too large: ") + name);
  }
  return static_cast<uint32_t>(result);
}

Model ParseModel(const json& root) {
  Model model;
  model.format = root.at("format").get<std::string>();
  if (model.format != "c5mb-pure-cnn-v1") {
    throw std::runtime_error("unsupported model package format: " +
                             model.format);
  }

  const json& input = root.at("input");
  if (input.at("layout").get<std::string>() != "NHWC8") {
    throw std::runtime_error("PL accelerator requires NHWC8 input");
  }
  model.channel_order = input.at("channel_order").get<std::string>();
  model.input_width = JsonU32(input, "width");
  model.input_height = JsonU32(input, "height");
  model.input_offset = JsonSize(input, "offset");
  model.input_scale = input.at("scale").get<float>();
  if (!(model.input_scale > 0.0f) || !std::isfinite(model.input_scale)) {
    throw std::runtime_error("invalid input quantization scale");
  }
  for (std::size_t index = 0; index < 3U; ++index) {
    model.mean[index] = input.at("mean").at(index).get<float>();
    model.standard_deviation[index] =
        input.at("std").at(index).get<float>();
    if (model.standard_deviation[index] == 0.0f ||
        !std::isfinite(model.standard_deviation[index])) {
      throw std::runtime_error("invalid input standard deviation");
    }
  }
  model.labels = root.at("labels").get<std::vector<std::string> >();

  const json& memory = root.at("memory");
  model.parameter_bytes = JsonSize(memory, "parameter_bytes");
  model.prior_bytes = JsonSize(memory, "prior_bytes");
  model.arena_bytes = JsonSize(memory, "activation_arena_bytes");
  if (memory.at("activation_banks").get<unsigned>() != 2U) {
    throw std::runtime_error("model package must declare two activation banks");
  }

  const json& layer_values = root.at("layers");
  for (std::size_t index = 0; index < layer_values.size(); ++index) {
    const json& item = layer_values.at(index);
    if (item.at("index").get<std::size_t>() != index) {
      throw std::runtime_error("model layers are not in execution order");
    }
    Layer layer;
    layer.name = item.at("name").get<std::string>();
    layer.op = item.at("op").get<std::string>();
    layer.input_width = JsonU32(item, "input_width");
    layer.input_height = JsonU32(item, "input_height");
    layer.input_blocks = JsonU32(item, "input_blocks");
    layer.output_width = JsonU32(item, "output_width");
    layer.output_height = JsonU32(item, "output_height");
    layer.output_blocks = JsonU32(item, "output_blocks");
    layer.kernel = JsonU32(item, "kernel");
    layer.stride = JsonU32(item, "stride");
    layer.padding = JsonU32(item, "padding");
    layer.activation_code = JsonU32(item, "activation_code");
    layer.input_offset = JsonSize(item, "input_offset");
    layer.output_offset = JsonSize(item, "output_offset");
    layer.weight_offset = JsonSize(item, "weight_offset");
    layer.weight_bytes = JsonSize(item, "weight_bytes");
    layer.bias_offset = JsonSize(item, "bias_offset");
    layer.bias_bytes = JsonSize(item, "bias_bytes");
    layer.quant_offset = JsonSize(item, "quant_offset");
    layer.quant_bytes = JsonSize(item, "quant_bytes");
    layer.output_scale = item.at("output_scale").get<float>();
    model.layers.push_back(layer);
  }

  const json& head_values = root.at("heads");
  for (std::size_t index = 0; index < head_values.size(); ++index) {
    const json& item = head_values.at(index);
    Head head;
    head.index = item.at("index").get<int>();
    head.width = JsonU32(item, "width");
    head.height = JsonU32(item, "height");
    head.anchors = JsonU32(item, "anchors");
    head.classes = JsonU32(item, "classes_with_background");
    head.box_layer = JsonSize(item, "box_layer");
    head.score_layer = JsonSize(item, "score_layer");
    head.prior_start = JsonSize(item, "prior_start");
    head.prior_count = JsonSize(item, "prior_count");
    for (std::size_t component = 0; component < 4U; ++component) {
      head.variances[component] =
          item.at("variances").at(component).get<float>();
    }
    model.heads.push_back(head);
  }

  const json& nms = root.at("nms");
  model.background_label = nms.at("background_label").get<int>();
  model.score_threshold = nms.at("score_threshold").get<float>();
  model.nms_threshold = nms.at("nms_threshold").get<float>();
  model.nms_top_k = nms.at("nms_top_k").get<int>();
  model.keep_top_k = nms.at("keep_top_k").get<int>();
  return model;
}

std::size_t TensorBytes(uint32_t width, uint32_t height, uint32_t blocks) {
  const uint64_t bytes = static_cast<uint64_t>(width) * height * blocks * 8U;
  if (bytes > std::numeric_limits<std::size_t>::max()) {
    throw std::runtime_error("tensor size overflow");
  }
  return static_cast<std::size_t>(bytes);
}

void ValidateModel(const Model& model,
                   std::size_t parameter_file_bytes,
                   std::size_t prior_file_bytes) {
  if (model.layers.empty() || model.heads.empty()) {
    throw std::runtime_error("model package has no layers or SSD heads");
  }
  if (model.parameter_bytes != parameter_file_bytes ||
      model.prior_bytes != prior_file_bytes) {
    throw std::runtime_error("model package file size does not match manifest");
  }
  if (model.input_width == 0U || model.input_height == 0U ||
      model.input_width > 1023U || model.input_height > 1023U) {
    throw std::runtime_error("input dimensions exceed PL descriptor fields");
  }
  if (model.channel_order != "BGR" && model.channel_order != "RGB") {
    throw std::runtime_error("channel_order must be BGR or RGB");
  }
  const std::size_t input_bytes =
      TensorBytes(model.input_width, model.input_height, 1U);
  if (model.input_offset > model.arena_bytes ||
      input_bytes > model.arena_bytes - model.input_offset) {
    throw std::runtime_error("input tensor is outside activation arena");
  }

  for (std::size_t index = 0; index < model.layers.size(); ++index) {
    const Layer& layer = model.layers[index];
    if (layer.op != "conv" && layer.op != "depthwise") {
      throw std::runtime_error("unsupported PL layer operation: " + layer.op);
    }
    if (layer.input_width > 1023U || layer.input_height > 1023U ||
        layer.input_blocks > 1023U || layer.output_width > 1023U ||
        layer.output_height > 1023U || layer.output_blocks > 1023U ||
        layer.input_blocks == 0U || layer.output_blocks == 0U) {
      throw std::runtime_error("layer dimensions exceed PL descriptor fields");
    }
    const std::size_t input_size = TensorBytes(
        layer.input_width, layer.input_height, layer.input_blocks);
    const std::size_t output_size = TensorBytes(
        layer.output_width, layer.output_height, layer.output_blocks);
    if (layer.input_offset > model.arena_bytes ||
        input_size > model.arena_bytes - layer.input_offset ||
        layer.output_offset > model.arena_bytes ||
        output_size > model.arena_bytes - layer.output_offset) {
      throw std::runtime_error("layer tensor is outside activation arena: " +
                               layer.name);
    }
    const std::size_t offsets[] = {
        layer.weight_offset, layer.bias_offset, layer.quant_offset};
    const std::size_t sizes[] = {
        layer.weight_bytes, layer.bias_bytes, layer.quant_bytes};
    for (std::size_t part = 0; part < 3U; ++part) {
      if ((offsets[part] & 7U) != 0U ||
          offsets[part] > model.parameter_bytes ||
          sizes[part] > model.parameter_bytes - offsets[part]) {
        throw std::runtime_error("layer parameter range is invalid: " +
                                 layer.name);
      }
    }
    if (!(layer.output_scale > 0.0f) ||
        !std::isfinite(layer.output_scale)) {
      throw std::runtime_error("invalid output scale: " + layer.name);
    }
  }

  std::size_t maximum_prior = 0U;
  for (std::size_t index = 0; index < model.heads.size(); ++index) {
    const Head& head = model.heads[index];

    if (head.box_layer >= model.layers.size() ||
        head.score_layer >= model.layers.size() || head.anchors == 0U ||
        head.classes != model.labels.size() + 1U) {
      throw std::runtime_error("invalid SSD head metadata");
    }
    const std::size_t expected =
        static_cast<std::size_t>(head.width) * head.height * head.anchors;
    if (head.prior_count != expected) {
      throw std::runtime_error("SSD head prior count mismatch");
    }
    maximum_prior = std::max(maximum_prior,
                             head.prior_start + head.prior_count);
  }
  if (model.background_label < 0 ||
      model.heads.empty() ||
      model.background_label >= static_cast<int>(model.heads[0].classes)) {
    throw std::runtime_error("background label is outside class channels");
  }
  if (maximum_prior * 4U * sizeof(float) != model.prior_bytes) {
    throw std::runtime_error("prior box file does not match SSD heads");
  }
}

float IntersectionOverUnion(const PureCnnDetection& left,
                            const PureCnnDetection& right) {
  const float intersection_left = std::max(left.left, right.left);
  const float intersection_top = std::max(left.top, right.top);
  const float intersection_right = std::min(left.right, right.right);
  const float intersection_bottom = std::min(left.bottom, right.bottom);
  const float width = std::max(0.0f, intersection_right - intersection_left);
  const float height = std::max(0.0f, intersection_bottom - intersection_top);
  const float intersection = width * height;
  const float left_area = std::max(0.0f, left.right - left.left) *
                          std::max(0.0f, left.bottom - left.top);
  const float right_area = std::max(0.0f, right.right - right.left) *
                           std::max(0.0f, right.bottom - right.top);
  const float union_area = left_area + right_area - intersection;
  return union_area > 0.0f ? intersection / union_area : 0.0f;
}

bool HigherScore(const PureCnnDetection& left,
                 const PureCnnDetection& right) {
  return left.score > right.score;
}

int LabelIndex(int class_index, int background_index) {
  if (class_index == background_index) {
    return -1;
  }
  return class_index < background_index ? class_index : class_index - 1;
}

}  // namespace

class PureCnnRuntime::Impl {
 public:
  explicit Impl(const Settings& settings)
      : settings_(settings),
        model_(ParseModel(ReadJson(
            JoinPath(settings.model_directory, "model.json")))),
        parameters_(ReadBinary(
            JoinPath(settings.model_directory, "parameters.bin"))),
        prior_bytes_(ReadBinary(
            JoinPath(settings.model_directory, "priors.bin"))),
        parameter_span_(AlignUp(model_.parameter_bytes, kAlignment)),
        cma_(settings.cma_device,
             parameter_span_ + model_.arena_bytes * 2U),
        registers_(settings.register_base),
        sequence_(1U), next_bank_(0U) {
    ValidateModel(model_, parameters_.size(), prior_bytes_.size());
    if (!settings_.channel_order_override.empty()) {
      if (settings_.channel_order_override != "BGR" &&
          settings_.channel_order_override != "RGB") {
        throw std::runtime_error("channel_order_override must be BGR or RGB");
      }
      model_.channel_order = settings_.channel_order_override;
    }
    if (!(settings_.score_threshold >= 0.0f) ||
        settings_.score_threshold > 1.0f) {
      throw std::runtime_error("score threshold must be in [0,1]");
    }
    if (settings_.timeout_ms == 0U || settings_.poll_interval_us == 0U) {
      throw std::runtime_error("timeout and poll interval must be non-zero");
    }
    if (cma_.physical() + cma_.size() - 1U >
        std::numeric_limits<uint32_t>::max()) {
      throw std::runtime_error("CMA block is outside FPGA 32-bit address space");
    }
    std::memcpy(cma_.data(), &parameters_[0], parameters_.size());
    std::memset(cma_.data() + parameter_span_, 0,
                model_.arena_bytes * 2U);
    priors_.resize(prior_bytes_.size() / sizeof(float));
    if (!prior_bytes_.empty()) {
      std::memcpy(&priors_[0], &prior_bytes_[0], prior_bytes_.size());
    }
    if (registers_.Read(0x00U) != kExpectedCoreId) {
      throw std::runtime_error("pure CNN PL core ID mismatch");
    }
    if (registers_.Read(0x01U) != kExpectedCoreVersion) {
      throw std::runtime_error("pure CNN PL core version mismatch");
    }
    ResetUnlocked();
  }

  PureCnnResult Run(const cv::Mat& decoded_bgr) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (decoded_bgr.empty()) {
      throw std::runtime_error("decoded image is empty");
    }
    const unsigned bank = next_bank_;
    uint8_t* arena = ArenaVirtual(bank);
    const uint64_t arena_physical = ArenaPhysical(bank);

    const std::chrono::steady_clock::time_point preprocess_start =
        std::chrono::steady_clock::now();
    EncodeInput(decoded_bgr, arena);
    const std::chrono::steady_clock::time_point preprocess_end =
        std::chrono::steady_clock::now();

    uint64_t cycles = 0U;
    const std::chrono::steady_clock::time_point accelerator_start =
        std::chrono::steady_clock::now();
    try {
      cycles = ExecuteLayers(arena_physical);
    } catch (...) {
      ResetUnlocked();
      throw;
    }
    const std::chrono::steady_clock::time_point accelerator_end =
        std::chrono::steady_clock::now();

    const std::chrono::steady_clock::time_point postprocess_start =
        std::chrono::steady_clock::now();
    PureCnnResult result;
    result.detections = DecodeDetections(arena);
    const std::chrono::steady_clock::time_point postprocess_end =
        std::chrono::steady_clock::now();
    result.preprocess_ms = Milliseconds(preprocess_start, preprocess_end);
    result.accelerator_ms = Milliseconds(accelerator_start, accelerator_end);
    result.postprocess_ms = Milliseconds(postprocess_start, postprocess_end);
    result.accelerator_cycles = cycles;
    result.activation_bank = bank;
    next_bank_ ^= 1U;
    return result;
  }

  void Reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    ResetUnlocked();
  }

  const std::vector<std::string>& labels() const { return model_.labels; }
  const std::string& format() const { return model_.format; }
  const std::string& channel_order() const { return model_.channel_order; }
  uint32_t core_id() const { return registers_.Read(0x00U); }
  uint32_t core_version() const { return registers_.Read(0x01U); }
  uint32_t completed_jobs() const { return registers_.Read(0x0AU); }

 private:
  static double Milliseconds(
      const std::chrono::steady_clock::time_point& start,
      const std::chrono::steady_clock::time_point& end) {
    return std::chrono::duration_cast<std::chrono::microseconds>(end - start)
               .count() /
           1000.0;
  }

  uint8_t* ArenaVirtual(unsigned bank) {
    return cma_.data() + parameter_span_ + model_.arena_bytes * bank;
  }

  uint64_t ArenaPhysical(unsigned bank) const {
    return cma_.physical() + parameter_span_ + model_.arena_bytes * bank;
  }

  void ResetUnlocked() {
    registers_.Write(0x02U, 0x00000001U);
    usleep(10U);
    registers_.Write(0x02U, 0x00000000U);
    usleep(10U);
    const uint32_t status = registers_.Read(0x03U);
    if ((status & 0x41U) != 0U) {
      throw std::runtime_error("pure CNN core did not reset to idle");
    }
  }

  void EncodeInput(const cv::Mat& decoded_bgr, uint8_t* arena) const {
    cv::Mat color;
    if (decoded_bgr.channels() == 1) {
      cv::cvtColor(decoded_bgr, color, cv::COLOR_GRAY2BGR);
    } else if (decoded_bgr.channels() == 3) {
      color = decoded_bgr;
    } else if (decoded_bgr.channels() == 4) {
      cv::cvtColor(decoded_bgr, color, cv::COLOR_BGRA2BGR);
    } else {
      throw std::runtime_error("unsupported decoded image channel count");
    }
    cv::Mat resized;
    cv::resize(color, resized,
               cv::Size(model_.input_width, model_.input_height),
               0.0, 0.0, cv::INTER_LINEAR);
    if (model_.channel_order == "RGB") {
      cv::cvtColor(resized, resized, cv::COLOR_BGR2RGB);
    }

    int8_t* output = reinterpret_cast<int8_t*>(arena + model_.input_offset);
    const std::size_t output_bytes =
        TensorBytes(model_.input_width, model_.input_height, 1U);
    std::memset(output, 0, output_bytes);
    for (uint32_t y = 0; y < model_.input_height; ++y) {
      const cv::Vec3b* row = resized.ptr<cv::Vec3b>(y);
      for (uint32_t x = 0; x < model_.input_width; ++x) {
        int8_t* pixel = output +
            (static_cast<std::size_t>(y) * model_.input_width + x) * 8U;
        for (std::size_t channel = 0; channel < 3U; ++channel) {
          const float normalized =
              (static_cast<float>(row[x][channel]) - model_.mean[channel]) /
              model_.standard_deviation[channel];
          pixel[channel] = QuantizeInt8(normalized / model_.input_scale);
        }
      }
    }
  }

  uint32_t LayerOperation(const Layer& layer) const {
    return layer.op == "conv" ? 0U : 1U;
  }

  uint32_t NextSequence() {
    if (sequence_ == 0U) {
      sequence_ = 1U;
    }
    const uint32_t result = sequence_++;
    if (sequence_ == 0U) {
      sequence_ = 1U;
    }
    return result;
  }

  void ProgramSlot(unsigned slot,
                   const Layer& layer,
                   uint64_t arena_physical,
                   uint32_t sequence) {
    const uint32_t base = slot == 0U ? 0x10U : 0x20U;
    const uint32_t input_address = CheckedU32(
        arena_physical + layer.input_offset, "activation input address");
    const uint32_t output_address = CheckedU32(
        arena_physical + layer.output_offset, "activation output address");
    const uint32_t parameter_address = CheckedU32(
        cma_.physical() + layer.weight_offset, "weight address");
    const uint32_t bias_address = CheckedU32(
        cma_.physical() + layer.bias_offset, "bias address");
    const uint32_t quant_address = CheckedU32(
        cma_.physical() + layer.quant_offset, "quant address");
    const uint32_t input_shape = layer.input_width |
        (layer.input_height << 10U) | (layer.input_blocks << 20U);
    const uint32_t output_shape = layer.output_width |
        (layer.output_height << 10U) | (layer.output_blocks << 20U);
    const uint32_t operation = LayerOperation(layer) |
        (layer.kernel << 4U) | (layer.stride << 8U) |
        (layer.padding << 12U) | (layer.activation_code << 16U);

    registers_.Write(base + 0U, input_address);
    registers_.Write(base + 1U, output_address);
    registers_.Write(base + 2U, parameter_address);
    registers_.Write(base + 3U, bias_address);
    registers_.Write(base + 4U, quant_address);
    registers_.Write(base + 5U, input_shape);
    registers_.Write(base + 6U, output_shape);
    registers_.Write(base + 7U, operation);
    registers_.Write(base + 8U, 0U);
    registers_.Write(base + 9U, sequence);
  }

  void SubmitSlot(unsigned slot, bool clear_done) {
    uint32_t command = 1U << slot;
    if (clear_done) {
      command |= 1U << (16U + slot);
    }
    registers_.Write(0x04U, command);
  }

  uint32_t WaitSlot(unsigned slot,
                    uint32_t expected_sequence,
                    const std::chrono::steady_clock::time_point& deadline) {
    const uint32_t done_mask = 1U << (4U + slot);
    for (;;) {
      const uint32_t status = registers_.Read(0x03U);
      if ((status & (1U << 6U)) != 0U) {
        std::ostringstream error;
        error << "pure CNN layer failed, code=0x" << std::hex
              << registers_.Read(0x07U) << ", status=0x" << status;
        throw std::runtime_error(error.str());
      }
      if ((status & done_mask) != 0U) {
        const uint32_t completed = registers_.Read(0x08U + slot);
        if (completed != expected_sequence) {
          throw std::runtime_error("pure CNN descriptor sequence mismatch");
        }
        return registers_.Read(0x06U);
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        std::ostringstream error;
        error << "pure CNN inference timeout, status=0x" << std::hex
              << status;
        throw std::runtime_error(error.str());
      }
      usleep(settings_.poll_interval_us);
    }
  }

  uint64_t ExecuteLayers(uint64_t arena_physical) {
    ResetUnlocked();
    const std::chrono::steady_clock::time_point deadline =
        std::chrono::steady_clock::now() +
        std::chrono::milliseconds(settings_.timeout_ms);
    std::array<uint32_t, 2> slot_sequence{{0U, 0U}};
    std::size_t next = 0U;

    if (next < model_.layers.size()) {
      slot_sequence[0] = NextSequence();
      ProgramSlot(0U, model_.layers[next++], arena_physical,
                  slot_sequence[0]);
    }
    if (next < model_.layers.size()) {
      slot_sequence[1] = NextSequence();
      ProgramSlot(1U, model_.layers[next++], arena_physical,
                  slot_sequence[1]);
    }
    registers_.Write(0x04U, next > 1U ? 0x00000003U : 0x00000001U);

    uint64_t cycles = 0U;
    for (std::size_t completed = 0U;
         completed < model_.layers.size(); ++completed) {
      const unsigned slot = static_cast<unsigned>(completed & 1U);
      cycles += WaitSlot(slot, slot_sequence[slot], deadline);
      if (next < model_.layers.size()) {
        slot_sequence[slot] = NextSequence();
        ProgramSlot(slot, model_.layers[next++], arena_physical,
                    slot_sequence[slot]);
        SubmitSlot(slot, true);
      } else {
        registers_.Write(0x04U, 1U << (16U + slot));
      }
    }
    return cycles;
  }

  int8_t ReadOutput(const uint8_t* arena,
                    const Layer& layer,
                    uint32_t y,
                    uint32_t x,
                    uint32_t channel) const {
    const std::size_t offset = layer.output_offset +
        ((static_cast<std::size_t>(y) * layer.output_width + x) *
             layer.output_blocks +
         channel / 8U) * 8U + channel % 8U;
    return *reinterpret_cast<const int8_t*>(arena + offset);
  }

  std::vector<PureCnnDetection> DecodeDetections(
      const uint8_t* arena) const {
    std::vector<std::vector<PureCnnDetection> > per_label(
        model_.labels.size());
    const float threshold =
        std::max(model_.score_threshold, settings_.score_threshold);

    for (std::size_t head_index = 0; head_index < model_.heads.size();
         ++head_index) {
      const Head& head = model_.heads[head_index];
      const Layer& box = model_.layers[head.box_layer];
      const Layer& score = model_.layers[head.score_layer];
      std::vector<float> logits(head.classes);
      for (uint32_t y = 0; y < head.height; ++y) {
        for (uint32_t x = 0; x < head.width; ++x) {
          for (uint32_t anchor = 0; anchor < head.anchors; ++anchor) {
            const std::size_t prior_index = head.prior_start +
                (static_cast<std::size_t>(y) * head.width + x) *
                    head.anchors + anchor;
            const float* prior = &priors_[prior_index * 4U];
            const uint32_t box_channel = anchor * 4U;
            const float dx = ReadOutput(arena, box, y, x,
                                        box_channel + 0U) * box.output_scale;
            const float dy = ReadOutput(arena, box, y, x,
                                        box_channel + 1U) * box.output_scale;
            const float dw = ReadOutput(arena, box, y, x,
                                        box_channel + 2U) * box.output_scale;
            const float dh = ReadOutput(arena, box, y, x,
                                        box_channel + 3U) * box.output_scale;
            const float prior_width = prior[2] - prior[0];
            const float prior_height = prior[3] - prior[1];
            const float prior_center_x = (prior[0] + prior[2]) * 0.5f;
            const float prior_center_y = (prior[1] + prior[3]) * 0.5f;
            const float center_x = prior_center_x +
                dx * head.variances[0] * prior_width;
            const float center_y = prior_center_y +
                dy * head.variances[1] * prior_height;
            const float width = std::exp(Clamp(
                dw * head.variances[2], -20.0f, 20.0f)) * prior_width;
            const float height = std::exp(Clamp(
                dh * head.variances[3], -20.0f, 20.0f)) * prior_height;

            float maximum_logit = -std::numeric_limits<float>::infinity();
            for (uint32_t class_index = 0; class_index < head.classes;
                 ++class_index) {
              const uint32_t score_channel =
                  anchor * head.classes + class_index;
              logits[class_index] = ReadOutput(
                  arena, score, y, x, score_channel) * score.output_scale;
              maximum_logit = std::max(maximum_logit, logits[class_index]);
            }
            float denominator = 0.0f;
            for (uint32_t class_index = 0; class_index < head.classes;
                 ++class_index) {
              logits[class_index] = std::exp(
                  logits[class_index] - maximum_logit);
              denominator += logits[class_index];
            }
            if (!(denominator > 0.0f) || !std::isfinite(denominator)) {
              continue;
            }
            for (uint32_t class_index = 0; class_index < head.classes;
                 ++class_index) {
              const int label = LabelIndex(
                  static_cast<int>(class_index), model_.background_label);
              if (label < 0) {
                continue;
              }
              const float probability = logits[class_index] / denominator;
              if (probability < threshold || !std::isfinite(probability)) {
                continue;
              }
              PureCnnDetection detection;
              detection.label_id = label;
              detection.score = probability;
              detection.left = Clamp(center_x - width * 0.5f, 0.0f, 1.0f);
              detection.top = Clamp(center_y - height * 0.5f, 0.0f, 1.0f);
              detection.right = Clamp(center_x + width * 0.5f, 0.0f, 1.0f);
              detection.bottom = Clamp(center_y + height * 0.5f, 0.0f, 1.0f);
              if (detection.right > detection.left &&
                  detection.bottom > detection.top) {
                per_label[static_cast<std::size_t>(label)].push_back(detection);
              }
            }
          }
        }
      }
    }

    std::vector<PureCnnDetection> kept;
    for (std::size_t label = 0; label < per_label.size(); ++label) {
      std::vector<PureCnnDetection>& candidates = per_label[label];
      std::sort(candidates.begin(), candidates.end(), HigherScore);
      if (model_.nms_top_k > 0 &&
          candidates.size() > static_cast<std::size_t>(model_.nms_top_k)) {
        candidates.resize(static_cast<std::size_t>(model_.nms_top_k));
      }
      std::vector<PureCnnDetection> class_kept;
      for (std::size_t index = 0; index < candidates.size(); ++index) {
        bool suppressed = false;
        for (std::size_t selected = 0; selected < class_kept.size();
             ++selected) {
          if (IntersectionOverUnion(candidates[index], class_kept[selected]) >
              model_.nms_threshold) {
            suppressed = true;
            break;
          }
        }
        if (!suppressed) {
          class_kept.push_back(candidates[index]);
        }
      }
      kept.insert(kept.end(), class_kept.begin(), class_kept.end());
    }
    std::sort(kept.begin(), kept.end(), HigherScore);
    if (model_.keep_top_k > 0 &&
        kept.size() > static_cast<std::size_t>(model_.keep_top_k)) {
      kept.resize(static_cast<std::size_t>(model_.keep_top_k));
    }
    return kept;
  }

  Settings settings_;
  Model model_;
  std::vector<uint8_t> parameters_;
  std::vector<uint8_t> prior_bytes_;
  std::vector<float> priors_;
  std::size_t parameter_span_;
  CmaMemory cma_;
  RegisterBank registers_;
  uint32_t sequence_;
  unsigned next_bank_;
  mutable std::mutex mutex_;
};

PureCnnRuntime::Settings::Settings()
    : model_directory("model"),
      cma_device("/dev/cmadrv0"),
      channel_order_override(""),
      register_base(0xFF200000ULL),
      timeout_ms(60000U),
      poll_interval_us(50U),
      score_threshold(0.20f) {}

PureCnnRuntime::PureCnnRuntime(const Settings& settings)
    : impl_(new Impl(settings)) {}

PureCnnRuntime::~PureCnnRuntime() {}

PureCnnResult PureCnnRuntime::Run(const cv::Mat& decoded_bgr) {
  return impl_->Run(decoded_bgr);
}

void PureCnnRuntime::Reset() { impl_->Reset(); }

const std::vector<std::string>& PureCnnRuntime::labels() const {
  return impl_->labels();
}

std::string PureCnnRuntime::model_format() const { return impl_->format(); }

std::string PureCnnRuntime::channel_order() const {
  return impl_->channel_order();
}

uint32_t PureCnnRuntime::core_id() const { return impl_->core_id(); }

uint32_t PureCnnRuntime::core_version() const {
  return impl_->core_version();
}

uint32_t PureCnnRuntime::completed_jobs() const {
  return impl_->completed_jobs();
}

}  // namespace c5mb
