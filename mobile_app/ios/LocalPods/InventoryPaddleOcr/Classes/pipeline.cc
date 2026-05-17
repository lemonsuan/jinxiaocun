#include "pipeline.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <map>

namespace {
struct OcrCell {
  std::string text;
  float score;
  float left;
  float top;
  float right;
  float bottom;
  float centerX;
  float centerY;
  float height;
};

cv::Mat GetRotateCropImage(const cv::Mat &srcimage,
                           std::vector<std::vector<int>> box) {
  int x_collect[4] = {box[0][0], box[1][0], box[2][0], box[3][0]};
  int y_collect[4] = {box[0][1], box[1][1], box[2][1], box[3][1]};
  int left = std::max(0, int(*std::min_element(x_collect, x_collect + 4)));
  int right =
      std::min(srcimage.cols, int(*std::max_element(x_collect, x_collect + 4)));
  int top = std::max(0, int(*std::min_element(y_collect, y_collect + 4)));
  int bottom = std::min(srcimage.rows,
                        int(*std::max_element(y_collect, y_collect + 4)));
  if (right <= left || bottom <= top) {
    return cv::Mat();
  }

  cv::Mat img_crop;
  srcimage(cv::Rect(left, top, right - left, bottom - top)).copyTo(img_crop);
  for (auto &point : box) {
    point[0] -= left;
    point[1] -= top;
  }

  int img_crop_width = static_cast<int>(sqrt(pow(box[0][0] - box[1][0], 2) +
                                             pow(box[0][1] - box[1][1], 2)));
  int img_crop_height = static_cast<int>(sqrt(pow(box[0][0] - box[3][0], 2) +
                                              pow(box[0][1] - box[3][1], 2)));
  if (img_crop_width <= 0 || img_crop_height <= 0) {
    return img_crop;
  }

  cv::Point2f pts_std[4];
  pts_std[0] = cv::Point2f(0.f, 0.f);
  pts_std[1] = cv::Point2f(img_crop_width, 0.f);
  pts_std[2] = cv::Point2f(img_crop_width, img_crop_height);
  pts_std[3] = cv::Point2f(0.f, img_crop_height);

  cv::Point2f pointsf[4];
  for (int index = 0; index < 4; index += 1) {
    pointsf[index] = cv::Point2f(box[index][0], box[index][1]);
  }

  cv::Mat dst_img;
  cv::warpPerspective(img_crop, dst_img, cv::getPerspectiveTransform(pointsf, pts_std),
                      cv::Size(img_crop_width, img_crop_height),
                      cv::BORDER_REPLICATE);

  if (static_cast<float>(dst_img.rows) >=
      static_cast<float>(dst_img.cols) * 1.5f) {
    cv::Mat srcCopy;
    cv::transpose(dst_img, srcCopy);
    cv::flip(srcCopy, srcCopy, 0);
    return srcCopy;
  }
  return dst_img;
}

std::vector<std::string> ReadDict(const std::string &path) {
  std::ifstream in(path);
  std::string line;
  std::vector<std::string> values;
  while (getline(in, line)) {
    values.push_back(line);
  }
  return values;
}

std::vector<std::string> Split(const std::string &str,
                               const std::string &delim) {
  std::vector<std::string> res;
  if (str.empty()) {
    return res;
  }
  char *strs = new char[str.length() + 1];
  std::strcpy(strs, str.c_str());
  char *d = new char[delim.length() + 1];
  std::strcpy(d, delim.c_str());
  char *p = std::strtok(strs, d);
  while (p) {
    res.emplace_back(p);
    p = std::strtok(NULL, d);
  }
  delete[] strs;
  delete[] d;
  return res;
}

std::map<std::string, double> LoadConfigTxt(const std::string &configPath) {
  auto config = ReadDict(configPath);
  std::map<std::string, double> dict;
  for (const auto &line : config) {
    auto parts = Split(line, " ");
    if (parts.size() >= 2) {
      dict[parts[0]] = stod(parts[1]);
    }
  }
  return dict;
}

OcrCell BuildCell(const std::vector<std::vector<int>> &box,
                  const std::string &text, float score) {
  int minX = box[0][0], maxX = box[0][0], minY = box[0][1], maxY = box[0][1];
  for (const auto &point : box) {
    minX = std::min(minX, point[0]);
    maxX = std::max(maxX, point[0]);
    minY = std::min(minY, point[1]);
    maxY = std::max(maxY, point[1]);
  }
  return {text, score, static_cast<float>(minX), static_cast<float>(minY),
          static_cast<float>(maxX), static_cast<float>(maxY),
          (minX + maxX) / 2.0f, (minY + maxY) / 2.0f,
          static_cast<float>(std::max(1, maxY - minY))};
}

std::vector<std::string> GroupCellsIntoRows(std::vector<OcrCell> cells) {
  if (cells.empty()) {
    return {};
  }
  std::sort(cells.begin(), cells.end(), [](const OcrCell &a, const OcrCell &b) {
    return a.centerY == b.centerY ? a.centerX < b.centerX : a.centerY < b.centerY;
  });

  std::vector<float> heights;
  for (const auto &cell : cells) {
    heights.push_back(cell.height);
  }
  std::sort(heights.begin(), heights.end());
  const float medianHeight = heights[heights.size() / 2];
  const float rowThreshold = std::max(12.0f, medianHeight * 0.75f);

  std::vector<std::vector<OcrCell>> rows;
  for (const auto &cell : cells) {
    if (rows.empty() ||
        std::abs(rows.back().front().centerY - cell.centerY) > rowThreshold) {
      rows.push_back({cell});
    } else {
      rows.back().push_back(cell);
    }
  }

  std::vector<std::string> result;
  for (auto &row : rows) {
    std::sort(row.begin(), row.end(), [](const OcrCell &a, const OcrCell &b) {
      return a.centerX < b.centerX;
    });
    std::string line;
    for (size_t index = 0; index < row.size(); index += 1) {
      if (index > 0) {
        line += "\t";
      }
      line += row[index].text;
    }
    if (!line.empty()) {
      result.push_back(line);
    }
  }
  return result;
}

bool IsTdToken(const std::string &token) {
  return token == "<td>" || token == "<td" || token == "<td></td>";
}

float OverlapArea(const OcrCell &ocr, const TableCellBox &cell) {
  const float left = std::max(ocr.left, cell.left);
  const float top = std::max(ocr.top, cell.top);
  const float right = std::min(ocr.right, cell.right);
  const float bottom = std::min(ocr.bottom, cell.bottom);
  if (right <= left || bottom <= top) {
    return 0.0f;
  }
  return (right - left) * (bottom - top);
}

bool CenterInside(const OcrCell &ocr, const TableCellBox &cell) {
  return ocr.centerX >= cell.left && ocr.centerX <= cell.right &&
         ocr.centerY >= cell.top && ocr.centerY <= cell.bottom;
}

std::string CellText(std::vector<OcrCell> values) {
  if (values.empty()) {
    return "";
  }
  std::sort(values.begin(), values.end(), [](const OcrCell &a, const OcrCell &b) {
    const float threshold = std::max(a.height, b.height) * 0.5f;
    if (std::abs(a.centerY - b.centerY) > threshold) {
      return a.centerY < b.centerY;
    }
    return a.centerX < b.centerX;
  });
  std::string text;
  for (size_t index = 0; index < values.size(); index += 1) {
    if (index > 0) {
      text += " ";
    }
    text += values[index].text;
  }
  return text;
}

std::vector<std::string>
BuildStructuredRows(const TableStructureResult &table,
                    const std::vector<OcrCell> &ocrCells) {
  if (table.tokens.empty() || table.cells.empty() || ocrCells.empty()) {
    return {};
  }

  std::vector<std::vector<OcrCell>> assigned(table.cells.size());
  for (const auto &ocr : ocrCells) {
    int bestIndex = -1;
    float bestScore = 0.0f;
    for (size_t index = 0; index < table.cells.size(); index += 1) {
      const float overlap = OverlapArea(ocr, table.cells[index]);
      const float score =
          CenterInside(ocr, table.cells[index]) ? overlap + 1000000.0f : overlap;
      if (score > bestScore) {
        bestScore = score;
        bestIndex = static_cast<int>(index);
      }
    }
    if (bestIndex >= 0) {
      assigned[bestIndex].push_back(ocr);
    }
  }

  std::vector<std::string> cellTexts;
  int nonEmptyCellCount = 0;
  for (const auto &cellValues : assigned) {
    auto text = CellText(cellValues);
    if (!text.empty()) {
      nonEmptyCellCount += 1;
    }
    cellTexts.push_back(text);
  }
  if (nonEmptyCellCount == 0) {
    return {};
  }

  std::vector<std::string> rows;
  std::vector<std::string> currentRow;
  size_t cellIndex = 0;
  for (const auto &token : table.tokens) {
    if (token == "<tr>") {
      if (!currentRow.empty()) {
        rows.push_back("");
        for (size_t index = 0; index < currentRow.size(); index += 1) {
          if (index > 0) {
            rows.back() += "\t";
          }
          rows.back() += currentRow[index];
        }
        currentRow.clear();
      }
      continue;
    }
    if (token == "</tr>") {
      if (!currentRow.empty()) {
        rows.push_back("");
        for (size_t index = 0; index < currentRow.size(); index += 1) {
          if (index > 0) {
            rows.back() += "\t";
          }
          rows.back() += currentRow[index];
        }
        currentRow.clear();
      }
      continue;
    }
    if (IsTdToken(token) && cellIndex < cellTexts.size()) {
      currentRow.push_back(cellTexts[cellIndex]);
      cellIndex += 1;
    }
  }
  if (!currentRow.empty()) {
    rows.push_back("");
    for (size_t index = 0; index < currentRow.size(); index += 1) {
      if (index > 0) {
        rows.back() += "\t";
      }
      rows.back() += currentRow[index];
    }
  }

  rows.erase(std::remove_if(rows.begin(), rows.end(),
                            [](const std::string &row) { return row.empty(); }),
             rows.end());
  return rows;
}
} // namespace

Pipeline::Pipeline(const std::string &detModelDir,
                   const std::string &clsModelDir,
                   const std::string &recModelDir,
                   const std::string &cPUPowerMode, int cPUThreadNum,
                   const std::string &configPath,
                   const std::string &dictPath,
                   const std::string &tableModelPath,
                   const std::string &tableDictPath) {
  clsPredictor_.reset(new ClsPredictor(clsModelDir, cPUThreadNum, cPUPowerMode));
  detPredictor_.reset(new DetPredictor(detModelDir, cPUThreadNum, cPUPowerMode));
  recPredictor_.reset(new RecPredictor(recModelDir, cPUThreadNum, cPUPowerMode));
  Config_ = LoadConfigTxt(configPath);
  charactor_dict_ = ReadDict(dictPath);
  charactor_dict_.insert(charactor_dict_.begin(), "#");
  charactor_dict_.push_back(" ");
  tablePredictor_.reset(new TableStructurePredictor(
      tableModelPath, tableDictPath, cPUThreadNum, cPUPowerMode));
}

std::vector<std::string> Pipeline::RecognizeRows(const std::string &imagePath) {
  cv::Mat image = cv::imread(imagePath, cv::IMREAD_COLOR);
  if (image.empty()) {
    return {};
  }

  const int useDirectionClassify = int(Config_["use_direction_classify"]);
  auto boxes = detPredictor_->Predict(image, Config_, nullptr, nullptr, nullptr);

  std::vector<OcrCell> cells;
  for (int index = static_cast<int>(boxes.size()) - 1; index >= 0; index -= 1) {
    cv::Mat cropImage = GetRotateCropImage(image, boxes[index]);
    if (cropImage.empty()) {
      continue;
    }
    if (useDirectionClassify >= 1) {
      cropImage = clsPredictor_->Predict(cropImage, nullptr, nullptr, nullptr, 0.9);
    }
    auto recognized =
        recPredictor_->Predict(cropImage, nullptr, nullptr, nullptr, charactor_dict_);
    if (!recognized.first.empty()) {
      cells.push_back(BuildCell(boxes[index], recognized.first, recognized.second));
    }
  }
  if (tablePredictor_ != nullptr && tablePredictor_->IsReady()) {
    auto table = tablePredictor_->Predict(image);
    auto structuredRows = BuildStructuredRows(table, cells);
    if (!structuredRows.empty()) {
      return structuredRows;
    }
  }
  return GroupCellsIntoRows(cells);
}
