#pragma once

// Include std library headers BEFORE the private/protected hack to avoid
// redefining access specifiers on std internals (std::any, std::stringbuf, etc.)
#include <any>
#include <chrono>
#include <sstream>

// Access private/protected members of Hyprland classes.
// Needed for InputMethodRelay::getFocusedTextInput() and similar.
#define private public
#define protected public

#include <hyprland/src/includes.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

inline HANDLE PHANDLE = nullptr;
