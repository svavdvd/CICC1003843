#include <signal.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
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
#include "opencv2/imgcodecs.hpp"
#include "pl_sort_control.hpp"
#include "pure_cnn_runtime.hpp"

namespace {

using json = nlohmann::json;

volatile sig_atomic_t g_stop = 0;

void SignalHandler(int) { g_stop = 1; }

std::string Trim(const std::string& value) {
  const std::string whitespace = " \t\r\n";
  const std::size_t first = value.find_first_not_of(whitespace);
  if (first == std::string::npos) {
    return "";
  }
  return value.substr(first, value.find_last_not_of(whitespace) - first + 1U);
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
    values[key] = Trim(line.substr(separator + 1U));
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

bool ParseBool(const std::string& value, const std::string& key) {
  if (value == "1" || value == "true" || value == "yes") {
    return true;
  }
  if (value == "0" || value == "false" || value == "no") {
    return false;
  }
  throw std::runtime_error("invalid boolean for " + key + ": " + value);
}

std::array<float, 5> ParseFloat5(const std::string& value,
                                const std::string& key) {
  std::array<float, 5> result;
  std::istringstream stream(value);
  std::string token;
  for (std::size_t index = 0; index < result.size(); ++index) {
    if (!std::getline(stream, token, ',')) {
      throw std::runtime_error(key + " must contain five values");
    }
    result[index] = ParseFloat(Trim(token), key);
  }
  if (std::getline(stream, token, ',')) {
    throw std::runtime_error(key + " contains more than five values");
  }
  return result;
}

struct Settings {
  std::string bind_address;
  int port;
  int max_upload_bytes;
  c5mb::PureCnnRuntime::Settings cnn;
  bool pl_sort_enabled;
  bool pl_four_class_mode;
  bool pl_swap_sides;
  uint64_t pl_sort_base;
  uint64_t pl_sort_clock_hz;
  uint64_t pl_watchdog_ms;
  std::array<float, 5> pl_thresholds;
};

Settings LoadSettings(const std::string& path) {
  const std::map<std::string, std::string> values = ReadConfig(path);
  Settings settings;
  settings.bind_address = GetValue(values, "bind_address", "0.0.0.0");
  settings.port = static_cast<int>(
      ParseLong(GetValue(values, "port", "8082"), "port"));
  settings.max_upload_bytes = static_cast<int>(ParseLong(
      GetValue(values, "max_upload_bytes", "16777216"),
      "max_upload_bytes"));
  settings.cnn.model_directory =
      GetValue(values, "model_directory", "model");
  settings.cnn.cma_device =
      GetValue(values, "cma_device", "/dev/cmadrv0");
  settings.cnn.channel_order_override =
      GetValue(values, "channel_order", "");
  settings.cnn.register_base = ParseUnsigned(
      GetValue(values, "cnn_base", "0xff200000"), "cnn_base");
  settings.cnn.timeout_ms = static_cast<uint32_t>(ParseUnsigned(
      GetValue(values, "cnn_timeout_ms", "60000"), "cnn_timeout_ms"));
  settings.cnn.poll_interval_us = static_cast<uint32_t>(ParseUnsigned(
      GetValue(values, "cnn_poll_interval_us", "50"),
      "cnn_poll_interval_us"));
  settings.cnn.score_threshold = ParseFloat(
      GetValue(values, "score_threshold", "0.20"), "score_threshold");
  settings.pl_sort_enabled = ParseBool(
      GetValue(values, "pl_sort_enabled", "true"), "pl_sort_enabled");
  settings.pl_four_class_mode = ParseBool(
      GetValue(values, "pl_four_class_mode", "false"),
      "pl_four_class_mode");
  settings.pl_swap_sides = ParseBool(
      GetValue(values, "pl_swap_sides", "false"), "pl_swap_sides");
  settings.pl_sort_base = ParseUnsigned(
      GetValue(values, "pl_sort_base", "0xff200800"), "pl_sort_base");
  settings.pl_sort_clock_hz = ParseUnsigned(
      GetValue(values, "pl_sort_clock_hz", "50000000"),
      "pl_sort_clock_hz");
  settings.pl_watchdog_ms = ParseUnsigned(
      GetValue(values, "pl_watchdog_ms", "85000"), "pl_watchdog_ms");
  settings.pl_thresholds = ParseFloat5(
      GetValue(values, "pl_thresholds", "0.70,0.70,0.70,0.20,0.70"),
      "pl_thresholds");

  if (settings.bind_address.empty() || settings.port <= 0 ||
      settings.port > 65535 || settings.max_upload_bytes <= 0) {
    throw std::runtime_error("invalid HTTP server settings");
  }
  if (settings.cnn.register_base >
          std::numeric_limits<uint32_t>::max() ||
      settings.cnn.timeout_ms == 0U ||
      settings.cnn.poll_interval_us == 0U ||
      settings.cnn.score_threshold < 0.0f ||
      settings.cnn.score_threshold > 1.0f) {
    throw std::runtime_error("invalid pure CNN settings");
  }
  if (settings.pl_sort_enabled) {
    const uint64_t cycles =
        settings.pl_sort_clock_hz * settings.pl_watchdog_ms / 1000ULL;
    if (settings.pl_sort_clock_hz == 0U || settings.pl_watchdog_ms == 0U ||
        cycles > std::numeric_limits<uint32_t>::max()) {
      throw std::runtime_error("PL sort watchdog does not fit 32 bits");
    }
  }
  for (std::size_t index = 0; index < settings.pl_thresholds.size(); ++index) {
    if (settings.pl_thresholds[index] < 0.0f ||
        settings.pl_thresholds[index] > 1.0f) {
      throw std::runtime_error("PL thresholds must be in [0,1]");
    }
  }
  return settings;
}

void ValidateLabels(const std::vector<std::string>& labels) {
  const char* expected[] = {
      "ca_shang", "zang_wu", "zhe_zhou", "zhen_kong", "zheng_chang"};
  if (labels.size() != 5U) {
    throw std::runtime_error("sorting control requires five ISDD labels");
  }
  for (std::size_t index = 0; index < labels.size(); ++index) {
    if (labels[index] != expected[index]) {
      throw std::runtime_error("model label order does not match PL sorting IP");
    }
  }
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

std::string Hex(uint32_t value) {
  std::ostringstream stream;
  stream << "0x" << std::hex << value;
  return stream.str();
}

json BuildDetectionJson(
    const c5mb::PureCnnResult& inference,
    const std::vector<std::string>& labels,
    int image_width,
    int image_height,
    std::vector<c5mb::PlSortControl::Candidate>* candidates) {
  json results = json::array();
  const double total_ms = inference.preprocess_ms + inference.accelerator_ms +
                          inference.postprocess_ms;
  for (std::size_t index = 0; index < inference.detections.size(); ++index) {
    const c5mb::PureCnnDetection& detection = inference.detections[index];
    if (detection.label_id < 0 ||
        static_cast<std::size_t>(detection.label_id) >= labels.size()) {
      continue;
    }
    const int left = static_cast<int>(std::lround(
        detection.left * static_cast<float>(image_width - 1)));
    const int top = static_cast<int>(std::lround(
        detection.top * static_cast<float>(image_height - 1)));
    const int right = static_cast<int>(std::lround(
        detection.right * static_cast<float>(image_width - 1)));
    const int bottom = static_cast<int>(std::lround(
        detection.bottom * static_cast<float>(image_height - 1)));
    json item;
    item["class_name"] = labels[static_cast<std::size_t>(detection.label_id)];
    item["score"] = detection.score;
    item["loc"] = {left, top, right, bottom};
    item["prediction_time"] = total_ms;
    results.push_back(item);

    c5mb::PlSortControl::Candidate candidate;
    candidate.class_id = static_cast<uint8_t>(detection.label_id);
    candidate.score = detection.score;
    candidates->push_back(candidate);
  }

  json response;
  response["len"] = results.size();
  response["result"] = results;
  response["timing_ms"] = {
      {"preprocess", inference.preprocess_ms},
      {"accelerator", inference.accelerator_ms},
      {"postprocess", inference.postprocess_ms},
      {"total", total_ms}};
  response["accelerator_cycles"] = inference.accelerator_cycles;
  response["activation_bank"] = inference.activation_bank;
  return response;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string config_path = argc >= 2 ? argv[1] : "gateway.ini";
  try {
    signal(SIGINT, SignalHandler);
    signal(SIGTERM, SignalHandler);
    const Settings settings = LoadSettings(config_path);
    c5mb::PureCnnRuntime runtime(settings.cnn);
    ValidateLabels(runtime.labels());

    std::unique_ptr<c5mb::PlSortControl> pl_sort;
    if (settings.pl_sort_enabled) {
      const uint64_t watchdog_cycles =
          settings.pl_sort_clock_hz * settings.pl_watchdog_ms / 1000ULL;
      pl_sort.reset(new c5mb::PlSortControl(settings.pl_sort_base));
      pl_sort->Initialize(settings.pl_four_class_mode,
                          static_cast<uint32_t>(watchdog_cycles),
                          settings.pl_swap_sides);
      for (std::size_t index = 0; index < settings.pl_thresholds.size();
           ++index) {
        pl_sort->SetThreshold(static_cast<uint8_t>(index),
                              settings.pl_thresholds[index]);
      }
    }
    uint32_t next_event_id = 1U;

    httplib::Server server;
    server.new_task_queue = [] { return new httplib::ThreadPool(1); };
    server.set_payload_max_length(
        static_cast<std::size_t>(settings.max_upload_bytes) + 65536U);
    server.set_read_timeout(15, 0);
    server.set_write_timeout(90, 0);

    server.Get("/health", [&](const httplib::Request&,
                              httplib::Response& response) {
      json body;
      body["status"] = "ok";
      body["runtime"] = "pure-verilog-cnn";
      body["model_format"] = runtime.model_format();
      body["channel_order"] = runtime.channel_order();
      body["classes"] = runtime.labels();
      body["cnn_core_id"] = Hex(runtime.core_id());
      body["cnn_core_version"] = Hex(runtime.core_version());
      body["completed_layer_jobs"] = runtime.completed_jobs();
      body["pl_sort_enabled"] = settings.pl_sort_enabled;
      if (pl_sort.get() != NULL) {
        body["pl_status"] = pl_sort->status();
        body["pl_fault"] = pl_sort->fault_code();
        body["active_event_id"] = pl_sort->active_event_id();
      }
      SetJson(&response, 200, body);
    });

    server.Post("/predict", [&](const httplib::Request& request,
                                 httplib::Response& response) {
      try {
        if (!request.has_file("image_file")) {
          SetError(&response, 400, "multipart field image_file is required");
          return;
        }
        const httplib::MultipartFormData upload =
            request.get_file_value("image_file");
        if (upload.content.empty()) {
          SetError(&response, 400, "image_file is empty");
          return;
        }
        if (upload.content.size() >
            static_cast<std::size_t>(settings.max_upload_bytes)) {
          SetError(&response, 413, "image_file exceeds max_upload_bytes");
          return;
        }
        const std::vector<unsigned char> encoded(upload.content.begin(),
                                                 upload.content.end());
        const cv::Mat image = cv::imdecode(encoded, cv::IMREAD_COLOR);
        if (image.empty()) {
          SetError(&response, 415, "image_file is not a supported image");
          return;
        }

        const c5mb::PureCnnResult inference = runtime.Run(image);
        std::vector<c5mb::PlSortControl::Candidate> candidates;
        json output = BuildDetectionJson(inference, runtime.labels(),
                                         image.cols, image.rows, &candidates);
        if (pl_sort.get() != NULL) {
          const uint32_t event_id = AllocateEventId(&next_event_id);
          const c5mb::PlSortControl::Result result =
              pl_sort->Submit(event_id, true, true, candidates);
          output["event_id"] = result.event_id;
          output["decision"] = DecisionName(result.decision);
          output["action"] = ActionName(result.action);
          output["alarm"] = result.alarm;
          output["pl_status"] = result.status;
          output["pl_fault"] = result.fault_code;
        }
        SetJson(&response, 200, output);
      } catch (const std::exception& error) {
        std::cerr << "predict error: " << error.what() << std::endl;
        SetError(&response, 500, error.what());
      }
    });

    server.Post("/ack", [&](const httplib::Request& request,
                             httplib::Response& response) {
      try {
        if (pl_sort.get() == NULL) {
          SetError(&response, 409, "PL sort control is disabled");
          return;
        }
        const json body = json::parse(request.body);
        const uint32_t event_id = body.at("event_id").get<uint32_t>();
        const bool success = body.at("success").get<bool>();
        pl_sort->Acknowledge(event_id, success);
        json output;
        output["event_id"] = event_id;
        output["acknowledged"] = true;
        output["success"] = success;
        output["pl_status"] = pl_sort->status();
        output["pl_fault"] = pl_sort->fault_code();
        SetJson(&response, 200, output);
      } catch (const std::exception& error) {
        SetError(&response, 409, error.what());
      }
    });

    server.Post("/reset", [&](const httplib::Request&,
                               httplib::Response& response) {
      try {
        runtime.Reset();
        if (pl_sort.get() != NULL) {
          pl_sort->ClearFault();
        }
        json output;
        output["reset"] = true;
        output["pl_fault"] =
            pl_sort.get() == NULL ? 0U : pl_sort->fault_code();
        SetJson(&response, 200, output);
      } catch (const std::exception& error) {
        SetError(&response, 500, error.what());
      }
    });

    server.set_error_handler(
        [](const httplib::Request&, httplib::Response& response) {
      if (response.body.empty()) {
        SetError(&response, response.status == 413 ? 413 : 404,
                 response.status == 413 ? "request payload is too large"
                                        : "route not found");
      }
    });

    std::thread stop_watcher([&server]() {
      while (!g_stop) {
        usleep(100000U);
      }
      server.stop();
    });

    std::cerr << "C5MB pure CNN gateway listening on "
              << settings.bind_address << ':' << settings.port << std::endl;
    const bool listened =
        server.listen(settings.bind_address.c_str(), settings.port);
    g_stop = 1;
    stop_watcher.join();
    if (!listened) {
      throw std::runtime_error("HTTP server listen failed");
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "fatal: " << error.what() << std::endl;
    return 1;
  }
}
