// Host harness exercises the same production OCR core used by Android JNI.
#include "ocr_v6_engine.h"
#include <fstream>
#include <chrono>
#include <sys/resource.h>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

static void JsonString(const std::string& value) {
  std::cout << '"';
  for (const unsigned char c : value) {
    switch (c) {
      case '"': std::cout << "\\\""; break;
      case '\\': std::cout << "\\\\"; break;
      case '\n': std::cout << "\\n"; break;
      case '\r': std::cout << "\\r"; break;
      case '\t': std::cout << "\\t"; break;
      default:
        if (c < 0x20) throw std::runtime_error("Unexpected control character in OCR output");
        std::cout << c;
    }
  }
  std::cout << '"';
}

int main(int argc, char** argv) {
  try {
    if (argc != 7 && argc != 8) throw std::runtime_error("det rec keys width height rgba_file required");
    const int width = std::stoi(argv[4]);
    const int height = std::stoi(argv[5]);
    if (width <= 0 || height <= 0 || width > 10000 || height > 10000)
      throw std::runtime_error("Invalid image dimensions");
    std::ifstream input(argv[6], std::ios::binary);
    if (!input) throw std::runtime_error("Cannot read RGBA fixture");
    const std::vector<uint8_t> rgba((std::istreambuf_iterator<char>(input)), {});
    if (rgba.size() != static_cast<size_t>(width) * height * 4)
      throw std::runtime_error("Invalid RGBA fixture size");
    const auto begin = std::chrono::steady_clock::now();
    ppocrv6::Engine engine(argv[1], argv[2], argv[3], 2);
    if (argc == 8 && std::string(argv[7]) == "timeouts") {
      for (const int timeout : {0, 1, 20}) {
        bool cancelled = false;
        try { engine.Process(rgba.data(), width, height, width * 4, timeout); }
        catch (const std::exception&) { cancelled = true; }
        if (!cancelled) throw std::runtime_error("Deadline did not cancel inference");
      }
    }
    const auto results = engine.Process(rgba.data(), width, height, width * 4);
    std::cout << "[";
    bool first = true;
    for (const auto& result : results) {
      if (!first) std::cout << ",";
      first = false;
      std::cout << "{\"text\":";
      JsonString(result.text);
      std::cout << ",\"confidence\":" << result.confidence
                << ",\"box\":{\"centerX\":" << result.box.center_x
                << ",\"centerY\":" << result.box.center_y
                << ",\"width\":" << result.box.width
                << ",\"height\":" << result.box.height
                << ",\"angle\":" << result.box.angle << "}}";
    }
    std::cout << "]\n";
    struct rusage usage {};
    getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
    const auto peak_bytes = usage.ru_maxrss;
#else
    const auto peak_bytes = usage.ru_maxrss * 1024L;
#endif
    const auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
    std::cerr << "HOST_METRICS {\"peak_rss_bytes\":" << peak_bytes
              << ",\"wall_seconds\":" << elapsed
              << ",\"detection_ms\":" << engine.statistics().detection_ms
              << ",\"recognition_ms\":" << engine.statistics().recognition_ms << "}\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "OCR fixture failed: " << error.what() << '\n';
    return 1;
  }
}
