#include "flutter_window.h"
#include <flutter/standard_method_codec.h>
#include <optional>
#include "flutter/generated_plugin_registrant.h"
FlutterWindow::FlutterWindow(const flutter::DartProject& project) : project_(project) {}
FlutterWindow::~FlutterWindow() {}
void FlutterWindow::SetPresentation(bool enabled) {
  SetThreadExecutionState(enabled ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED
                                 : ES_CONTINUOUS);
  if (presentation_ == enabled) return;
  const HWND window = GetHandle();
  if (enabled) {
    old_style_ = GetWindowLongPtr(window, GWL_STYLE);
    GetWindowPlacement(window, &placement_);
    MONITORINFO monitor = {sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor);
    SetWindowLongPtr(window, GWL_STYLE, old_style_ & ~WS_OVERLAPPEDWINDOW);
    SetWindowPos(window, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                 monitor.rcMonitor.right - monitor.rcMonitor.left,
                 monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtr(window, GWL_STYLE, old_style_);
    SetWindowPlacement(window, &placement_);
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  }
  presentation_ = enabled;
}
bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;
  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) return false;
  RegisterPlugins(flutter_controller_->engine());
  study_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "cn.pcnl.study/platform",
      &flutter::StandardMethodCodec::GetInstance());
  study_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "presentation") {
      const auto value = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!value) { result->Error("ARGUMENT", "Expected a boolean"); return; }
      SetPresentation(*value);
      result->Success();
    } else { result->NotImplemented(); }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}
void FlutterWindow::OnDestroy() {
  SetThreadExecutionState(ES_CONTINUOUS);
  study_channel_ = nullptr;
  flutter_controller_ = nullptr;
  Win32Window::OnDestroy();
}
LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
    WPARAM const wparam, LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    const auto result = flutter_controller_->HandleTopLevelWindowProc(
        hwnd, message, wparam, lparam);
    if (result) return *result;
  }
  if (message == WM_FONTCHANGE && flutter_controller_) {
    flutter_controller_->engine()->ReloadSystemFonts();
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
