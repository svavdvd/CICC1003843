#ifndef C5MB_PL_SORT_CONTROL_HPP
#define C5MB_PL_SORT_CONTROL_HPP

#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

namespace c5mb {

class PlSortControl {
 public:
  static const uint64_t kDefaultPhysicalBase = 0xFF200800ULL;
  static const uint32_t kExpectedId = 0x534F5254U;
  static const uint32_t kExpectedVersion = 0x00010000U;

  enum Decision {
    kDecisionUnknown = 0,
    kDecisionOk = 1,
    kDecisionNg = 2,
  };

  enum Action {
    kActionHold = 0,
    kActionSortRight = 1,
    kActionSortLeft = 2,
  };

  struct Candidate {
    uint8_t class_id;
    float score;
  };

  struct Result {
    uint32_t event_id;
    Decision decision;
    Action action;
    bool alarm;
    uint32_t status;
    uint32_t fault_code;
  };

  explicit PlSortControl(uint64_t physical_base = kDefaultPhysicalBase)
      : fd_(-1), mapping_(MAP_FAILED), mapping_bytes_(0), registers_(NULL) {
    const long page_size_value = sysconf(_SC_PAGESIZE);
    if (page_size_value <= 0) {
      throw std::runtime_error("sysconf(_SC_PAGESIZE) failed");
    }
    const std::size_t page_size =
        static_cast<std::size_t>(page_size_value);
    const uint64_t page_mask = static_cast<uint64_t>(page_size - 1U);
    const uint64_t page_base = physical_base & ~page_mask;
    const std::size_t page_offset =
        static_cast<std::size_t>(physical_base - page_base);
    mapping_bytes_ = page_offset + kRegisterSpanBytes;

    fd_ = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_ < 0) {
      ThrowSystemError("open /dev/mem");
    }
    mapping_ = mmap(NULL, mapping_bytes_, PROT_READ | PROT_WRITE, MAP_SHARED,
                    fd_, static_cast<off_t>(page_base));
    if (mapping_ == MAP_FAILED) {
      const int saved_errno = errno;
      close(fd_);
      fd_ = -1;
      errno = saved_errno;
      ThrowSystemError("mmap PL sort control");
    }
    registers_ = reinterpret_cast<volatile uint32_t*>(
        static_cast<uint8_t*>(mapping_) + page_offset);
  }

  ~PlSortControl() {
    if (mapping_ != MAP_FAILED) {
      munmap(mapping_, mapping_bytes_);
    }
    if (fd_ >= 0) {
      close(fd_);
    }
  }

  void Initialize(bool four_class_mode,
                  uint32_t watchdog_cycles = 1500000000U,
                  bool swap_sides = false) {
    const uint32_t id = Read(kRegId);
    const uint32_t version = Read(kRegVersion);
    if (id != kExpectedId) {
      throw std::runtime_error("PL sort_control ID mismatch: " + Hex(id));
    }
    if (version != kExpectedVersion) {
      throw std::runtime_error("PL sort_control version mismatch: " +
                               Hex(version));
    }

    Write(kRegControl, kControlEnable | kControlReset |
                           (four_class_mode ? kControlFourClass : 0U) |
                           (swap_sides ? kControlSwapSides : 0U));
    Write(kRegControl, kControlEnable |
                           (four_class_mode ? kControlFourClass : 0U) |
                           (swap_sides ? kControlSwapSides : 0U));
    Write(kRegWatchdogLimit, watchdog_cycles);
    ClearFault();
  }

  void SetThreshold(uint8_t class_id, float score) {
    if (class_id > 4U) {
      throw std::runtime_error("PL threshold class_id must be in 0..4");
    }
    Write(static_cast<Register>(kRegThreshold0 + class_id),
          EncodeScore(score));
  }

  Result Submit(uint32_t event_id,
                bool inference_ok,
                bool workpiece_present,
                const std::vector<Candidate>& candidates) {
    uint32_t status = Read(kRegStatus);
    if ((status & kStatusFault) != 0U) {
      throw std::runtime_error("PL sort_control fault before submit: " +
                               Hex((status >> 16U) & 0xFU));
    }
    if ((status & kStatusReady) == 0U) {
      throw std::runtime_error("PL sort_control is not ready: " + Hex(status));
    }

    Write(kRegEventId, event_id);
    Write(kRegEventFlags, (inference_ok ? 1U : 0U) |
                              (workpiece_present ? 2U : 0U));
    Write(kRegCommand, kCommandStartEvent);

    for (std::size_t index = 0; index < candidates.size(); ++index) {
      if (candidates[index].class_id > 4U) {
        throw std::runtime_error("candidate class_id must be in 0..4");
      }
      const uint32_t packed =
          (EncodeScore(candidates[index].score) << 16U) |
          static_cast<uint32_t>(candidates[index].class_id);
      Write(kRegCandidate, packed);
      Write(kRegCommand, kCommandPushCandidate);
    }

    Write(kRegCommand, kCommandCommitEvent);
    status = Read(kRegStatus);
    Result result;
    result.event_id = Read(kRegCommandEvent);
    result.decision = static_cast<Decision>(Read(kRegDecision) & 0x7U);
    result.action = static_cast<Action>(Read(kRegAction) & 0x7U);
    result.alarm = (Read(kRegAlarm) & 0x1U) != 0U;
    result.status = status;
    result.fault_code = Read(kRegFaultCode) & 0xFU;

    if (result.event_id != event_id) {
      throw std::runtime_error("PL sort_control event ID mismatch");
    }
    if ((status & kStatusFault) != 0U || result.fault_code != 0U) {
      throw std::runtime_error("PL sort_control submit fault: " +
                               Hex(result.fault_code));
    }
    if ((status & kStatusCommandValid) == 0U ||
        (status & kStatusAwaitingAck) == 0U) {
      throw std::runtime_error("PL sort_control did not publish a command");
    }
    return result;
  }

  void Acknowledge(uint32_t event_id, bool success) {
    const uint32_t active_event = Read(kRegCommandEvent);
    if (active_event != event_id) {
      throw std::runtime_error("PL ACK event ID mismatch");
    }
    Write(kRegEventId, event_id);
    Write(kRegCommand,
          success ? kCommandAckDone : kCommandAckFailed);
    const uint32_t status = Read(kRegStatus);
    if (success && (status & kStatusFault) != 0U) {
      throw std::runtime_error("PL sort_control rejected ACK: " +
                               Hex(Read(kRegFaultCode) & 0xFU));
    }
  }

  void ClearFault() { Write(kRegCommand, kCommandClearFault); }

  uint32_t status() const { return Read(kRegStatus); }
  uint32_t active_event_id() const { return Read(kRegCommandEvent); }
  uint32_t fault_code() const { return Read(kRegFaultCode) & 0xFU; }

 private:
  enum Register {
    kRegId = 0x00,
    kRegVersion = 0x01,
    kRegControl = 0x02,
    kRegStatus = 0x03,
    kRegEventId = 0x04,
    kRegEventFlags = 0x05,
    kRegCandidate = 0x06,
    kRegCommand = 0x07,
    kRegDecision = 0x08,
    kRegAction = 0x09,
    kRegAlarm = 0x0A,
    kRegCommandEvent = 0x0B,
    kRegWatchdogLimit = 0x0C,
    kRegFaultCode = 0x0E,
    kRegThreshold0 = 0x10,
  };

  static const std::size_t kRegisterSpanBytes = 0x100U;
  static const uint32_t kControlEnable = 1U << 0;
  static const uint32_t kControlReset = 1U << 1;
  static const uint32_t kControlFourClass = 1U << 2;
  static const uint32_t kControlSwapSides = 1U << 3;
  static const uint32_t kStatusReady = 1U << 0;
  static const uint32_t kStatusCommandValid = 1U << 2;
  static const uint32_t kStatusAwaitingAck = 1U << 3;
  static const uint32_t kStatusFault = 1U << 4;
  static const uint32_t kCommandStartEvent = 1U << 0;
  static const uint32_t kCommandPushCandidate = 1U << 1;
  static const uint32_t kCommandCommitEvent = 1U << 2;
  static const uint32_t kCommandAckDone = 1U << 3;
  static const uint32_t kCommandAckFailed = 1U << 4;
  static const uint32_t kCommandClearFault = 1U << 5;

  static uint32_t EncodeScore(float score) {
    if (!std::isfinite(score) || score < 0.0f || score > 1.0f) {
      throw std::runtime_error("candidate score must be finite and in [0,1]");
    }
    return static_cast<uint32_t>(std::floor(score * 65535.0f + 0.5f));
  }

  uint32_t Read(Register address) const {
    const uint32_t value = registers_[static_cast<uint32_t>(address)];
    __sync_synchronize();
    return value;
  }

  void Write(Register address, uint32_t value) {
    registers_[static_cast<uint32_t>(address)] = value;
    __sync_synchronize();
  }

  static std::string Hex(uint32_t value) {
    static const char digits[] = "0123456789ABCDEF";
    std::string result("0x00000000");
    for (int index = 0; index < 8; ++index) {
      result[9 - index] = digits[value & 0xFU];
      value >>= 4U;
    }
    return result;
  }

  static void ThrowSystemError(const std::string& operation) {
    throw std::runtime_error(operation + " failed: " + std::strerror(errno));
  }

  PlSortControl(const PlSortControl&);
  PlSortControl& operator=(const PlSortControl&);

  int fd_;
  void* mapping_;
  std::size_t mapping_bytes_;
  volatile uint32_t* registers_;
};

}  // namespace c5mb

#endif  // C5MB_PL_SORT_CONTROL_HPP
