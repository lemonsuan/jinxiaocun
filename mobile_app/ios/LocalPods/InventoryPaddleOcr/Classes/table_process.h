#pragma once

#include "paddle_api.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <memory>
#include <string>
#include <vector>

struct TableCellBox {
  float left;
  float top;
  float right;
  float bottom;
};

struct TableStructureResult {
  std::vector<std::string> tokens;
  std::vector<TableCellBox> cells;
};

class TableStructurePredictor {
public:
  TableStructurePredictor(const std::string &modelPath,
                          const std::string &dictPath, int cpuThreadNum,
                          const std::string &cpuPowerMode);

  bool IsReady() const;
  TableStructureResult Predict(const cv::Mat &image);

private:
  void Preprocess(const cv::Mat &image, std::vector<float> *shape);
  TableStructureResult Postprocess(const paddle::lite_api::Tensor &locTensor,
                                   const paddle::lite_api::Tensor &probTensor,
                                   const std::vector<float> &shape) const;

  std::shared_ptr<paddle::lite_api::PaddlePredictor> predictor_;
  std::vector<std::string> structureDict_;
  int eosIndex_;
};
