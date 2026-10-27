// Project-owned PP-OCRv6_small CPU preprocessing, DB geometry and CTC pipeline.
// Model preprocessing parameters follow the official inference.yml assets.
#include "ocr_v6_engine.h"
#include "onnxruntime_c_api.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <fstream>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>

namespace ppocrv6 {
namespace {
using Clock = std::chrono::steady_clock;
constexpr float kPi = 3.14159265358979323846f;
constexpr int kDetectorMaxSide = 960;
constexpr int kRecognitionMaxWidth = 3200;
constexpr int kMaxBoxes = 1000;
struct Point {
    float x, y;
};
struct Quad {
    std::array<Point, 4> points;
    Box box;
};
float Cross(Point a, Point b, Point c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}
std::vector<Point> Hull(std::vector<Point> points) {
    std::sort(points.begin(), points.end(),
              [](Point a, Point b) { return a.x < b.x || (a.x == b.x && a.y < b.y); });
    points.erase(std::unique(points.begin(), points.end(),
                             [](Point a, Point b) { return a.x == b.x && a.y == b.y; }),
                 points.end());
    if (points.size() < 3)
        return points;
    std::vector<Point> hull;
    for (const auto p : points) {
        while (hull.size() > 1 && Cross(hull[hull.size() - 2], hull.back(), p) <= 0)
            hull.pop_back();
        hull.push_back(p);
    }
    const auto lower = hull.size();
    for (auto i = points.rbegin() + 1; i != points.rend(); ++i) {
        while (hull.size() > lower && Cross(hull[hull.size() - 2], hull.back(), *i) <= 0)
            hull.pop_back();
        hull.push_back(*i);
    }
    hull.pop_back();
    return hull;
}
Box MinimumBox(std::vector<Point> points) {
    const auto hull = Hull(std::move(points));
    Box best;
    float bestArea = std::numeric_limits<float>::max();
    for (size_t i = 0; i < hull.size(); ++i) {
        const auto a = hull[i], b = hull[(i + 1) % hull.size()];
        const float length = std::hypot(b.x - a.x, b.y - a.y);
        if (length < .001f)
            continue;
        const float ux = (b.x - a.x) / length, uy = (b.y - a.y) / length;
        float minU = INFINITY, maxU = -INFINITY, minV = INFINITY, maxV = -INFINITY;
        for (auto p : hull) {
            const float u = p.x * ux + p.y * uy, v = -p.x * uy + p.y * ux;
            minU = std::min(minU, u);
            maxU = std::max(maxU, u);
            minV = std::min(minV, v);
            maxV = std::max(maxV, v);
        }
        const float w = maxU - minU + 1, h = maxV - minV + 1;
        if (w * h < bestArea) {
            bestArea = w * h;
            const float cu = (minU + maxU) / 2, cv = (minV + maxV) / 2;
            best = {cu * ux - cv * uy, cu * uy + cv * ux, w, h, std::atan2(uy, ux) * 180 / kPi, 0};
        }
    }
    if (best.width < best.height) {
        std::swap(best.width, best.height);
        best.angle += 90;
    }
    while (best.angle > 90)
        best.angle -= 180;
    while (best.angle < -90)
        best.angle += 180;
    return best;
}
std::array<Point, 4> Corners(const Box &box) {
    const float c = std::cos(box.angle * kPi / 180), s = std::sin(box.angle * kPi / 180),
                w = box.width / 2, h = box.height / 2;
    return {{{box.center_x - w * c + h * s, box.center_y - w * s - h * c},
             {box.center_x + w * c + h * s, box.center_y + w * s - h * c},
             {box.center_x + w * c - h * s, box.center_y + w * s + h * c},
             {box.center_x - w * c - h * s, box.center_y - w * s + h * c}}};
}
float Sample(const uint8_t *rgba, int width, int height, int stride, float x, float y, int bgr) {
    x = std::clamp(x, 0.f, float(width - 1));
    y = std::clamp(y, 0.f, float(height - 1));
    const int x0 = int(x), y0 = int(y), x1 = std::min(x0 + 1, width - 1),
              y1 = std::min(y0 + 1, height - 1), channel = 2 - bgr;
    const float dx = x - x0, dy = y - y0;
    return rgba[y0 * stride + x0 * 4 + channel] * (1 - dx) * (1 - dy) +
           rgba[y0 * stride + x1 * 4 + channel] * dx * (1 - dy) +
           rgba[y1 * stride + x0 * 4 + channel] * (1 - dx) * dy +
           rgba[y1 * stride + x1 * 4 + channel] * dx * dy;
}
std::vector<Quad> DetectBoxes(const float *probability, int mapWidth, int mapHeight, int imageWidth,
                              int imageHeight) {
    const int size = mapWidth * mapHeight;
    std::vector<uint8_t> seen(size, 0);
    std::vector<int> queue;
    std::vector<Quad> result;
    const int dx[] = {-1, 1, 0, 0}, dy[] = {0, 0, -1, 1};
    for (int start = 0; start < size; ++start) {
        if (seen[start] || probability[start] < .2f)
            continue;
        queue.clear();
        queue.push_back(start);
        seen[start] = 1;
        std::vector<Point> boundary;
        for (size_t i = 0; i < queue.size(); ++i) {
            const int index = queue[i], x = index % mapWidth, y = index / mapWidth;
            bool edge = false;
            for (int d = 0; d < 4; ++d) {
                const int nx = x + dx[d], ny = y + dy[d];
                if (nx < 0 || ny < 0 || nx >= mapWidth || ny >= mapHeight) {
                    edge = true;
                    continue;
                }
                const int n = ny * mapWidth + nx;
                if (probability[n] < .2f) {
                    edge = true;
                    continue;
                }
                if (!seen[n]) {
                    seen[n] = 1;
                    queue.push_back(n);
                }
            }
            if (edge)
                boundary.push_back({float(x), float(y)});
        }
        if (queue.size() < 6 || boundary.size() < 3)
            continue;
        auto box = MinimumBox(std::move(boundary));
        if (box.width < 3 || box.height < 3)
            continue;
        const auto corners = Corners(box);
        float left = INFINITY, right = -INFINITY, top = INFINITY, bottom = -INFINITY;
        for (auto p : corners) {
            left = std::min(left, p.x);
            right = std::max(right, p.x);
            top = std::min(top, p.y);
            bottom = std::max(bottom, p.y);
        }
        const float c = std::cos(box.angle * kPi / 180), s = std::sin(box.angle * kPi / 180);
        double sum = 0;
        int count = 0;
        for (int y = std::max(0, int(std::floor(top)));
             y <= std::min(mapHeight - 1, int(std::ceil(bottom))); ++y)
            for (int x = std::max(0, int(std::floor(left)));
                 x <= std::min(mapWidth - 1, int(std::ceil(right))); ++x) {
                const float px = x - box.center_x, py = y - box.center_y;
                if (std::abs(px * c + py * s) <= box.width / 2 &&
                    std::abs(-px * s + py * c) <= box.height / 2) {
                    sum += probability[y * mapWidth + x];
                    ++count;
                }
            }
        if (!count || sum / count < .45)
            continue;
        box.confidence = float(sum / count);
        const float expansion = box.width * box.height * 1.4f / (2 * (box.width + box.height));
        box.width += 2 * expansion;
        box.height += 2 * expansion;
        auto expanded = Corners(box);
        for (auto &p : expanded) {
            p.x = std::clamp(p.x * imageWidth / mapWidth, 0.f, float(imageWidth - 1));
            p.y = std::clamp(p.y * imageHeight / mapHeight, 0.f, float(imageHeight - 1));
        }
        // Refit after mapping to preserve row grouping geometry when rounded resize scales differ.
        std::vector<Point> mapped(expanded.begin(), expanded.end());
        auto finalBox = MinimumBox(std::move(mapped));
        finalBox.confidence = box.confidence;
        if (result.size() >= kMaxBoxes) {
            throw std::runtime_error(
                "Document exceeds bounded text count; crop the image and retry");
        }
        result.push_back({expanded, finalBox});
    }
    std::sort(result.begin(), result.end(), [](const Quad &a, const Quad &b) {
        return a.box.center_y < b.box.center_y ||
               (a.box.center_y == b.box.center_y && a.box.center_x < b.box.center_x);
    });
    return result;
}
} // namespace

struct Engine::Impl {
    const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    OrtEnv *env = nullptr;
    OrtSession *detector = nullptr;
    OrtSession *recognizer = nullptr;
    OrtMemoryInfo *memory = nullptr;
    std::string detectorInput, detectorOutput, recognizerInput, recognizerOutput;
    std::vector<std::string> dictionary;
    std::vector<float> input;
    Statistics stats;
    OrtRunOptions *currentRunOptions = nullptr;
    void Check(OrtStatus *status) const {
        if (status) {
            const std::string message = api->GetErrorMessage(status);
            api->ReleaseStatus(status);
            throw std::runtime_error(message);
        }
    }
    void Clear() {
        if (detector)
            api->ReleaseSession(detector);
        if (recognizer)
            api->ReleaseSession(recognizer);
        if (memory)
            api->ReleaseMemoryInfo(memory);
        if (env)
            api->ReleaseEnv(env);
        detector = nullptr;
        recognizer = nullptr;
        memory = nullptr;
        env = nullptr;
    }
    ~Impl() { Clear(); }
    std::string Name(OrtSession *session, bool output) {
        OrtAllocator *allocator = nullptr;
        Check(api->GetAllocatorWithDefaultOptions(&allocator));
        char *name = nullptr;
        Check(output ? api->SessionGetOutputName(session, 0, allocator, &name)
                     : api->SessionGetInputName(session, 0, allocator, &name));
        const std::string result(name);
        allocator->Free(allocator, name);
        return result;
    }
    void Initialize(const std::string &det, const std::string &rec, const std::string &keys,
                    int threads) {
        if (!api)
            throw std::runtime_error("ONNX Runtime API version mismatch");
        std::ifstream stream(keys);
        if (!stream)
            throw std::runtime_error("Missing v6 dictionary");
        std::string line;
        while (std::getline(stream, line)) {
            if (!line.empty() && line.back() == '\r')
                line.pop_back();
            dictionary.push_back(line);
        }
        if (dictionary.size() != 18709)
            throw std::runtime_error("PP-OCRv6_small dictionary class count mismatch");
        Check(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "inventory-ocr-v6", &env));
        OrtSessionOptions *options = nullptr;
        Check(api->CreateSessionOptions(&options));
        try {
            Check(api->SetIntraOpNumThreads(options, std::clamp(threads, 1, 4)));
            Check(api->SetInterOpNumThreads(options, 1));
            Check(api->SetSessionExecutionMode(options, ORT_SEQUENTIAL));
            Check(api->SetSessionGraphOptimizationLevel(options, ORT_DISABLE_ALL));
            // ORT files are optimized offline. Disable arenas to avoid retaining peak document
            // allocations.
            Check(api->DisableCpuMemArena(options));
            Check(api->DisableMemPattern(options));
            Check(api->CreateSession(env, det.c_str(), options, &detector));
            Check(api->CreateSession(env, rec.c_str(), options, &recognizer));
            api->ReleaseSessionOptions(options);
        } catch (...) {
            api->ReleaseSessionOptions(options);
            throw;
        }
        detectorInput = Name(detector, false);
        detectorOutput = Name(detector, true);
        recognizerInput = Name(recognizer, false);
        recognizerOutput = Name(recognizer, true);
        Check(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));
    }
    struct Output {
        const OrtApi *api;
        OrtValue *value = nullptr;
        ~Output() {
            if (value)
                api->ReleaseValue(value);
        }
    };
    void Run(OrtSession *session, const std::string &inputName, const std::string &outputName,
             const std::array<int64_t, 4> &shape, Output &output) {
        OrtValue *tensor = nullptr;
        Check(api->CreateTensorWithDataAsOrtValue(
            memory, input.data(), input.size() * sizeof(float), shape.data(), shape.size(),
            ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor));
        const char *inputs[] = {inputName.c_str()};
        const char *outputs[] = {outputName.c_str()};
        const OrtValue *values[] = {tensor};
        auto *status =
            api->Run(session, currentRunOptions, inputs, values, 1, outputs, 1, &output.value);
        api->ReleaseValue(tensor);
        Check(status);
    }
    std::vector<int64_t> Shape(OrtValue *value) {
        OrtTensorTypeAndShapeInfo *info = nullptr;
        Check(api->GetTensorTypeAndShape(value, &info));
        try {
            ONNXTensorElementDataType type;
            Check(api->GetTensorElementType(info, &type));
            if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
                throw std::runtime_error("Unexpected OCR tensor type");
            size_t rank = 0;
            Check(api->GetDimensionsCount(info, &rank));
            std::vector<int64_t> shape(rank);
            Check(api->GetDimensions(info, shape.data(), rank));
            api->ReleaseTensorTypeAndShapeInfo(info);
            return shape;
        } catch (...) {
            api->ReleaseTensorTypeAndShapeInfo(info);
            throw;
        }
    }
    std::pair<std::string, float> Recognize(const uint8_t *rgba, int width, int height, int stride,
                                            const Quad &quad) {
        auto points = quad.points;
        float lineWidth =
            std::max(std::hypot(points[1].x - points[0].x, points[1].y - points[0].y),
                     std::hypot(points[2].x - points[3].x, points[2].y - points[3].y));
        float lineHeight =
            std::max(std::hypot(points[3].x - points[0].x, points[3].y - points[0].y),
                     std::hypot(points[2].x - points[1].x, points[2].y - points[1].y));
        // The rectangle's long edge is the text direction; no JPEG/bitmap intermediate allocation.
        if (lineHeight > lineWidth) {
            std::rotate(points.begin(), points.begin() + 1, points.end());
            std::swap(lineWidth, lineHeight);
        }
        const int target = std::max(8, int(std::ceil(48 * lineWidth / std::max(1.f, lineHeight))));
        if (target > kRecognitionMaxWidth)
            throw std::runtime_error(
                "Text line exceeds bounded v6 input; crop the document or retry closer");
        const int modelWidth = std::max(32, ((target + 7) / 8) * 8);
        input.assign(size_t(3) * 48 * modelWidth, 0.f);
        for (int y = 0; y < 48; ++y) {
            const float v = float(y) / 47;
            for (int x = 0; x < target; ++x) {
                const float u = target == 1 ? 0 : float(x) / (target - 1);
                const float px = (1 - u) * (1 - v) * points[0].x + u * (1 - v) * points[1].x +
                                 u * v * points[2].x + (1 - u) * v * points[3].x;
                const float py = (1 - u) * (1 - v) * points[0].y + u * (1 - v) * points[1].y +
                                 u * v * points[2].y + (1 - u) * v * points[3].y;
                for (int channel = 0; channel < 3; ++channel)
                    input[size_t(channel) * 48 * modelWidth + y * modelWidth + x] =
                        (Sample(rgba, width, height, stride, px, py, channel) / 255.f - .5f) / .5f;
            }
        }
        Output output{api};
        Run(recognizer, recognizerInput, recognizerOutput, {1, 3, 48, modelWidth}, output);
        const auto shape = Shape(output.value);
        if (shape.size() != 3 || shape[0] != 1 || shape[2] != int64_t(dictionary.size() + 1))
            throw std::runtime_error("Unexpected v6 recognition output");
        float *data = nullptr;
        Check(api->GetTensorMutableData(output.value, reinterpret_cast<void **>(&data)));
        std::string text;
        double score = 0;
        int count = 0, previous = 0;
        for (int64_t t = 0; t < shape[1]; ++t) {
            const float *row = data + t * shape[2];
            const int best = int(std::max_element(row, row + shape[2]) - row);
            if (best != 0 && best != previous) {
                text += dictionary.at(best - 1);
                score += row[best];
                ++count;
            }
            previous = best;
        }
        return {text, count ? float(score / count) : 0.f};
    }
};
Engine::Engine(const std::string &det, const std::string &rec, const std::string &dict, int threads)
    : impl_(std::make_unique<Impl>()) {
    impl_->Initialize(det, rec, dict, threads);
}
Engine::~Engine() = default;
const Statistics &Engine::statistics() const { return impl_->stats; }
std::vector<Result> Engine::Process(const uint8_t *rgba, int width, int height, int stride,
                                    int64_t timeout_ms) {
    if (timeout_ms <= 0)
        throw std::runtime_error("OCR request expired");
    if (!rgba || width < 2 || height < 2 || width > 8192 || height > 8192 || stride < width * 4)
        throw std::invalid_argument("Invalid OCR RGBA image");
    auto &impl = *impl_;
    impl.stats = {};
    const auto start = Clock::now();
    struct Deadline {
        Impl &impl;
        OrtRunOptions *options = nullptr;
        std::mutex mutex;
        std::condition_variable cv;
        bool completed = false;
        std::thread watchdog;
        Clock::time_point end;
        Deadline(Impl &owner, int64_t timeout)
            : impl(owner), end(Clock::now() + std::chrono::milliseconds(timeout)) {
            impl.Check(impl.api->CreateRunOptions(&options));
            try {
                watchdog = std::thread([this] {
                    std::unique_lock<std::mutex> lock(mutex);
                    if (!cv.wait_until(lock, end, [this] { return completed; })) {
                        // ORT explicitly supports terminating a Run from another thread.
                        auto *status = impl.api->RunOptionsSetTerminate(options);
                        if (status)
                            impl.api->ReleaseStatus(status);
                    }
                });
                impl.currentRunOptions = options;
            } catch (...) {
                impl.api->ReleaseRunOptions(options);
                throw;
            }
        }
        void Check() const {
            if (Clock::now() >= end)
                throw std::runtime_error("OCR request expired");
        }
        ~Deadline() {
            {
                std::lock_guard<std::mutex> lock(mutex);
                completed = true;
            }
            cv.notify_all();
            if (watchdog.joinable())
                watchdog.join();
            impl.currentRunOptions = nullptr;
            impl.api->ReleaseRunOptions(options);
        }
    } deadline(impl, timeout_ms);
    const float scale = std::min(1.f, float(kDetectorMaxSide) / std::max(width, height));
    const int dw = std::max(32, int(std::round(width * scale / 32)) * 32),
              dh = std::max(32, int(std::round(height * scale / 32)) * 32);
    impl.stats.detector_width = dw;
    impl.stats.detector_height = dh;
    impl.input.resize(size_t(3) * dw * dh);
    const float mean[] = {.485f, .456f, .406f}, stddev[] = {.229f, .224f, .225f};
    for (int y = 0; y < dh; ++y) {
        deadline.Check();
        for (int x = 0; x < dw; ++x) {
            const float px = (x + .5f) * width / dw - .5f, py = (y + .5f) * height / dh - .5f;
            for (int c = 0; c < 3; ++c)
                impl.input[size_t(c) * dw * dh + y * dw + x] =
                    (Sample(rgba, width, height, stride, px, py, c) / 255.f - mean[c]) / stddev[c];
        }
    }
    deadline.Check();
    Impl::Output output{impl.api};
    impl.Run(impl.detector, impl.detectorInput, impl.detectorOutput, {1, 3, dh, dw}, output);
    const auto shape = impl.Shape(output.value);
    if (shape.size() != 4 || shape[0] != 1 || shape[1] != 1 || shape[2] < 1 || shape[3] < 1 ||
        shape[2] > 2048 || shape[3] > 2048)
        throw std::runtime_error("Unexpected v6 detection output");
    float *probability = nullptr;
    impl.Check(
        impl.api->GetTensorMutableData(output.value, reinterpret_cast<void **>(&probability)));
    deadline.Check();
    const auto boxes = DetectBoxes(probability, int(shape[3]), int(shape[2]), width, height);
    impl.api->ReleaseValue(output.value);
    output.value = nullptr;
    const auto detEnd = Clock::now();
    impl.stats.detection_ms = std::chrono::duration<double, std::milli>(detEnd - start).count();
    std::vector<Result> results;
    results.reserve(boxes.size());
    for (const auto &box : boxes) {
        deadline.Check();
        auto recognition = impl.Recognize(rgba, width, height, stride, box);
        if (!recognition.first.empty() && recognition.second >= .35f)
            results.push_back({std::move(recognition.first), recognition.second, box.box});
    }
    deadline.Check();
    const auto end = Clock::now();
    impl.stats.recognition_ms = std::chrono::duration<double, std::milli>(end - detEnd).count();
    impl.stats.total_ms = std::chrono::duration<double, std::milli>(end - start).count();
    return results;
}
} // namespace ppocrv6
