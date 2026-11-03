#include <array>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "httplib.h"
#include "json.hpp"
#include "pl_sort_control.hpp"

namespace {

using json = nlohmann::json;

std::string Trim(const std::string& value) {
  std::size_t begin = 0;
  while (begin < value.size() &&
         std::isspace(static_cast<unsigned char>(value[begin]))) {
    ++begin;
  }
  std::size_t end = value.size();
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(value[end - 1]))) {
    --end;
  }
  return value.substr(begin, end - begin);
}

std::map<std::string, std::string> ReadConfig(const std::string& path) {
  std::ifstream input(path.c_str());
  if (!input) {
    throw std::runtime_error("cannot open config: " + path);
  }
  std::map<std::string, std::string> values;
  std::string line;
  while (std::getline(input, line)) {
    line = Trim(line);
    if (line.empty() || line[0] == '#' || line[0] == ';' || line[0] == '[') {
      continue;
    }
    const std::size_t separator = line.find('=');
    if (separator == std::string::npos) {
      throw std::runtime_error("invalid config line: " + line);
    }
    values[Trim(line.substr(0, separator))] = Trim(line.substr(separator + 1));
  }
  return values;
}

std::string GetValue(const std::map<std::string, std::string>& values,
                     const std::string& key,
                     const std::string& fallback) {
  const std::map<std::string, std::string>::const_iterator found =
      values.find(key);
  return found == values.end() ? fallback : found->second;
}

uint64_t ParseUnsigned(const std::string& value, const std::string& key) {
  errno = 0;
  char* end = NULL;
  const unsigned long long parsed = std::strtoull(value.c_str(), &end, 0);
  if (errno != 0 || end == value.c_str() || *end != '\0') {
    throw std::runtime_error(key + " must be an unsigned integer");
  }
  return static_cast<uint64_t>(parsed);
}

float ParseFloat(const std::string& value, const std::string& key) {
  errno = 0;
  char* end = NULL;
  const float parsed = std::strtof(value.c_str(), &end);
  if (errno != 0 || end == value.c_str() || *end != '\0') {
    throw std::runtime_error(key + " must be a number");
  }
  return parsed;
}

bool ParseBool(const std::string& value, const std::string& key) {
  if (value == "true" || value == "1" || value == "yes") {
    return true;
  }
  if (value == "false" || value == "0" || value == "no") {
    return false;
  }
  throw std::runtime_error(key + " must be true or false");
}

std::vector<std::string> SplitCsv(const std::string& value,
                                  const std::string& key) {
  std::vector<std::string> output;
  std::istringstream stream(value);
  std::string token;
  while (std::getline(stream, token, ',')) {
    token = Trim(token);
    if (token.empty()) {
      throw std::runtime_error(key + " contains an empty item");
    }
    output.push_back(token);
  }
  return output;
}

struct Settings {
  std::string bind_address;
  int port;
  std::string upstream_host;
  int upstream_port;
  std::string upstream_path;
  int upstream_timeout_seconds;
  std::size_t max_upload_bytes;
  uint64_t pl_sort_base;
  uint64_t pl_sort_clock_hz;
  uint64_t pl_watchdog_ms;
  bool pl_four_class_mode;
  bool pl_swap_sides;
  std::array<float, 5> thresholds;
  std::array<std::string, 5> class_order;
};

Settings LoadSettings(const std::string& path) {
  const std::map<std::string, std::string> values = ReadConfig(path);
  Settings settings;
  settings.bind_address = GetValue(values, "bind_address", "0.0.0.0");
  settings.port = static_cast<int>(ParseUnsigned(
      GetValue(values, "port", "8082"), "port"));
  settings.upstream_host = GetValue(values, "upstream_host", "127.0.0.1");
  settings.upstream_port = static_cast<int>(ParseUnsigned(
      GetValue(values, "upstream_port", "8080"), "upstream_port"));
  settings.upstream_path = GetValue(values, "upstream_path", "/predict");
  settings.upstream_timeout_seconds = static_cast<int>(ParseUnsigned(
      GetValue(values, "upstream_timeout_seconds", "30"),
      "upstream_timeout_seconds"));
  settings.max_upload_bytes = static_cast<std::size_t>(ParseUnsigned(
      GetValue(values, "max_upload_bytes", "16777216"), "max_upload_bytes"));
  settings.pl_sort_base = ParseUnsigned(
      GetValue(values, "pl_sort_base", "0xff200800"), "pl_sort_base");
  settings.pl_sort_clock_hz = ParseUnsigned(
      GetValue(values, "pl_sort_clock_hz", "50000000"), "pl_sort_clock_hz");
  settings.pl_watchdog_ms = ParseUnsigned(
      GetValue(values, "pl_watchdog_ms", "85000"), "pl_watchdog_ms");
  settings.pl_four_class_mode = ParseBool(
      GetValue(values, "pl_four_class_mode", "false"),
      "pl_four_class_mode");
  settings.pl_swap_sides = ParseBool(
      GetValue(values, "pl_swap_sides", "false"), "pl_swap_sides");

  const std::vector<std::string> threshold_values = SplitCsv(
      GetValue(values, "pl_thresholds", "0.70,0.70,0.70,0.20,0.70"),
      "pl_thresholds");
  const std::vector<std::string> classes = SplitCsv(
      GetValue(values, "class_order",
               "ca_shang,zang_wu,zhe_zhou,zhen_kong,zheng_chang"),
      "class_order");
  if (threshold_values.size() != 5U || classes.size() != 5U) {
    throw std::runtime_error("pl_thresholds and class_order must contain five items");
  }
  for (std::size_t index = 0; index < 5U; ++index) {
    settings.thresholds[index] =
        ParseFloat(threshold_values[index], "pl_thresholds");
    settings.class_order[index] = classes[index];
  }
  if (settings.port <= 0 || settings.port > 65535 ||
      settings.upstream_port <= 0 || settings.upstream_port > 65535) {
    throw std::runtime_error("port values must be in 1..65535");
  }
  return settings;
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

void SetJson(httplib::Response* response, int status, const json& body) {
  response->status = status;
  response->set_content(body.dump(), "application/json; charset=utf-8");
}

void SetError(httplib::Response* response,
              int status,
              const std::string& message) {
  json body;
  body["error"] = message;
  SetJson(response, status, body);
}

class Gateway {
 public:
  explicit Gateway(const Settings& settings)
      : settings_(settings),
        pl_(settings.pl_sort_base),
        next_event_id_(1U),
        pending_event_id_(0U) {
    for (std::size_t index = 0; index < settings_.class_order.size(); ++index) {
      class_ids_[settings_.class_order[index]] = static_cast<uint8_t>(index);
    }
    ConfigurePl();
  }

  void Predict(const httplib::Request& request, httplib::Response& response) {
    std::lock_guard<std::mutex> lock(mutex_);
    try {
      if (pending_event_id_ != 0U) {
        SetError(&response, 409, "previous PL event is awaiting actuator ACK");
        return;
      }
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
      if (upload.content.size() > settings_.max_upload_bytes) {
        SetError(&response, 413, "image_file exceeds max_upload_bytes");
        return;
      }

      httplib::Client upstream(settings_.upstream_host, settings_.upstream_port);
      upstream.set_connection_timeout(5, 0);
      upstream.set_read_timeout(settings_.upstream_timeout_seconds, 0);
      upstream.set_write_timeout(settings_.upstream_timeout_seconds, 0);
      httplib::MultipartFormDataItems items;
      httplib::MultipartFormData item;
      item.name = "image_file";
      item.content = upload.content;
      item.filename = upload.filename.empty() ? "capture.jpg" : upload.filename;
      item.content_type = upload.content_type.empty()
                              ? "image/jpeg"
                              : upload.content_type;
      items.push_back(item);

      const httplib::Result upstream_result =
          upstream.Post(settings_.upstream_path.c_str(), items);
      if (!upstream_result) {
        SetError(&response, 502, "official inference service is unreachable");
        return;
      }
      if (upstream_result->status != 200) {
        response.status = 502;
        response.set_content(upstream_result->body,
                             "application/json; charset=utf-8");
        return;
      }

      json output = json::parse(upstream_result->body);
      const std::vector<c5mb::PlSortControl::Candidate> candidates =
          ReadCandidates(output);
      const uint32_t event_id = AllocateEventId();
      const c5mb::PlSortControl::Result pl_result =
          pl_.Submit(event_id, true, true, candidates);
      pending_event_id_ = pl_result.event_id;

      output["event_id"] = pl_result.event_id;
      output["decision"] = DecisionName(pl_result.decision);
      output["action"] = ActionName(pl_result.action);
      output["alarm"] = pl_result.alarm;
      output["pl_status"] = pl_result.status;
      output["pl_fault"] = pl_result.fault_code;
      output["pl_swap_sides"] = settings_.pl_swap_sides;
      output["gateway"] = "pl_sort_gateway";
      SetJson(&response, 200, output);
    } catch (const std::exception& error) {
      std::cerr << "predict error: " << error.what() << std::endl;
      SetError(&response, 500, error.what());
    }
  }

  void Acknowledge(const httplib::Request& request,
                   httplib::Response& response) {
    std::lock_guard<std::mutex> lock(mutex_);
    try {
      const json input = json::parse(request.body);
      const uint32_t event_id = input.at("event_id").get<uint32_t>();
      const bool success = input.at("success").get<bool>();
      if (pending_event_id_ == 0U || event_id != pending_event_id_) {
        SetError(&response, 409, "ACK event_id does not match pending event");
        return;
      }
      pl_.Acknowledge(event_id, success);
      pending_event_id_ = 0U;
      json body;
      body["event_id"] = event_id;
      body["acknowledged"] = true;
      body["success"] = success;
      body["pl_status"] = pl_.status();
      body["pl_fault"] = pl_.fault_code();
      SetJson(&response, 200, body);
    } catch (const std::exception& error) {
      SetError(&response, 400, error.what());
    }
  }

  void Health(httplib::Response& response) {
    std::lock_guard<std::mutex> lock(mutex_);
    try {
      json body;
      body["status"] = "ok";
      body["pending_event_id"] = pending_event_id_;
      body["pl_active_event_id"] = pl_.active_event_id();
      body["pl_status"] = pl_.status();
      body["pl_fault"] = pl_.fault_code();
      body["pl_swap_sides"] = settings_.pl_swap_sides;
      body["upstream_host"] = settings_.upstream_host;
      body["upstream_port"] = settings_.upstream_port;
      SetJson(&response, 200, body);
    } catch (const std::exception& error) {
      SetError(&response, 500, error.what());
    }
  }

  void Reset(httplib::Response& response) {
    std::lock_guard<std::mutex> lock(mutex_);
    try {
      ConfigurePl();
      pending_event_id_ = 0U;
      json body;
      body["reset"] = true;
      body["pl_status"] = pl_.status();
      body["pl_fault"] = pl_.fault_code();
      SetJson(&response, 200, body);
    } catch (const std::exception& error) {
      SetError(&response, 500, error.what());
    }
  }

 private:
  void ConfigurePl() {
    uint64_t cycles =
        settings_.pl_sort_clock_hz * settings_.pl_watchdog_ms / 1000ULL;
    if (cycles > std::numeric_limits<uint32_t>::max()) {
      cycles = std::numeric_limits<uint32_t>::max();
    }
    pl_.Initialize(settings_.pl_four_class_mode,
                   static_cast<uint32_t>(cycles),
                   settings_.pl_swap_sides);
    for (std::size_t index = 0; index < settings_.thresholds.size(); ++index) {
      pl_.SetThreshold(static_cast<uint8_t>(index),
                       settings_.thresholds[index]);
    }
  }

  std::vector<c5mb::PlSortControl::Candidate> ReadCandidates(
      const json& output) const {
    std::vector<c5mb::PlSortControl::Candidate> candidates;
    const json& results = output.at("result");
    if (!results.is_array()) {
      throw std::runtime_error("upstream result must be an array");
    }
    for (json::const_iterator item = results.begin(); item != results.end();
         ++item) {
      const std::string class_name = item->at("class_name").get<std::string>();
      const std::map<std::string, uint8_t>::const_iterator class_id =
          class_ids_.find(class_name);
      if (class_id == class_ids_.end()) {
        std::cerr << "ignoring unknown class: " << class_name << std::endl;
        continue;
      }
      c5mb::PlSortControl::Candidate candidate;
      candidate.class_id = class_id->second;
      candidate.score = item->at("score").get<float>();
      candidates.push_back(candidate);
    }
    return candidates;
  }

  uint32_t AllocateEventId() {
    if (next_event_id_ == 0U) {
      next_event_id_ = 1U;
    }
    const uint32_t value = next_event_id_++;
    if (next_event_id_ == 0U) {
      next_event_id_ = 1U;
    }
    return value;
  }

  Settings settings_;
  c5mb::PlSortControl pl_;
  std::map<std::string, uint8_t> class_ids_;
  uint32_t next_event_id_;
  uint32_t pending_event_id_;
  std::mutex mutex_;
};

}  // namespace

int main(int argc, char** argv) {
  try {
    const std::string config_path =
        argc > 1 ? argv[1] : "/opt/pl_sort_gateway/gateway.ini";
    const Settings settings = LoadSettings(config_path);
    Gateway gateway(settings);
    httplib::Server server;
    server.new_task_queue = [] { return new httplib::ThreadPool(2); };
    server.set_payload_max_length(settings.max_upload_bytes + 65536U);
    server.set_read_timeout(30, 0);
    server.set_write_timeout(30, 0);
    server.Get("/health", [&](const httplib::Request&, httplib::Response& res) {
      gateway.Health(res);
    });
    server.Post("/predict", [&](const httplib::Request& req,
                                httplib::Response& res) {
      gateway.Predict(req, res);
    });
    server.Post("/ack", [&](const httplib::Request& req,
                            httplib::Response& res) {
      gateway.Acknowledge(req, res);
    });
    server.Post("/reset", [&](const httplib::Request&, httplib::Response& res) {
      gateway.Reset(res);
    });
    std::cout << "PL sort gateway listening on " << settings.bind_address << ':'
              << settings.port << std::endl;
    if (!server.listen(settings.bind_address.c_str(), settings.port)) {
      throw std::runtime_error("HTTP listen failed");
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "fatal: " << error.what() << std::endl;
    return 1;
  }
}
