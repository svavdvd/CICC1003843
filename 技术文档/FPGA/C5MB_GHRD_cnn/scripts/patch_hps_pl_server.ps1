param(
    [string]$Path = (Join-Path $PSScriptRoot '..\deploy\fpga_hps\ssd_detection_pl.cc')
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")

function Replace-Once {
    param([string]$Source, [string]$Old, [string]$New, [string]$Label)
    $count = ([regex]::Matches($Source, [regex]::Escape($Old))).Count
    if ($count -ne 1) {
        throw "$Label expected exactly one match, found $count"
    }
    return $Source.Replace($Old, $New)
}

$text = Replace-Once $text @'
#include "httplib.h"
#include "intelfpga.h"
#include "json.hpp"
'@ @'
#include "httplib.h"
#include "json.hpp"
#include "pl_sort_control.hpp"
'@ 'includes'

$text = Replace-Once $text @'
long ParseLong(const std::string& value, const std::string& key) {
  char* end = NULL;
  errno = 0;
  const long result = std::strtol(value.c_str(), &end, 0);
  if (errno != 0 || end == value.c_str() || *end != '\0') {
    throw std::runtime_error("invalid integer for " + key + ": " + value);
  }
  return result;
}
'@ @'
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
'@ 'integer parsers'

$text = Replace-Once $text @'
  return result;
}

struct Settings {
'@ @'
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
'@ 'five-value parser'

$text = Replace-Once $text @'
  float score_threshold = 0.2f;
  std::string input_color_order = "bgr";
'@ @'
  float score_threshold = 0.2f;
  bool pl_sort_enabled = true;
  bool pl_four_class_mode = false;
  uint64_t pl_sort_base = c5mb::PlSortControl::kDefaultPhysicalBase;
  uint64_t pl_sort_clock_hz = 50000000ULL;
  uint64_t pl_watchdog_ms = 30000ULL;
  std::array<float, 5> pl_thresholds{{0.70f, 0.70f, 0.70f, 0.20f,
                                      0.70f}};
  std::string input_color_order = "bgr";
'@ 'settings fields'

$text = Replace-Once $text @'
  settings.score_threshold = ParseFloat(
      GetValue(values, "score_threshold", "0.2"), "score_threshold");
  settings.input_color_order =
'@ @'
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
'@ 'settings parsing'

$text = Replace-Once $text @'
  if (settings.score_threshold < 0.0f || settings.score_threshold > 1.0f) {
    throw std::runtime_error("score_threshold must be in [0,1]");
  }
  if (settings.input_color_order != "bgr" &&
'@ @'
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
'@ 'settings validation'

$text = Replace-Once $text @'
json ReadDetections(PaddlePredictor* predictor,
                    const Settings& settings,
                    const std::vector<std::string>& labels,
                    int image_width,
                    int image_height,
                    double prediction_ms) {
'@ @'
json ReadDetections(
    PaddlePredictor* predictor,
    const Settings& settings,
    const std::vector<std::string>& labels,
    int image_width,
    int image_height,
    double prediction_ms,
    std::vector<c5mb::PlSortControl::Candidate>* candidates) {
'@ 'detection signature'

$text = Replace-Once $text @'
    item["prediction_time"] = prediction_ms;
    results.push_back(item);
'@ @'
    item["prediction_time"] = prediction_ms;
    results.push_back(item);

    c5mb::PlSortControl::Candidate candidate;
    candidate.class_id = static_cast<uint8_t>(class_id);
    candidate.score = score;
    candidates->push_back(candidate);
'@ 'candidate collection'

$text = Replace-Once $text @'
json RunModel(PaddlePredictor* predictor,
              const Settings& settings,
              const std::vector<std::string>& labels,
              const cv::Mat& image) {
'@ @'
json RunModel(
    PaddlePredictor* predictor,
    const Settings& settings,
    const std::vector<std::string>& labels,
    const cv::Mat& image,
    std::vector<c5mb::PlSortControl::Candidate>* candidates) {
'@ 'run model signature'

$text = Replace-Once $text @'
  return ReadDetections(predictor, settings, labels, image.cols, image.rows,
                        prediction_ms);
}

void SetJson(httplib::Response* response, int status, const json& value) {
'@ @'
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
'@ 'PL result helpers'

$oldMain = $text.Substring($text.IndexOf('int main(int argc, char** argv) {'))
if (-not $oldMain.StartsWith('int main(int argc, char** argv) {')) {
    throw 'main function start not found'
}

$newMain = @'
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
'@

$text = $text.Substring(0, $text.Length - $oldMain.Length) + $newMain + "`n"
[IO.File]::WriteAllText($Path, $text, $utf8)
Write-Host "Patched HPS PL predict server: $Path"
