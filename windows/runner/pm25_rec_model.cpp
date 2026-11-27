#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "pm25_rec_model.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <stdexcept>

Pm25RecModel::Pm25RecModel(const std::filesystem::path& dir)
    : env_(ORT_LOGGING_LEVEL_WARNING,"pm25_rec") {
  // rec.conf: width height mean scale (ASCII whitespace-separated).
  std::ifstream config(dir / L"rec.conf");
  if (!(config >> width_ >> height_ >> mean_ >> scale_) || width_ < 8 || width_ > 1024 ||
      height_ < 8 || height_ > 256 || !std::isfinite(mean_) || !std::isfinite(scale_) || scale_ <= 0) {
    throw std::runtime_error("Invalid or missing rec.conf");
  }
  Ort::SessionOptions options;
  options.SetIntraOpNumThreads(1);
  session_ = Ort::Session(env_, (dir / L"rec.onnx").c_str(), options);
  if (session_.GetInputCount() != 1 || session_.GetOutputCount() != 1) {
    throw std::runtime_error("REC model requires precisely one input and output");
  }
  Ort::AllocatorWithDefaultOptions allocator;
  input_=session_.GetInputNameAllocated(0,allocator).get();
  output_=session_.GetOutputNameAllocated(0,allocator).get();
  pixels_.resize(static_cast<size_t>(width_)*height_);
}

Pm25Recognition Pm25RecModel::Run(const std::vector<uint8_t>& rgba, uint32_t fw,
              uint32_t fh, double l, double t, double r, double b) {
  if (!(std::isfinite(l)&&std::isfinite(t)&&std::isfinite(r)&&std::isfinite(b) &&
      l>=0 && t>=0 && r<=1 && b<=1 && r>l && b>t && fw && fh &&
      rgba.size() == static_cast<size_t>(fw)*fh*4)) {
    throw std::runtime_error("Invalid frame or ROI");
  }
  for (int y=0;y<height_;++y) {
    const auto yy=std::min(static_cast<uint32_t>((t+(b-t)*(y+.5)/height_)*fh),fh-1);
    for (int x=0;x<width_;++x) {
      const auto xx=std::min(static_cast<uint32_t>((l+(r-l)*(x+.5)/width_)*fw),fw-1);
      const auto* p=rgba.data()+(static_cast<size_t>(yy)*fw+xx)*4;
      const double y_luma=.299*p[0]+.587*p[1]+.114*p[2];
      pixels_[static_cast<size_t>(y)*width_+x]=static_cast<float>((y_luma/255.0-mean_)/scale_);
    }
  }
  const int64_t shape[]={1,1,height_,width_};
  const auto mem=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
  auto tensor=Ort::Value::CreateTensor<float>(mem,pixels_.data(),pixels_.size(),shape,4);
  const char* in[]={input_.c_str()}; const char* out[]={output_.c_str()};
  auto output=session_.Run(Ort::RunOptions{nullptr},in,&tensor,1,out,1);
  const auto type=output[0].GetTensorTypeAndShapeInfo();
  const auto dims=type.GetShape();
  if(type.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || dims.size()!=3 ||
     dims[0]!=1 || dims[1]<=0 || dims[1]>16384 || dims[2]!=12) {
    throw std::runtime_error("REC output must be float32 [1,T,12] logits");
  }
  const float* p=output[0].GetTensorData<float>();
  constexpr char dict[]="0123456789.";
  int previous=0; double sum=0; std::string value;
  for (int64_t i=0;i<dims[1];++i,p+=12) {
    int best=0;
    for (int c=0;c<12;++c) {
      if(!std::isfinite(p[c])) throw std::runtime_error("REC produced nonfinite logits");
      if(p[c]>p[best])best=c;
    }
    if (best && best!=previous) {
      value.push_back(dict[best-1]);
      double denominator=0;
      for(int c=0;c<12;++c)denominator+=std::exp(static_cast<double>(p[c])-p[best]);
      sum+=1/denominator;
    }
    previous=best;
  }
  return {value, value.empty()?0.0:sum/static_cast<double>(value.size())};
}

