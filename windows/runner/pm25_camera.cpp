#include "pm25_camera.h"
#ifdef PM25_WITH_ORT
#include "pm25_rec_model.h"
#endif
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <chrono>
#include <cstdlib>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Clock = std::chrono::steady_clock;
struct Frame { UINT32 width{}, height{}; std::vector<uint8_t> data; };
struct Lease {
  std::shared_ptr<const Frame> frame;
  FlutterDesktopPixelBuffer buffer{};
};
#ifdef PM25_WITH_ORT
struct ProbeJob {
  std::mutex lock;
  bool done{false};
  std::string text, error;
  double confidence{};
};
struct ModelSlot {
  std::mutex lock;
  std::shared_ptr<Pm25RecModel> model;
};
#endif
struct Session {
  std::mutex lock;
  flutter::TextureRegistrar* registrar{};
  int64_t texture_id{-1};
  bool stopped{false};
  bool ended{false};
  std::string detail{"Opening Media Foundation camera..."};
  Clock::time_point received{};
  std::shared_ptr<const Frame> frame;
};
void Check(HRESULT hr, const char* stage) {
  if (FAILED(hr)) throw std::runtime_error(std::string(stage) + " (" + std::to_string(hr) + ")");
}
struct MediaRuntime {
  bool com{false}, mf{false};
  ~MediaRuntime() { if (mf) MFShutdown(); if (com) CoUninitialize(); }
};
struct DeviceList {
  IMFActivate** entries{}; UINT32 count{};
  ~DeviceList() { for (UINT32 i=0;i<count;++i) entries[i]->Release(); CoTaskMemFree(entries); }
};
void Capture(const std::shared_ptr<Session>& session) {
  try {
    MediaRuntime runtime;
    Check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM initialization failed"); runtime.com=true;
    Check(MFStartup(MF_VERSION), "Media Foundation initialization failed"); runtime.mf=true;
    ComPtr<IMFAttributes> options;
    Check(MFCreateAttributes(&options, 1), "Capture attributes unavailable");
    Check(options->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID), "Video source selection failed");
    DeviceList devices;
    Check(MFEnumDeviceSources(options.Get(), &devices.entries, &devices.count), "Camera enumeration failed");
    if (!devices.count) throw std::runtime_error("No Media Foundation camera found");
    // PoC chooses the first Windows-visible camera; there is no verified device mapping.
    ComPtr<IMFMediaSource> source;
    Check(devices.entries[0]->ActivateObject(IID_PPV_ARGS(&source)), "Camera activation failed");
    struct Shutdown { IMFMediaSource* p; ~Shutdown(){p->Shutdown();} } shutdown{source.Get()};
    ComPtr<IMFAttributes> reader_options;
    Check(MFCreateAttributes(&reader_options, 1), "Reader attributes unavailable");
    Check(reader_options->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING,TRUE), "RGB conversion option unavailable");
    ComPtr<IMFSourceReader> reader;
    Check(MFCreateSourceReaderFromMediaSource(source.Get(),reader_options.Get(),&reader),"Camera source reader failed");
    constexpr DWORD video=MF_SOURCE_READER_FIRST_VIDEO_STREAM;
    Check(reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS,FALSE),"Cannot deselect media streams");
    Check(reader->SetStreamSelection(video,TRUE),"Cannot select video stream");
    for (DWORD i=0;;++i) {
      ComPtr<IMFMediaType> native;
      if (FAILED(reader->GetNativeMediaType(video,i,&native))) break;
      UINT32 w=0,h=0;
      if (SUCCEEDED(MFGetAttributeSize(native.Get(),MF_MT_FRAME_SIZE,&w,&h)) && w==1280 && h==720 &&
          SUCCEEDED(reader->SetCurrentMediaType(video,nullptr,native.Get()))) break;
    }
    ComPtr<IMFMediaType> rgb;
    Check(MFCreateMediaType(&rgb),"RGB type unavailable");
    Check(rgb->SetGUID(MF_MT_MAJOR_TYPE,MFMediaType_Video),"Video format unavailable");
    Check(rgb->SetGUID(MF_MT_SUBTYPE,MFVideoFormat_RGB32),"RGB32 unavailable");
    Check(reader->SetCurrentMediaType(video,nullptr,rgb.Get()),"Camera does not supply a convertible RGB32 mode");
    auto last=Clock::time_point{};
    while (true) {
      {std::lock_guard<std::mutex> guard(session->lock); if(session->stopped) break;}
      DWORD flags=0; ComPtr<IMFSample> sample;
      Check(reader->ReadSample(video,0,nullptr,&flags,nullptr,&sample),"Camera frame read failed");
      if (flags & (MF_SOURCE_READERF_ERROR|MF_SOURCE_READERF_ENDOFSTREAM)) throw std::runtime_error("Camera stream ended");
      const auto now=Clock::now();
      if (!sample || now-last<std::chrono::milliseconds(67)) continue;
      last=now;
      ComPtr<IMFMediaType> current;
      Check(reader->GetCurrentMediaType(video,&current),"Camera format unknown");
      auto frame=std::make_shared<Frame>();
      Check(MFGetAttributeSize(current.Get(),MF_MT_FRAME_SIZE,&frame->width,&frame->height),"Camera size unknown");
      if (!frame->width || !frame->height || frame->width>4096 || frame->height>2160) throw std::runtime_error("Unsupported preview dimensions");
      ComPtr<IMFMediaBuffer> buffer;
      Check(sample->ConvertToContiguousBuffer(&buffer),"Camera buffer is unavailable");
      ComPtr<IMF2DBuffer> buffer2d;
      BYTE* data=nullptr; LONG stride=0; DWORD length=0;
      const bool locked2d=SUCCEEDED(buffer.As(&buffer2d)) && SUCCEEDED(buffer2d->Lock2D(&data,&stride));
      if (!locked2d) {
        UINT32 raw_stride=0;
        if(SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE,&raw_stride))) stride=static_cast<LONG>(raw_stride);
        else Check(MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1,frame->width,&stride),"RGB32 stride unknown");
        Check(buffer->Lock(&data,nullptr,&length),"Camera buffer lock failed");
      }
      struct Unlock { IMFMediaBuffer* b; IMF2DBuffer* d; ~Unlock(){if(d)d->Unlock2D();else b->Unlock();} } unlock{buffer.Get(),locked2d?buffer2d.Get():nullptr};
      const auto pitch=static_cast<size_t>(std::abs(static_cast<long long>(stride)));
      if (!data || pitch<frame->width*4u || (!locked2d && pitch*frame->height>length)) throw std::runtime_error("Invalid RGB32 buffer stride");
      if (!locked2d && stride<0) data+=pitch*(frame->height-1);
      frame->data.resize(static_cast<size_t>(frame->width)*frame->height*4);
      for (UINT32 y=0;y<frame->height;++y) {
        const auto* row=data+static_cast<ptrdiff_t>(y)*stride;
        auto* out=frame->data.data()+static_cast<size_t>(y)*frame->width*4;
        for (UINT32 x=0;x<frame->width;++x,row+=4,out+=4) {out[0]=row[2];out[1]=row[1];out[2]=row[0];out[3]=255;}
      }
      std::lock_guard<std::mutex> guard(session->lock);
      if (session->stopped) break;
      session->frame=std::move(frame); session->received=now;
      session->detail="Media Foundation preview PoC; REC and device profile not validated";
      if(session->texture_id>=0)session->registrar->MarkTextureFrameAvailable(session->texture_id);
    }
  } catch(const std::exception& error) {
    std::lock_guard<std::mutex> guard(session->lock);
    if (!session->stopped) session->detail=error.what();
  }
  std::lock_guard<std::mutex> guard(session->lock);
  session->ended=true;
}
} // namespace

struct Pm25Camera::Impl {
  flutter::TextureRegistrar* registrar;
  flutter::MethodChannel<Value> channel;
  std::shared_ptr<Session> session;
  std::shared_ptr<Session> retiring;
  std::shared_ptr<flutter::TextureVariant> texture;
#ifdef PM25_WITH_ORT
  std::shared_ptr<ModelSlot> rec=std::make_shared<ModelSlot>();
  std::shared_ptr<ProbeJob> probe;
#endif
  Impl(flutter::BinaryMessenger* messenger,flutter::TextureRegistrar* r)
      :registrar(r),channel(messenger,"pm25_capture/camera",&flutter::StandardMethodCodec::GetInstance()) {
#ifdef PM25_WITH_ORT
    try {
      std::thread([slot=rec]{
        try {
          std::wstring path(32768,L'\0');
          const auto count=GetModuleFileNameW(nullptr,path.data(),static_cast<DWORD>(path.size()));
          if(!count || count>=path.size())return;
          path.resize(count);
          auto model=std::make_shared<Pm25RecModel>(std::filesystem::path(path).parent_path());
          std::lock_guard<std::mutex> lock(slot->lock);
          slot->model=std::move(model);
        } catch(const std::exception&) { /* Missing/invalid model leaves the probe disabled. */ }
      }).detach();
    } catch(const std::exception&) { /* Preview does not depend on the probe. */ }
#endif
    channel.SetMethodCallHandler([this](const auto& call,auto result){
      if (call.method_name()=="open") { if(!session) Open(); result->Success(State()); }
      else if (call.method_name()=="state"||call.method_name()=="tune") result->Success(State());
      else if (call.method_name()=="sample") result->Error("unsupported_profile","No validated Windows UVC/REC profile");
      else if (call.method_name()=="close") {Close();result->Success();}
#ifdef PM25_WITH_ORT
      else if (call.method_name()=="probe") {
        try { result->Success(BeginProbe(call.arguments())); }
        catch(const std::exception& e) {result->Error("probe_unavailable",e.what());}
      } else if(call.method_name()=="probeResult") result->Success(ProbeResult());
#endif
      else result->NotImplemented();
    });
  }
  ~Impl(){channel.SetMethodCallHandler(nullptr);Close();}
  void Open(){
    if(retiring){bool ended;{std::lock_guard<std::mutex> guard(retiring->lock);ended=retiring->ended;}if(!ended)return;retiring.reset();}
    session=std::make_shared<Session>(); session->registrar=registrar;
    texture=std::make_shared<flutter::TextureVariant>(flutter::PixelBufferTexture([view=session](size_t,size_t)->const FlutterDesktopPixelBuffer*{
      std::shared_ptr<const Frame> frame;
      {std::lock_guard<std::mutex> guard(view->lock);frame=view->frame;}
      if(!frame)return nullptr;
      auto* lease=new Lease{std::move(frame),{}};
      lease->buffer.buffer=lease->frame->data.data();
      lease->buffer.width=lease->frame->width;
      lease->buffer.height=lease->frame->height;
      lease->buffer.release_context=lease;
      lease->buffer.release_callback=[](void* pointer){delete static_cast<Lease*>(pointer);};
      return &lease->buffer;
    }));
    session->texture_id=registrar->RegisterTexture(texture.get());
    if(session->texture_id<0){session->detail="Flutter texture registration failed";session->ended=true;return;}
    try {std::thread(Capture,session).detach();}
    catch(const std::exception& e){session->detail=e.what();session->ended=true;}
  }
  void Close(){
    if(!session)return;
    int64_t id;
    {std::lock_guard<std::mutex> guard(session->lock);session->stopped=true;id=session->texture_id;session->texture_id=-1;}
    if(id>=0)registrar->UnregisterTexture(id,[keep=texture]{});
    texture.reset(); retiring=std::move(session);
  }
#ifdef PM25_WITH_ORT
  Value BeginProbe(const Value* arg){
    if(probe) {std::lock_guard<std::mutex> lock(probe->lock);if(!probe->done)throw std::runtime_error("Another probe is in flight");}
    const auto* roi=arg?std::get_if<Map>(arg):nullptr;
    if(!roi || !session)throw std::runtime_error("ROI or camera unavailable");
    std::shared_ptr<Pm25RecModel> model;
    {std::lock_guard<std::mutex> lock(rec->lock);model=rec->model;}
    if(!model)throw std::runtime_error("No ONNX REC model loaded");
    std::shared_ptr<const Frame> frame;
    {std::lock_guard<std::mutex> lock(session->lock);
      if(!session->ended && Clock::now()-session->received<std::chrono::milliseconds(1500))frame=session->frame;}
    if(!frame)throw std::runtime_error("No recent frame");
    const auto number=[roi](const char* key){return std::get<double>(roi->at(Value(key)));};
    const double l=number("l"),t=number("t"),r=number("r"),b=number("b");
    auto job=std::make_shared<ProbeJob>();
    std::thread([job,model,frame,l,t,r,b]{
      Pm25Recognition reading{"",0};
      std::string error;
      try {reading=model->Run(frame->data,frame->width,frame->height,l,t,r,b);}
      catch(const std::exception& e){error=e.what();}
      std::lock_guard<std::mutex> lock(job->lock);
      job->text=std::move(reading.text);job->confidence=reading.confidence;
      job->error=std::move(error);job->done=true;
    }).detach();
    probe=std::move(job);
    return Value(Map{{Value("pending"),Value(true)}});
  }
  Value ProbeResult(){
    if(!probe)return Value();
    std::lock_guard<std::mutex> lock(probe->lock);
    if(!probe->done)return Value(Map{{Value("pending"),Value(true)}});
    Map out{{Value("text"),Value(probe->text)},{Value("confidence"),Value(probe->confidence)}};
    if(!probe->error.empty())out[Value("error")]=Value(probe->error);
    return Value(out);
  }
#endif
  Value State(){
    Map info{{Value("platform"),Value("Windows Media Foundation")},{Value("validated"),Value(false)},
      {Value("ready"),Value(false)},{Value("storageReady"),Value(false)},{Value("tuneSupported"),Value(false)},
      {Value("roiLimit"),Value(0)},{Value("periods"),Value(flutter::EncodableList{})}};
#ifdef PM25_WITH_ORT
    {std::lock_guard<std::mutex> lock(rec->lock);info[Value("probeSupported")]=Value(static_cast<bool>(rec->model));}
#endif
    if(session){
      std::lock_guard<std::mutex> guard(session->lock);
      info[Value("message")]=Value(session->detail);
      if(session->texture_id>=0)info[Value("textureId")]=Value(session->texture_id);
      info[Value("framesReady")]=Value(!session->ended && session->frame && Clock::now()-session->received<std::chrono::milliseconds(1500));
      if(session->frame){info[Value("width")]=Value(static_cast<int>(session->frame->width));info[Value("height")]=Value(static_cast<int>(session->frame->height));}
    }else info[Value("message")]=Value(retiring?"Previous camera connection is closing; retry shortly":"Camera closed");
    return Value(info);
  }
};
Pm25Camera::Pm25Camera(flutter::BinaryMessenger* messenger,flutter::TextureRegistrar* registrar)
    :impl_(std::make_unique<Impl>(messenger,registrar)){}
Pm25Camera::~Pm25Camera()=default;

