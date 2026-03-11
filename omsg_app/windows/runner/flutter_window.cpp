#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

class FlutterWindow::DeepLinkStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  DeepLinkStreamHandler() = default;
  ~DeepLinkStreamHandler() override = default;

  void Emit(const std::string& deep_link) {
    if (events_) {
      events_->Success(flutter::EncodableValue(deep_link));
    }
  }

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    events_ = std::move(events);
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* arguments) override {
    events_.reset();
    return nullptr;
  }

 private:
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> events_;
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             std::optional<std::string> initial_deep_link)
    : project_(project), initial_deep_link_(std::move(initial_deep_link)) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  deep_link_method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "omsg/deep_links",
          &flutter::StandardMethodCodec::GetInstance());
  deep_link_method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getInitialLink") {
          if (initial_deep_link_.has_value()) {
            result->Success(flutter::EncodableValue(*initial_deep_link_));
          } else {
            result->Success();
          }
          return;
        }
        result->NotImplemented();
      });
  deep_link_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "omsg/deep_links/events",
          &flutter::StandardMethodCodec::GetInstance());
  auto stream_handler = std::make_unique<DeepLinkStreamHandler>();
  deep_link_stream_handler_ = stream_handler.get();
  deep_link_event_channel_->SetStreamHandler(std::move(stream_handler));
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    if (deep_link_event_channel_) {
      deep_link_event_channel_->SetStreamHandler(nullptr);
    }
    deep_link_stream_handler_ = nullptr;
    deep_link_method_channel_.reset();
    deep_link_event_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
