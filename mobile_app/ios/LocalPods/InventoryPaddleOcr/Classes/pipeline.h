#pragma once

#include "cls_process.h"
#include "det_process.h"
#include "paddle_api.h"
#include "rec_process.h"
#include "table_process.h"
#include <map>
#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <string>
#include <vector>

using namespace paddle::lite_api;

class Pipeline {
public:
  Pipeline(const std::string &detModelDir, const std::string &clsModelDir,
           const std::string &recModelDir, const std::string &cPUPowerMode,
           int cPUThreadNum, const std::string &configPath,
           const std::string &dictPath, const std::string &tableModelPath,
           const std::string &tableDictPath);

  std::vector<std::string> RecognizeRows(const std::string &imagePath);

private:
  std::map<std::string, double> Config_;
  std::vector<std::string> charactor_dict_;
  std::shared_ptr<ClsPredictor> clsPredictor_;
  std::shared_ptr<DetPredictor> detPredictor_;
  std::shared_ptr<RecPredictor> recPredictor_;
  std::shared_ptr<TableStructurePredictor> tablePredictor_;
};
