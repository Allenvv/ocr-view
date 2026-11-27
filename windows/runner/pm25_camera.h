#ifndef PM25_CAMERA_H_
#define PM25_CAMERA_H_
#include <flutter/binary_messenger.h>
#include <flutter/texture_registrar.h>
#include <memory>

// Media Foundation preview and offline REC sampling for a bound UVC session.
class Pm25Camera {
 public:
  Pm25Camera(flutter::BinaryMessenger* messenger,
             flutter::TextureRegistrar* registrar);
  ~Pm25Camera();
  Pm25Camera(const Pm25Camera&) = delete;
  Pm25Camera& operator=(const Pm25Camera&) = delete;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
#endif
