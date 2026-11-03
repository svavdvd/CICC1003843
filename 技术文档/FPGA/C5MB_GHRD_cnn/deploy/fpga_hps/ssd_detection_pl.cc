#include <signal.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "httplib.h"
#include "json.hpp"
#include "pl_sort_control.hpp"
#include "opencv2/core.hpp"
#include "opencv2/imgcodecs.hpp"
#include "opencv2/imgproc.hpp"
#include "paddle_api.h"

namespace {

using json = nlohmann::json;
using paddle::lite_api::MobileConfig;
using paddle::lite_api::PaddlePredictor;
using paddle::lite_api::PowerMode;
using paddle::lite_api::Tensor;

volatile sig_atomic_t g_stop = 0;

void SignalHandler(int) { g_stop = 1; }

std::string Trim(const std::string& value) {
  const std::string whitespace = " \t\r\n";
  const std::size_t first = value.find_first_not_of(whitespace);
  if (first == std::string::npos) {
    return "";
  }
  const std::size_t last = value.find_last_not_of(whitespace);
  return value.substr(first, last - first + 1);
}

std::map<std::string, std::string> ReadConfig(const std::string& path) {
  std::ifstream stream(path.c_str());
  if (!stream) {
    throw std::runtime_error("cannot open config: " + path);
  }

  std::map<std::string, std::string> values;
  std::string line;
  int line_number = 0;
  while (std::getline(stream, line)) {
    ++line_number;
    const std::size_t comment = line.find('#');
    if (comment != std::string::npos) {
      line.erase(comment);
    }
    line = Trim(line);
    if (line.empty()) {
      continue;
    }
    const std::size_t separator = line.find('=');
    if (separator == std::string::npos) {
      std::ostringstream error;
      error << "config line " << line_number << " must use key=value";
      throw std::runtime_error(error.str());
    }
    const std::string key = Trim(line.substr(0, separator));
    if (key.empty()) {
      throw std::runtime_error("config contains an empty key");
    }
    values[key] = Trim(line.substr(separator + 1));
  }
  return values;
}

std::string GetValue(const std::map<std::string, std::string>& values,
                     const std::string& key,
                     const std::string& default_value) {
  const std::map<std::string, std::string>::const_iterator item =
      values.find(key);
  return item == values.end() ? default_value : item->second;
}

long ParseLong(const std::string& value, const std::string& key) {
  char* end = NULL;
  errno = 0;
  const long result = std::strtol(value.c_str(), &end, 0);
  if (errno != 0 || end == value.c_str() || *end != '\0') {
    throw std::runtime_error("invalid integer for " + key + ": " + value);
  }
  return result;
}

uint64_t ParseUnsigned(const std::string& value, const std::string& key) {
  char* end = NULL;
  errno = 0;
  const unsigned long long result = std::strtoull(value.c_str(), &end, 0);
  if (errno != 0 || end == value.c_str() || *end != '\0') {
    throw std::runtime_error("invalid unsigned integer for " + key + ": " +
                             value);
  }
  return static_cast<uint64_t>(result);
}

bool ParseBool(const std::string& value, const std::string& key) {
  if (value == "1" || value == "true" || value == "yes") {
    return true;
  }
  if (value == "0" || value == "false" || value == "no") {
    return false;
  }
  throw std::runtime_error("invalid boolean for " + key + ": " + value);
}

float ParseFloat(const std::string& value, const std::string& key) {
  char* end = NULL;
  errno = 0;
  const float result = std::strtof(value.c_str(), &end);
  if (errno != 0 || end == value.c_str() || *end != '\0' ||
      !std::isfinite(result)) {
    throw std::runtime_error("invalid float for " + key + ": " + value);
  }
  return result;
}

std::array<float, 3> ParseFloat3(const std::string& value,
                                const std::string& key) {
  std::array<float, 3> result;
  std::istringstream stream(value);
  std::string token;
  for (std::size_t index = 0; index < result.size(); ++index) {
    if (!std::getline(stream, token, ',')) {
      throw std::runtime_error(
          key + " must contain three comma-separated values");
    }
    result[index] = ParseFloat(Trim(token), key);
  }
  if (std::getline(stream, token, ',')) {
    throw std::runtime_error(key + " contains more than three values");
  }
  return result;
}

std::array<float, 5> ParseFloat5(const std::string& value,
                                const std::string& key) {
  std::array<float, 5> result;
  std::istringstream stream(value);
  std::string token;
  for (std::size_t index = 0; index < result.size(); ++index) {
    if (!std::getline(stream, token, ',')) {
      throw std::runtime_error(
          key + " must contain five comma-separated values");
    }
    result[index] = ParseFloat(Trim(token), key);
  }
  if (std::getline(stream, token, ',')) {
    throw std::runtime_error(key + " contains more than five values");
  }
  return result;
}

struct Settings {
  std::string model_path;
  std::string labels_path;
  std::string bind_address = "0.0.0.0";
  int port = 8080;
  int input_width = 300;
  int input_height = 300;
  int image_input_index = 1;
  int shape_input_index = 0;
  int scale_input_index = 2;
  int threads = 2;
  int warmup_runs = 1;
  int max_upload_bytes = 16 * 1024 * 1024;
  float score_threshold = 0.2f;
  bool pl_sort_enabled = true;
  bool pl_four_class_mode = false;
  uint64_t pl_sort_base = c5mb::PlSortControl::kDefaultPhysicalBase;
  uint64_t pl_sort_clock_hz = 50000000ULL;
  uint64_t pl_watchdog_ms = 30000ULL;
  std::array<float, 5> pl_thresholds{{0.70f, 0.70f, 0.70f, 0.20f,
                                      0.70f}};
  std::string input_color_order = "bgr";
  std::array<float, 3> mean{{127.5f, 127.5f, 127.5f}};
  std::array<float, 3> standard_deviation{{127.502231f,
                                            127.502231f,
                                            127.502231f}};
};

Settings LoadSettings(const std::string& path) {
  const std::map<std::string, std::string> values = ReadConfig(path);
  Settings settings;
  settings.model_path =
      GetValue(values, "model_path", "model/ssd_mobilenet_v1_op.nb");
  settings.labels_path = GetValue(values, "labels_path", "labels.txt");
  settings.bind_address = GetValue(values, "bind_address", "0.0.0.0");
  settings.port = ParseLong(GetValue(values, "port", "8080"), "port");
  settings.input_width =
      ParseLong(GetValue(values, "input_width", "300"), "input_width");
  settings.input_height =
      ParseLong(GetValue(values, "input_height", "300"), "input_height");
  settings.image_input_index = ParseLong(
      GetValue(values, "image_input_index", "1"), "image_input_index");
  settings.shape_input_index = ParseLong(
      GetValue(values, "shape_input_index", "0"), "shape_input_index");
  settings.scale_input_index = ParseLong(
      GetValue(values, "scale_input_index", "2"), "scale_input_index");
  settings.threads =
      ParseLong(GetValue(values, "threads", "2"), "threads");
  settings.warmup_runs = ParseLong(
      GetValue(values, "warmup_runs", "1"), "warmup_runs");
  settings.max_upload_bytes = ParseLong(
      GetValue(values, "max_upload_bytes", "16777216"),
      "max_upload_bytes");
  settings.score_threshold = ParseFloat(
      GetValue(values, "score_threshold", "0.2"), "score_threshold");
  settings.pl_sort_enabled = ParseBool(
      GetValue(values, "pl_sort_enabled", "true"), "pl_sort_enabled");
  settings.pl_four_class_mode = ParseBool(
      GetValue(values, "pl_four_class_mode", "false"),
      "pl_four_class_mode");
  settings.pl_sort_base = ParseUnsigned(
      GetValue(values, "pl_sort_base", "0xff200800"), "pl_sort_base");
  settings.pl_sort_clock_hz = ParseUnsigned(
      GetValue(values, "pl_sort_clock_hz", "50000000"),
      "pl_sort_clock_hz");
  settings.pl_watchdog_ms = ParseUnsigned(
      GetValue(values, "pl_watchdog_ms", "30000"), "pl_watchdog_ms");
  settings.pl_thresholds = ParseFloat5(
      GetValue(values, "pl_thresholds", "0.70,0.70,0.70,0.20,0.70"),
      "pl_thresholds");
  settings.input_color_order =
      GetValue(values, "input_color_order", "bgr");
  settings.mean = ParseFloat3(
      GetValue(values, "mean", "127.5,127.5,127.5"), "mean");
  settings.standard_deviation = ParseFloat3(
      GetValue(values, "std", "127.502231,127.502231,127.502231"),
      "std");

  if (settings.bind_address.empty()) {
    throw std::runtime_error("bind_address must not be empty");
  }
  if (settings.port <= 0 || settings.port > 65535) {
    throw std::runtime_error("port must be in 1..65535");
  }
  if (settings.input_width <= 0 || settings.input_height <= 0 ||
      settings.threads <= 0 || settings.warmup_runs < 0 ||
      settings.max_upload_bytes <= 0) {
    throw std::runtime_error("invalid image, thread, warmup, or upload setting");
  }
  if (settings.score_threshold < 0.0f || settings.score_threshold > 1.0f) {
    throw std::runtime_error("score_threshold must be in [0,1]");
  }
  if (settings.pl_sort_enabled &&
      (settings.pl_sort_clock_hz == 0U || settings.pl_watchdog_ms == 0U ||
       settings.pl_sort_clock_hz >
           std::numeric_limits<uint32_t>::max() * 1000ULL /
               settings.pl_watchdog_ms)) {
    throw std::runtime_error("PL watchdog settings overflow 32 bits");
  }
  for (std::size_t index = 0; index < settings.pl_thresholds.size(); ++index) {
    if (settings.pl_thresholds[index] < 0.0f ||
        settings.pl_thresholds[index] > 1.0f) {
      throw std::runtime_error("pl_thresholds values must be in [0,1]");
    }
  }
  if (settings.input_color_order != "bgr" &&
      settings.input_color_order != "rgb") {
    throw std::runtime_error("input_color_order must be bgr or rgb");
  }
  for (std::size_t index = 0;
       index < settings.standard_deviation.size(); ++index) {
    if (settings.standard_deviation[index] == 0.0f) {
      throw std::runtime_error("std values must be non-zero");
    }
  }
  return settings;
}

std::vector<std::string> LoadLabels(const std::string& path) {
  std::ifstream stream(path.c_str());
  if (!stream) {
    throw std::runtime_error("cannot open labels: " + path);
  }
  std::vector<std::string> labels;
  std::string line;
  while (std::getline(stream, line)) {
    line = Trim(line);
    if (!line.empty()) {
      labels.push_back(line);
    }
  }
  const char* expected[] = {
      "ca_shang", "zang_wu", "zhe_zhou", "zhen_kong", "zheng_chang"};
  if (labels.size() != 5U) {
    throw std::runtime_error("ISDD model requires exactly five labels");
  }
  for (std::size_t index = 0; index < labels.size(); ++index) {
    if (labels[index] != expected[index]) {
      throw std::runtime_error(
          "label order must match isdd-dataset-voc/label_list.txt");
    }
  }
  return labels;
}

std::shared_ptr<PaddlePredictor> LoadPredictor(const Settings& settings) {
  MobileConfig config;
  config.set_model_from_file(settings.model_path);
  config.set_threads(settings.threads);
  config.set_power_mode(PowerMode::LITE_POWER_NO_BIND);
  return paddle::lite_api::CreatePaddlePredictor<MobileConfig>(config);
}

void PrintModelInputs(PaddlePredictor* predictor) {
  const std::vector<std::string> names = predictor->GetInputNames();
  std::cerr << "model inputs (" << names.size() << "):";
  for (std::size_t index = 0; index < names.size(); ++index) {
    std::cerr << " [" << index << "]=" << names[index];
  }
  std::cerr << std::endl;
}

void SetModelInputs(PaddlePredictor* predictor,
                    const Settings& settings,
                    const cv::Mat& decoded_bgr) {
  if (decoded_bgr.empty()) {
    throw std::runtime_error("decoded image is empty");
  }

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
             cv::Size(settings.input_width, settings.input_height), 0.0, 0.0,
             cv::INTER_CUBIC);
  if (settings.input_color_order == "rgb") {
    cv::cvtColor(resized, resized, cv::COLOR_BGR2RGB);
  }

  const std::vector<std::string> input_names = predictor->GetInputNames();
  if (input_names.empty()) {
    throw std::runtime_error("model reports no inputs");
  }
  const int image_index =
      input_names.size() == 1U ? 0 : settings.image_input_index;
  if (image_index < 0 ||
      static_cast<std::size_t>(image_index) >= input_names.size()) {
    throw std::runtime_error("image_input_index is outside model inputs");
  }

  std::unique_ptr<Tensor> image = predictor->GetInput(image_index);
  image->Resize({1, 3, settings.input_height, settings.input_width});
  float* output = image->mutable_data<float>();
  const std::size_t plane = static_cast<std::size_t>(settings.input_width) *
                            settings.input_height;
  for (int y = 0; y < settings.input_height; ++y) {
    const cv::Vec3b* row = resized.ptr<cv::Vec3b>(y);
    for (int x = 0; x < settings.input_width; ++x) {
      const std::size_t pixel =
          static_cast<std::size_t>(y) * settings.input_width + x;
      for (std::size_t channel = 0; channel < 3U; ++channel) {
        output[channel * plane + pixel] =
            (static_cast<float>(row[x][channel]) - settings.mean[channel]) /
            settings.standard_deviation[channel];
      }
    }
  }

  if (input_names.size() >= 3U) {
    if (settings.shape_input_index < 0 || settings.scale_input_index < 0 ||
        static_cast<std::size_t>(settings.shape_input_index) >=
            input_names.size() ||
        static_cast<std::size_t>(settings.scale_input_index) >=
            input_names.size()) {
      throw std::runtime_error("shape/scale input index is outside model inputs");
    }

    std::unique_ptr<Tensor> shape =
        predictor->GetInput(settings.shape_input_index);
    shape->Resize({1, 2});
    float* shape_data = shape->mutable_data<float>();
    shape_data[0] = static_cast<float>(settings.input_height);
    shape_data[1] = static_cast<float>(settings.input_width);

    std::unique_ptr<Tensor> scale =
        predictor->GetInput(settings.scale_input_index);
    scale->Resize({1, 2});
    float* scale_data = scale->mutable_data<float>();
    scale_data[0] = static_cast<float>(settings.input_height) /
                    static_cast<float>(decoded_bgr.rows);
    scale_data[1] = static_cast<float>(settings.input_width) /
                    static_cast<float>(decoded_bgr.cols);
  }
}

json ReadDetections(
    PaddlePredictor* predictor,
    const Settings& settings,
    const std::vector<std::string>& labels,
    int image_width,
    int image_height,
    double prediction_ms,
    std::vector<c5mb::PlSortControl::Candidate>* candidates) {
  std::unique_ptr<const Tensor> output = predictor->GetOutput(0);
  const std::vector<int64_t> shape = output->shape();
  int64_t elements = 1;
  for (std::size_t index = 0; index < shape.size(); ++index) {
    if (shape[index] <= 0 ||
        elements > std::numeric_limits<int64_t>::max() / shape[index]) {
      throw std::runtime_error("invalid output tensor shape");
    }
    elements *= shape[index];
  }
  if (elements < 6 || elements % 6 != 0) {
    throw std::runtime_error(
        "SSD output is not a sequence of six-value detections");
  }

  json results = json::array();
  const float* data = output->data<float>();
  for (int64_t index = 0; index < elements; index += 6) {
    if (!std::isfinite(data[index + 0]) ||
        !std::isfinite(data[index + 1]) ||
        !std::isfinite(data[index + 2]) ||
        !std::isfinite(data[index + 3]) ||
        !std::isfinite(data[index + 4]) ||
        !std::isfinite(data[index + 5])) {
      continue;
    }
    const int class_id = static_cast<int>(data[index + 0]);
    const float score = data[index + 1];
    if (class_id < 0 || static_cast<std::size_t>(class_id) >= labels.size() ||
        score < settings.score_threshold || score > 1.0f) {
      continue;
    }

    float left = data[index + 2];
    float top = data[index + 3];
    float right = data[index + 4];
    float bottom = data[index + 5];
    if (right <= 1.5f && bottom <= 1.5f) {
      left *= image_width;
      right *= image_width;
      top *= image_height;
      bottom *= image_height;
    }
    left = std::max(0.0f, std::min(left, static_cast<float>(image_width - 1)));
    right =
        std::max(0.0f, std::min(right, static_cast<float>(image_width - 1)));
    top = std::max(0.0f, std::min(top, static_cast<float>(image_height - 1)));
    bottom = std::max(
        0.0f, std::min(bottom, static_cast<float>(image_height - 1)));
    if (right <= left || bottom <= top) {
      continue;
    }

    json item;
    item["class_name"] = labels[class_id];
    item["score"] = score;
    item["loc"] = {static_cast<int>(std::lround(left)),
                   static_cast<int>(std::lround(top)),
                   static_cast<int>(std::lround(right)),
                   static_cast<int>(std::lround(bottom))};
    item["prediction_time"] = prediction_ms;
    results.push_back(item);

    c5mb::PlSortControl::Candidate candidate;
    candidate.class_id = static_cast<uint8_t>(class_id);
    candidate.score = score;
    candidates->push_back(candidate);
  }

  json response;
  response["len"] = results.size();
  response["result"] = results;
  return response;
}

json RunModel(
    PaddlePredictor* predictor,
    const Settings& settings,
    const std::vector<std::string>& labels,
    const cv::Mat& image,
    std::vector<c5mb::PlSortControl::Candidate>* candidates) {
  SetModelInputs(predictor, settings, image);
  const std::chrono::steady_clock::time_point start =
      std::chrono::steady_clock::now();
  predictor->Run();
  const std::chrono::steady_clock::time_point end =
      std::chrono::steady_clock::now();
  const double prediction_ms =
      std::chrono::duration_cast<std::chrono::microseconds>(end - start)
          .count() /
      1000.0;
  return ReadDetections(predictor, settings, labels, image.cols, image.rows,
                        prediction_ms, candidates);
}

const char* DecisionName(c5mb::PlSortControl::Decision decision) {
  switch (decision) {
    case c5mb::PlSortControl::kDecisionOk:
      return "ok";
    case c5mb::PlSortControl::kDecisionNg:
      return "ng";
    default:
      return "unknown";
  }
}

const char* ActionName(c5mb::PlSortControl::Action action) {
  switch (action) {
    case c5mb::PlSortControl::kActionSortRight:
      return "right";
    case c5mb::PlSortControl::kActionSortLeft:
      return "left";
    default:
      return "hold";
  }
}

uint32_t AllocateEventId(uint32_t* next_event_id) {
  if (*next_event_id == 0U) {
    *next_event_id = 1U;
  }
  const uint32_t result = *next_event_id;
  ++(*next_event_id);
  if (*next_event_id == 0U) {
    *next_event_id = 1U;
  }
  return result;
}

void SetJson(httplib::Response* response, int status, const json& value) {
  response->status = status;
  response->set_content(value.dump(), "application/json; charset=utf-8");
}

void SetError(httplib::Response* response,
              int status,
              const std::string& message) {
  json body;
  body["error"] = message;
  SetJson(response, status, body);
}

}  // namespace

int main(int argc, char** argv) {
  const std::string config_path =
      argc >= 2 ? argv[1] : "predict_server.ini";
  try {
    signal(SIGINT, SignalHandler);
    signal(SIGTERM, SignalHandler);

    const Settings settings = LoadSettings(config_path);
    const std::vector<std::string> labels = LoadLabels(settings.labels_path);
    std::shared_ptr<PaddlePredictor> predictor = LoadPredictor(settings);
    PrintModelInputs(predictor.get());

    std::unique_ptr<c5mb::PlSortControl> pl_sort;
    if (settings.pl_sort_enabled) {
      const uint64_t watchdog_cycles_64 =
          settings.pl_sort_clock_hz * settings.pl_watchdog_ms / 1000ULL;
      pl_sort.reset(new c5mb::PlSortControl(settings.pl_sort_base));
      pl_sort->Initialize(settings.pl_four_class_mode,
                          static_cast<uint32_t>(watchdog_cycles_64));
      for (std::size_t index = 0; index < settings.pl_thresholds.size();
           ++index) {
        pl_sort->SetThreshold(static_cast<uint8_t>(index),
                              settings.pl_thresholds[index]);
      }
    }
    uint32_t next_event_id = 1U;

    const cv::Mat warmup(settings.input_height, settings.input_width, CV_8UC3,
                         cv::Scalar(0, 0, 0));
    for (int run = 0; run < settings.warmup_runs; ++run) {
      SetModelInputs(predictor.get(), settings, warmup);
      predictor->Run();
    }

    httplib::Server server;
    server.new_task_queue = [] { return new httplib::ThreadPool(1); };
    server.set_payload_max_length(
        static_cast<std::size_t>(settings.max_upload_bytes) + 65536U);
    server.set_read_timeout(15, 0);
    server.set_write_timeout(15, 0);

    server.Get("/health", [&](const httplib::Request&, httplib::Response& res) {
      json body;
      body["status"] = "ok";
      body["model"] = settings.model_path;
      body["classes"] = labels.size();
      body["pl_sort_enabled"] = settings.pl_sort_enabled;
      if (pl_sort.get() != NULL) {
        body["pl_status"] = pl_sort->status();
        body["pl_fault"] = pl_sort->fault_code();
        body["active_event_id"] = pl_sort->active_event_id();
      }
      SetJson(&res, 200, body);
    });

    server.Post("/predict",
                [&](const httplib::Request& req, httplib::Response& res) {
      try {
        if (!req.has_file("image_file")) {
          SetError(&res, 400, "multipart field image_file is required");
          return;
        }
        const httplib::MultipartFormData upload =
            req.get_file_value("image_file");
        if (upload.content.empty()) {
          SetError(&res, 400, "image_file is empty");
          return;
        }
        if (upload.content.size() >
            static_cast<std::size_t>(settings.max_upload_bytes)) {
          SetError(&res, 413, "image_file exceeds max_upload_bytes");
          return;
        }
        const std::vector<unsigned char> encoded(upload.content.begin(),
                                                 upload.content.end());
        const cv::Mat image = cv::imdecode(encoded, cv::IMREAD_COLOR);
        if (image.empty()) {
          SetError(&res, 415, "image_file is not a supported image");
          return;
        }

        std::vector<c5mb::PlSortControl::Candidate> candidates;
        json output =
            RunModel(predictor.get(), settings, labels, image, &candidates);
        if (pl_sort.get() != NULL) {
          const uint32_t event_id = AllocateEventId(&next_event_id);
          const c5mb::PlSortControl::Result pl_result =
              pl_sort->Submit(event_id, true, true, candidates);
          output["event_id"] = pl_result.event_id;
          output["decision"] = DecisionName(pl_result.decision);
          output["action"] = ActionName(pl_result.action);
          output["alarm"] = pl_result.alarm;
          output["pl_status"] = pl_result.status;
          output["pl_fault"] = pl_result.fault_code;
        }
        SetJson(&res, 200, output);
      } catch (const std::exception& error) {
        std::cerr << "predict error: " << error.what() << std::endl;
        SetError(&res, 500, error.what());
      }
    });

    server.Post("/ack",
                [&](const httplib::Request& req, httplib::Response& res) {
      try {
        if (pl_sort.get() == NULL) {
          SetError(&res, 409, "PL sort control is disabled");
          return;
        }
        const json request_body = json::parse(req.body);
        const uint32_t event_id =
            request_body.at("event_id").get<uint32_t>();
        const bool success = request_body.at("success").get<bool>();
        pl_sort->Acknowledge(event_id, success);
        json body;
        body["event_id"] = event_id;
        body["acknowledged"] = true;
        body["success"] = success;
        body["pl_status"] = pl_sort->status();
        body["pl_fault"] = pl_sort->fault_code();
        SetJson(&res, 200, body);
      } catch (const std::exception& error) {
        std::cerr << "ack error: " << error.what() << std::endl;
        SetError(&res, 409, error.what());
      }
    });

    server.set_error_handler(
        [](const httplib::Request&, httplib::Response& res) {
      if (res.body.empty()) {
        SetError(&res, res.status == 413 ? 413 : 404,
                 res.status == 413 ? "request payload is too large"
                                   : "route not found");
      }
    });

    std::thread stop_watcher([&server]() {
      while (!g_stop) {
        usleep(100000);
      }
      server.stop();
    });

    std::cerr << "C5MB predict server listening on " << settings.bind_address
              << ':' << settings.port << std::endl;
    const bool listened =
        server.listen(settings.bind_address.c_str(), settings.port);
    g_stop = 1;
    stop_watcher.join();
    if (!listened) {
      throw std::runtime_error("HTTP server listen failed");
    }

    predictor.reset();
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "fatal: " << error.what() << std::endl;
    return 1;
  }
}
