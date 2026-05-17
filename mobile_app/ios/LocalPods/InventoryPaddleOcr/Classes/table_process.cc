#include "table_process.h"
#include "utils.h"
#include <algorithm>
#include <cmath>
#include <fstream>

namespace {
const int kTableMaxLen = 488;

std::vector<std::string> ReadLines(const std::string &path) {
  std::ifstream input(path);
  std::string line;
  std::vector<std::string> values;
  while (std::getline(input, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    if (!line.empty()) {
      values.push_back(line);
    }
  }
  return values;
}

bool IsTdToken(const std::string &token) {
  return token == "<td>" || token == "<td" || token == "<td></td>";
}

float Clamp(float value, float minValue, float maxValue) {
  return std::max(minValue, std::min(value, maxValue));
}

int Argmax(const float *values, int count) {
  int bestIndex = 0;
  float bestValue = values[0];
  for (int index = 1; index < count; index += 1) {
    if (values[index] > bestValue) {
      bestValue = values[index];
      bestIndex = index;
    }
  }
  return bestIndex;
}
} // namespace

TableStructurePredictor::TableStructurePredictor(
    const std::string &modelPath, const std::string &dictPath, int cpuThreadNum,
    const std::string &cpuPowerMode)
    : eosIndex_(-1) {
  structureDict_ = ReadLines(dictPath);
  if (modelPath.empty() || structureDict_.empty()) {
    return;
  }
  structureDict_.insert(structureDict_.begin(), "sos");
  structureDict_.push_back("eos");
  eosIndex_ = static_cast<int>(structureDict_.size()) - 1;

  paddle::lite_api::MobileConfig config;
  config.set_model_from_file(modelPath);
  config.set_threads(cpuThreadNum);
  config.set_power_mode(ParsePowerMode(cpuPowerMode));
  predictor_ =
      paddle::lite_api::CreatePaddlePredictor<paddle::lite_api::MobileConfig>(
          config);
}

bool TableStructurePredictor::IsReady() const { return predictor_ != nullptr; }

void TableStructurePredictor::Preprocess(const cv::Mat &image,
                                         std::vector<float> *shape) {
  const int height = image.rows;
  const int width = image.cols;
  const float ratio =
      static_cast<float>(kTableMaxLen) /
      static_cast<float>(std::max(std::max(height, width), 1));
  const int resizeHeight = std::max(1, static_cast<int>(height * ratio));
  const int resizeWidth = std::max(1, static_cast<int>(width * ratio));

  cv::Mat resized;
  cv::resize(image, resized, cv::Size(resizeWidth, resizeHeight));
  resized.convertTo(resized, CV_32FC3, 1.0 / 255.0);

  std::unique_ptr<paddle::lite_api::Tensor> inputTensor(
      std::move(predictor_->GetInput(0)));
  inputTensor->Resize({1, 3, kTableMaxLen, kTableMaxLen});
  float *inputData = inputTensor->mutable_data<float>();
  std::fill(inputData, inputData + 3 * kTableMaxLen * kTableMaxLen, 0.0f);

  const float mean[3] = {0.485f, 0.456f, 0.406f};
  const float std[3] = {0.229f, 0.224f, 0.225f};
  const int channelSize = kTableMaxLen * kTableMaxLen;
  for (int y = 0; y < resizeHeight; y += 1) {
    const cv::Vec3f *row = resized.ptr<cv::Vec3f>(y);
    for (int x = 0; x < resizeWidth; x += 1) {
      for (int channel = 0; channel < 3; channel += 1) {
        inputData[channel * channelSize + y * kTableMaxLen + x] =
            (row[x][channel] - mean[channel]) / std[channel];
      }
    }
  }

  *shape = {static_cast<float>(height), static_cast<float>(width), ratio, ratio,
            static_cast<float>(kTableMaxLen),
            static_cast<float>(kTableMaxLen)};
}

TableStructureResult TableStructurePredictor::Postprocess(
    const paddle::lite_api::Tensor &locTensor,
    const paddle::lite_api::Tensor &probTensor,
    const std::vector<float> &shape) const {
  TableStructureResult result;
  const auto locShape = locTensor.shape();
  const auto probShape = probTensor.shape();
  if (locShape.size() != 3 || probShape.size() != 3 || locShape[2] != 4 ||
      probShape[2] <= 0 || shape.size() < 6) {
    return result;
  }

  const float *locData = locTensor.data<float>();
  const float *probData = probTensor.data<float>();
  const int steps =
      static_cast<int>(std::min<int64_t>(locShape[1], probShape[1]));
  const int classCount = static_cast<int>(probShape[2]);
  const float imageHeight = shape[0];
  const float imageWidth = shape[1];
  const float ratioH = shape[2];
  const float ratioW = shape[3];
  const float padH = shape[4];
  const float padW = shape[5];

  for (int step = 0; step < steps; step += 1) {
    const int tokenIndex = Argmax(probData + step * classCount, classCount);
    if (step > 0 && tokenIndex == eosIndex_) {
      break;
    }
    if (tokenIndex <= 0 || tokenIndex == eosIndex_ ||
        tokenIndex >= static_cast<int>(structureDict_.size())) {
      continue;
    }

    const std::string &token = structureDict_[tokenIndex];
    if (IsTdToken(token)) {
      const float *bbox = locData + step * 4;
      const float x1 = Clamp((bbox[0] * padW) / ratioW, 0.0f, imageWidth);
      const float y1 = Clamp((bbox[1] * padH) / ratioH, 0.0f, imageHeight);
      const float x2 = Clamp((bbox[2] * padW) / ratioW, 0.0f, imageWidth);
      const float y2 = Clamp((bbox[3] * padH) / ratioH, 0.0f, imageHeight);
      result.cells.push_back({std::min(x1, x2), std::min(y1, y2),
                              std::max(x1, x2), std::max(y1, y2)});
    }
    result.tokens.push_back(token);
  }
  return result;
}

TableStructureResult TableStructurePredictor::Predict(const cv::Mat &image) {
  if (!IsReady() || image.empty()) {
    return {};
  }

  std::vector<float> shape;
  Preprocess(image, &shape);
  predictor_->Run();

  std::unique_ptr<const paddle::lite_api::Tensor> output0(
      std::move(predictor_->GetOutput(0)));
  std::unique_ptr<const paddle::lite_api::Tensor> output1(
      std::move(predictor_->GetOutput(1)));
  if (output0 == nullptr || output1 == nullptr) {
    return {};
  }

  const auto shape0 = output0->shape();
  const auto shape1 = output1->shape();
  if (shape0.size() == 3 && shape0[2] == 4) {
    return Postprocess(*output0, *output1, shape);
  }
  if (shape1.size() == 3 && shape1[2] == 4) {
    return Postprocess(*output1, *output0, shape);
  }
  return {};
}
