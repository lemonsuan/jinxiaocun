#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace ppocrv6 {
struct Box {
    float center_x = 0, center_y = 0, width = 0, height = 0, angle = 0, confidence = 0;
};
struct Result {
    std::string text;
    float confidence = 0;
    Box box;
};
struct Statistics {
    double detection_ms = 0, recognition_ms = 0, total_ms = 0;
    int detector_width = 0, detector_height = 0;
};
class Engine {
  public:
    Engine(const std::string &detector, const std::string &recognizer,
           const std::string &dictionary, int threads = 2);
    ~Engine();
    Engine(const Engine &) = delete;
    Engine &operator=(const Engine &) = delete;
    std::vector<Result> Process(const uint8_t *rgba, int width, int height, int stride,
                                int64_t timeout_ms = 35000);
    const Statistics &statistics() const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace ppocrv6
