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
#include <cmath>
#include <cstdlib>
#include <mutex>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Clock = std::chrono::steady_clock;
struct Frame { UINT32 width{}, height{}; int64_t timestamp{}; std::vector<uint8_t> data; };
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
  std::string error;
};
#endif
std::filesystem::path AppDirectory() {
  std::wstring path(32768, L'\0');
  const auto n=GetModuleFileNameW(nullptr,path.data(),static_cast<DWORD>(path.size()));
  if(!n || static_cast<size_t>(n)>=path.size()) throw std::runtime_error("Cannot locate application directory");
  path.resize(n); return std::filesystem::path(path).parent_path();
}
struct CameraProfile {
  std::wstring link;
  UINT32 width{}, height{}, fpsNum{}, fpsDen{};
  GUID subtype{};
  std::string modelHash;
  std::string runtime;
  std::string computer;
  Map combos;
};
CameraProfile ReadProfile() {
  CameraProfile profile;
  std::ifstream in(AppDirectory()/L"uvc.conf");
  std::string link, subtype;
  if(!(in>>std::quoted(link)>>profile.width>>profile.height>>profile.fpsNum>>profile.fpsDen>>subtype>>profile.modelHash>>profile.runtime>>std::quoted(profile.computer))) return {};
  if(!profile.width || !profile.height || !profile.fpsNum || !profile.fpsDen || subtype.size()!=38 || link.empty()) return {};
  std::wstring guid(subtype.begin(),subtype.end());
  if(FAILED(CLSIDFromString(guid.c_str(),&profile.subtype))) return {};
  const int len=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,link.data(),static_cast<int>(link.size()),nullptr,0);
  if(len<=0) return {};
  profile.link.resize(len);
  MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,link.data(),static_cast<int>(link.size()),profile.link.data(),len);
  int cycle=0,count=0;
  while(in>>cycle>>count) if((cycle==1000||cycle==2000||cycle==5000)&&count>=1&&count<=8)
    profile.combos[Value(std::to_string(cycle)+":"+std::to_string(count))]=Value(count);
  return profile;
}
struct Session {
  std::mutex lock;
  flutter::TextureRegistrar* registrar{};
  int64_t texture_id{-1};
  bool stopped{false};
  bool fixedMode{false};
  int64_t id{};
  CameraProfile profile;
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

    ComPtr<IMFMediaSource> source;
    UINT32 selected=0;
    if(!session->profile.link.empty()) {
      bool found=false;
      for(UINT32 i=0;i<devices.count;++i){
        wchar_t* link=nullptr; UINT32 len=0;
        if(SUCCEEDED(devices.entries[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,&link,&len))){
          found=_wcsicmp(link,session->profile.link.c_str())==0;
          CoTaskMemFree(link);
          if(found){selected=i;break;}
        }
      }
      if(!found) throw std::runtime_error("Configured UVC device is not connected");
    }
    Check(devices.entries[selected]->ActivateObject(IID_PPV_ARGS(&source)), "Camera activation failed");
    struct Shutdown { IMFMediaSource* p; ~Shutdown(){p->Shutdown();} } shutdown{source.Get()};
    ComPtr<IMFAttributes> reader_options;
    Check(MFCreateAttributes(&reader_options, 1), "Reader attributes unavailable");
    Check(reader_options->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING,TRUE), "RGB conversion option unavailable");
    ComPtr<IMFSourceReader> reader;
    Check(MFCreateSourceReaderFromMediaSource(source.Get(),reader_options.Get(),&reader),"Camera source reader failed");
    constexpr DWORD video=MF_SOURCE_READER_FIRST_VIDEO_STREAM;
    Check(reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS,FALSE),"Cannot deselect media streams");
    Check(reader->SetStreamSelection(video,TRUE),"Cannot select video stream");
    bool exact=false;
    for (DWORD i=0;;++i) {
      ComPtr<IMFMediaType> native;
      if (FAILED(reader->GetNativeMediaType(video,i,&native))) break;
      UINT32 w=0,h=0,fn=0,fd=0; GUID subtype{};
      if(FAILED(MFGetAttributeSize(native.Get(),MF_MT_FRAME_SIZE,&w,&h))) continue;
      const auto& p=session->profile;
      if(p.link.empty() ? (w==1280 && h==720) :
         (w==p.width && h==p.height && SUCCEEDED(MFGetAttributeRatio(native.Get(),MF_MT_FRAME_RATE,&fn,&fd)) &&
          fd && uint64_t(fn)*p.fpsDen==uint64_t(p.fpsNum)*fd && SUCCEEDED(native->GetGUID(MF_MT_SUBTYPE,&subtype)) && subtype==p.subtype)) {
        if(SUCCEEDED(reader->SetCurrentMediaType(video,nullptr,native.Get()))){exact=!p.link.empty();break;}
      }
    }
    if(!exact && !session->profile.link.empty()) throw std::runtime_error("Configured UVC mode unavailable");
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
      if(exact && last!=Clock::time_point{} && (flags & (MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED|MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)))
        throw std::runtime_error("Configured UVC stream changed format; reconnect required");
      const auto now=Clock::now();
      if (!sample || now-last<std::chrono::milliseconds(67)) continue;
      last=now;
      ComPtr<IMFMediaType> current;
      Check(reader->GetCurrentMediaType(video,&current),"Camera format unknown");
      auto frame=std::make_shared<Frame>();
      frame->timestamp=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
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
      session->fixedMode=exact && session->frame->width==session->profile.width && session->frame->height==session->profile.height;
      session->detail=session->fixedMode ? "UVC fixed device/mode (not AF/AE lock)" : "UVC preview; configure an exact device and mode before capture";
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
  struct RoundJob { std::mutex lock; bool done{}; Clock::time_point deadline; Map result; };
  std::shared_ptr<RoundJob> round;
#endif
  int64_t nextSession{};
  Impl(flutter::BinaryMessenger* messenger,flutter::TextureRegistrar* r)
      :registrar(r),channel(messenger,"pm25_capture/camera",&flutter::StandardMethodCodec::GetInstance()) {
#ifdef PM25_WITH_ORT
    try {
      std::thread([slot=rec]{
        try {
          auto model=std::make_shared<Pm25RecModel>(AppDirectory());
          std::lock_guard<std::mutex> lock(slot->lock);
          slot->model=std::move(model);
        } catch(const std::exception& e) {std::lock_guard<std::mutex> lock(slot->lock);slot->error=e.what();}
      }).detach();
    } catch(const std::exception&) { /* Preview does not depend on the probe. */ }
#endif
    channel.SetMethodCallHandler([this](const auto& call,auto result){
      if (call.method_name()=="open") { if(!session) Open(); result->Success(State()); }
      else if (call.method_name()=="state"||call.method_name()=="tune") result->Success(State());

      else if (call.method_name()=="close") {Close();result->Success();}
#ifdef PM25_WITH_ORT
      else if(call.method_name()=="sample") {
        try {result->Success(BeginRound(call.arguments()));}
        catch(const std::exception& e){result->Error("sample_failed",e.what());}
      } else if(call.method_name()=="sampleResult") result->Success(RoundResult());
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
    session=std::make_shared<Session>(); session->registrar=registrar; session->id=++nextSession;
    try{session->profile=ReadProfile();}catch(const std::exception& e){session->detail=e.what();session->ended=true;return;}
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
  bool Fresh() {
    if(!session) return false;
    std::lock_guard<std::mutex> guard(session->lock);
    return session->fixedMode && !session->ended && !session->stopped && session->frame && Clock::now()-session->received<std::chrono::milliseconds(1500);
  }
#ifdef PM25_WITH_ORT
  static Value Code(const char* code) {return Value(Map{{Value("fatal"),Value(code)}});}
  static int64_t Integer(const Value& v) {
    if(const auto* n=std::get_if<int64_t>(&v)) return *n;
    return std::get<int32_t>(v);
  }
  void CheckIdle() {
    if(round) {std::lock_guard<std::mutex> guard(round->lock);if(!round->done)throw std::runtime_error("REC round in progress");}
    if(probe) {std::lock_guard<std::mutex> guard(probe->lock);if(!probe->done)throw std::runtime_error("REC probe in progress");}
  }
  Value BeginRound(const Value* args){
    if(!args) throw std::runtime_error("Missing sampling request");
    const auto& request=std::get<Map>(*args);
    if(!Fresh()||session->id!=Integer(request.at(Value("sessionId")))) return Code("camera_lost");
    if(!StorageReady()) return Code("storage_low");
    CheckIdle();
    std::shared_ptr<Pm25RecModel> model;
    {std::lock_guard<std::mutex> guard(rec->lock);model=rec->model;}
    if(!model) return Code("model_lost");
    const auto& rows=std::get<flutter::EncodableList>(request.at(Value("rois")));
    const auto budget=Integer(request.at(Value("budgetMs")));
    const auto snap=request.find(Value("saveSnapshot")), threshold=request.find(Value("low"));
    const bool snapshot=snap!=request.end() && snap->second==Value(true);
    const double low=threshold==request.end() ? .60 : std::get<double>(threshold->second);
    if(rows.empty()||rows.size()>8||budget<1||budget>4000) throw std::runtime_error("Invalid ROI count or budget");
    std::shared_ptr<const Frame> frame;
    {std::lock_guard<std::mutex> guard(session->lock);frame=session->frame;}
    auto job=std::make_shared<RoundJob>();
    job->deadline=Clock::now()+std::chrono::milliseconds(budget);
    std::thread([job,model,frame,rows,snapshot,low]{
      flutter::EncodableList readings;
      for(const auto& entry:rows){
        if(Clock::now()>=job->deadline) break;
        try{
          const auto& roi=std::get<Map>(entry);
          const auto& id=roi.at(Value("deviceId"));
          Map reading{{Value("deviceId"),id},{Value("text"),Value("")},{Value("confidence"),Value(0.)}};
          const auto n=[&roi](const char* k){return std::get<double>(roi.at(Value(k)));};
          bool failed=true;
          try{
            const auto value=model->Run(frame->data,frame->width,frame->height,n("l"),n("t"),n("r"),n("b"));
            reading[Value("text")]=Value(value.text);reading[Value("confidence")]=Value(value.confidence);
            size_t parsed=0;const auto number=std::stod(value.text,&parsed);
            failed=parsed!=value.text.size()||!std::isfinite(number)||value.confidence<low;
          }catch(const std::exception& e){reading[Value("error")]=Value(e.what());}
          if(snapshot&&failed){
            try{
              const double l=n("l"),t=n("t"),r=n("r"),b=n("b");
              if(l>=0&&t>=0&&r<=1&&b<=1&&r>l&&b>t){
                const std::string header="P5\n96 32\n255\n";
                std::vector<uint8_t> pgm(header.begin(),header.end());
                for(int y=0;y<32;++y)for(int x=0;x<96;++x){
                  const auto xx=static_cast<size_t>((l+(r-l)*(x+.5)/96)*frame->width);
                  const auto yy=static_cast<size_t>((t+(b-t)*(y+.5)/32)*frame->height);
                  const auto* px=frame->data.data()+(yy*frame->width+xx)*4;
                  pgm.push_back(static_cast<uint8_t>((77u*px[0]+150u*px[1]+29u*px[2])>>8));
                }
                reading[Value("snapshot")]=Value(std::move(pgm));
              }
            }catch(const std::exception&){}
          }
          readings.emplace_back(std::move(reading));
        }catch(const std::exception&){break;}
      }
      std::lock_guard<std::mutex> guard(job->lock);
      if(readings.size()==rows.size()&&Clock::now()<job->deadline){
        job->result[Value("timestampMs")]=Value(frame->timestamp);
        job->result[Value("readings")]=Value(std::move(readings));
      }else job->result[Value("fatal")]=Value("sample_timeout");
      job->done=true;
    }).detach();
    round=job; roundSession=session->id;
    return Value(Map{{Value("pending"),Value(true)}});
  }
  int64_t roundSession{};
  Value RoundResult(){
    if(!round||!Fresh()||session->id!=roundSession) return Code("camera_lost");
    std::lock_guard<std::mutex> guard(round->lock);
    if(Clock::now()>=round->deadline) return Code("sample_timeout");
    return round->done ? Value(round->result) : Value(Map{{Value("pending"),Value(true)}});
  }
  Value BeginProbe(const Value* arg){
    CheckIdle();
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
  static bool StorageReady(){
    try{const wchar_t* local=_wgetenv(L"LOCALAPPDATA"); return local && std::filesystem::space(local).available>=100ULL*1024*1024;}
    catch(const std::exception&){return false;}
  }
  Value State(){
    Map info{{Value("platform"),Value("Windows Media Foundation")},{Value("validated"),Value(false)},
      {Value("ready"),Value(Fresh())},{Value("storageReady"),Value(StorageReady())},{Value("tuneSupported"),Value(false)},
      {Value("periods"),Value(flutter::EncodableList{})}};
#ifdef PM25_WITH_ORT
    std::shared_ptr<Pm25RecModel> model;
    {std::lock_guard<std::mutex> lock(rec->lock);model=rec->model;info[Value("modelProblem")]=Value(rec->error);}
    info[Value("probeSupported")]=Value(static_cast<bool>(model));
    info[Value("modelAvailable")]=Value(static_cast<bool>(model));
    if(model){info[Value("modelVersion")]=Value(model->version());info[Value("modelSha256")]=Value(model->sha256());info[Value("runtimeVersion")]=Value(OrtGetApiBase()->GetVersionString());}
    if(session && model){
      const auto& p=session->profile;
      char name[MAX_COMPUTERNAME_LENGTH+1]{};DWORD length=sizeof(name);
      if(GetComputerNameA(name,&length)&&p.computer==name&&p.modelHash==model->sha256()&&p.runtime==OrtGetApiBase()->GetVersionString()&&Fresh()){
        flutter::EncodableList periods;
        for(int cycle:{1000,2000,5000})for(int count=1;count<=8;++count){
          if(p.combos.count(Value(std::to_string(cycle)+":"+std::to_string(count)))){periods.emplace_back(cycle);break;}
        }
        info[Value("validated")]=Value(!periods.empty());info[Value("profiles")]=Value(p.combos);info[Value("periods")]=Value(periods);
      }
    }
#endif
    if(session){
      std::lock_guard<std::mutex> guard(session->lock);
      info[Value("message")]=Value(session->detail);
      info[Value("sessionId")]=Value(session->id);
      info[Value("fixedMode")]=Value(session->fixedMode);
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

